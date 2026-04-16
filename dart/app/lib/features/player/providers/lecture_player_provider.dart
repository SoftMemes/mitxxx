// ignore_for_file: uri_has_not_been_generated
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/cast/models/cast_queue_item.dart';
import 'package:omnilect/features/courses/providers/sequence_provider.dart';
import 'package:omnilect/features/courses/providers/xblock_provider.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';
import 'package:omnilect/features/downloads/utils/resolve_playable_uri.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';
import 'package:omnilect/features/player/models/lecture_player_state.dart';
import 'package:omnilect/features/player/models/vertical_segment.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'lecture_player_provider.g.dart';

/// Async notifier that drives the single-page lecture player.
///
/// On first build, loads all verticals for [sequenceId] from the Drift cache,
/// resolves local vs CDN URIs, sanitizes HTML, and starts the
/// [LecturePlaybackController]. Subsequent state updates come from the
/// controller's `ValueNotifier` listener and from explicit method calls
/// (e.g. [play], [pause], [seekGlobal]).
@riverpod
class LecturePlayer extends _$LecturePlayer {
  LecturePlaybackController? _playbackController;

  /// Maps video-schedule index → segment index in [LecturePlayerState.segments].
  final List<int> _videoIndexToSegmentIndex = [];

  /// Video-schedule index that was active the last time we processed a
  /// playback snapshot (used to detect boundary crossings).
  int _lastVideoIndex = 0;

  /// Cached segment list so analytics methods can resolve the current
  /// video block ID without going through state.
  List<VerticalSegment> _segments = [];

  /// Set true between [onScrubStart] and [onScrubEnd] to suppress the
  /// pause event that Chewie/video_player emits during scrubbing.
  bool _scrubInProgress = false;

  /// Position captured at scrub-start, in seconds, for the analytics event.
  int _scrubFromPositionS = 0;

  // ---------------------------------------------------------------------------
  // Public accessor for the widget layer
  // ---------------------------------------------------------------------------

  /// The underlying playback controller. Available once [state] has data.
  LecturePlaybackController? get playbackController => _playbackController;

  /// Returns the cast queue for the current lecture — one item per video
  /// segment, always using the remote CDN URL (never a local file path).
  ///
  /// Returns an empty list if the lecture hasn't loaded yet.
  List<CastQueueItem> get castQueue {
    if (!state.hasValue) return [];
    return state.requireValue.segments
        .where((s) => s.remoteVideoUrl != null)
        .map((s) => CastQueueItem(
              verticalId: s.verticalId,
              title: s.title,
              remoteUrl: Uri.parse(s.remoteVideoUrl!),
              duration: s.videoDuration,
              globalStartTime: s.globalStartTime,
            ))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Future<LecturePlayerState> build({
    required String courseId,
    required String sequenceId,
  }) async {
    // Load sequence metadata.
    final sequence = await ref.watch(
      sequenceDetailProvider(blockId: sequenceId).future,
    );

    if (sequence.items.isEmpty) {
      return const LecturePlayerState(segments: []);
    }

    final db = ref.read(appDatabaseProvider);

    // Load every vertical's xblock content in parallel. Throws AsyncError if
    // any are missing from the cache.
    final contents = await Future.wait(
      sequence.items.map(
        (item) => ref.watch(xblockContentProvider(blockId: item.id).future),
      ),
    );

    // Resolve playable URIs and sanitized HTML concurrently — the sanitized
    // path is a single indexed DB read for already-synced lectures, so this
    // collapses O(n) sequential parsing into one round-trip batch.
    final resolvedUris = await Future.wait([
      for (var i = 0; i < contents.length; i++)
        if (contents[i].videos.isNotEmpty)
          resolvePlayableUri(contents[i].videos.first, db)
        else
          Future<Uri?>.value(null),
    ]);
    final safeHtmls = await Future.wait([
      for (var i = 0; i < contents.length; i++)
        getOrComputeSanitizedXBlockHtml(
          db: db,
          blockId: sequence.items[i].id,
          rawHtml: contents[i].htmlContent,
        ),
    ]);

    // Build VerticalSegment list + video schedule in course order.
    final segments = <VerticalSegment>[];
    final videoSchedule = <VideoScheduleEntry>[];
    var globalTime = 0.0;

    for (var i = 0; i < sequence.items.length; i++) {
      final item = sequence.items[i];
      final content = contents[i];
      final video = content.videos.isNotEmpty ? content.videos.first : null;
      final resolvedUri = resolvedUris[i];
      final duration = video?.duration ?? 0;
      final safeHtml = safeHtmls[i];

      // globalStartTime for segments with video is the current running offset.
      // For no-video segments we use the same offset (they share the boundary
      // with the nearest preceding video segment, so tapping "play" starts at
      // the right position).
      final segGlobalStart = globalTime;

      if (resolvedUri != null) {
        videoSchedule.add(VideoScheduleEntry(
          segmentIndex: segments.length,
          uri: resolvedUri,
          duration: duration,
          globalStartTime: globalTime,
        ));
        _videoIndexToSegmentIndex.add(segments.length);
        globalTime += duration;
      }

      segments.add(VerticalSegment(
        verticalId: item.id,
        title: item.pageTitle,
        videoUrl: resolvedUri,
        videoDuration: duration,
        globalStartTime: segGlobalStart,
        safeHtmlContent: safeHtml,
        remoteVideoUrl: video?.mp4Url,
      ));
    }

    // Cache segments for analytics resolution.
    _segments = segments;

    // If there are no video segments, return immediately with no controller.
    if (videoSchedule.isEmpty) {
      return LecturePlayerState(segments: segments);
    }

    // Create and initialise the playback controller.
    final controller = LecturePlaybackController(videoSchedule);
    _playbackController = controller;
    ref.onDispose(controller.dispose);

    // Listen for playback updates and mirror them into Riverpod state.
    void onPlaybackChange() => _handlePlaybackSnapshot(
          controller.snapshot.value,
          segments,
        );
    controller.snapshot.addListener(onPlaybackChange);
    ref.onDispose(() => controller.snapshot.removeListener(onPlaybackChange));

    await controller.initialize();

    return LecturePlayerState(
      segments: segments,
      activeSegmentIndex: videoSchedule.first.segmentIndex,
    );
  }

  // ---------------------------------------------------------------------------
  // Analytics helpers
  // ---------------------------------------------------------------------------

  String? get _currentVerticalId {
    final snap = _playbackController?.snapshot.value;
    if (snap == null) return null;
    final vidIdx = snap.activeVideoIndex;
    if (vidIdx >= _videoIndexToSegmentIndex.length) return null;
    final segIdx = _videoIndexToSegmentIndex[vidIdx];
    if (segIdx >= _segments.length) return null;
    return _segments[segIdx].verticalId;
  }

  // ---------------------------------------------------------------------------
  // Public control methods
  // ---------------------------------------------------------------------------

  Future<void> play() async {
    final snap = _playbackController?.snapshot.value;
    final positionS = snap != null ? snap.globalPosition.round() : 0;
    final durationS = snap != null ? snap.totalDuration.round() : 0;
    final isResume = positionS > 0;

    await _playbackController?.play();

    final verticalId = _currentVerticalId;
    if (verticalId != null) {
      unawaited(ref.read(analyticsServiceProvider).logVideoPlay(
        courseId: courseId,
        videoBlockId: verticalId,
        positionS: positionS,
        durationS: durationS,
        isResume: isResume,
      ));
    }
  }

  Future<void> pause() async {
    if (_scrubInProgress) {
      // Suppress pause events caused purely by scrubbing.
      await _playbackController?.pause();
      return;
    }

    final snap = _playbackController?.snapshot.value;
    final positionS = snap != null ? snap.globalPosition.round() : 0;
    final durationS = snap != null ? snap.totalDuration.round() : 0;

    await _playbackController?.pause();

    final verticalId = _currentVerticalId;
    if (verticalId != null) {
      unawaited(ref.read(analyticsServiceProvider).logVideoPause(
        courseId: courseId,
        videoBlockId: verticalId,
        positionS: positionS,
        durationS: durationS,
      ));
    }
  }

  /// Called by the widget layer when the user begins dragging the scrub bar.
  void onScrubStart(double fromPositionS) {
    _scrubInProgress = true;
    _scrubFromPositionS = fromPositionS.round();
  }

  /// Called by the widget layer when the user releases the scrub bar.
  void onScrubEnd(double toPositionS) {
    _scrubInProgress = false;
    final snap = _playbackController?.snapshot.value;
    final durationS = snap != null ? snap.totalDuration.round() : 0;
    final verticalId = _currentVerticalId;
    if (verticalId != null) {
      ref.read(analyticsServiceProvider).logVideoScrub(
        courseId: courseId,
        videoBlockId: verticalId,
        fromPositionS: _scrubFromPositionS,
        toPositionS: toPositionS.round(),
        durationS: durationS,
      );
    }
  }

  Future<void> seekGlobal(double globalSeconds) async {
    await _playbackController?.seekGlobal(globalSeconds);
    // After a seek, update activeSegmentIndex to the seek target and lock
    // override so snapshot-sync doesn't thrash the section on every frame.
    // The boundary-crossing branch in _handlePlaybackSnapshot will still
    // release override when playback crosses into the next video naturally.
    _updateState((s) {
      // Find the last segment whose globalStartTime is <= the seek target.
      var targetIndex = 0;
      for (var i = 0; i < s.segments.length; i++) {
        if (s.segments[i].globalStartTime <= globalSeconds) targetIndex = i;
      }
      return s.copyWith(
        activeSegmentIndex: targetIndex,
        userOverrideActive: true,
      );
    });
  }

  /// Manually expand a section. Suspends auto-sync until the next video
  /// boundary is crossed.
  void selectSegment(int index) {
    _updateState((s) => s.copyWith(
          activeSegmentIndex: index,
          userOverrideActive: true,
        ));
  }

  /// Seek the video to the start of [segmentIndex] and start playing.
  Future<void> playFrom(int segmentIndex) async {
    if (!state.hasValue) return;
    final seg = state.requireValue.segments[segmentIndex];
    await _playbackController?.seekGlobal(seg.globalStartTime);
    await _playbackController?.play();
    _updateState((s) => s.copyWith(
          activeSegmentIndex: segmentIndex,
          userOverrideActive: false,
        ));
  }

  /// Dismiss the error and retry loading the current segment.
  Future<void> retry() async {
    // Rebuild the provider, which re-initialises the controller from scratch.
    ref.invalidateSelf();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _handlePlaybackSnapshot(
    PlaybackSnapshot snap,
    List<VerticalSegment> segments,
  ) {
    if (!state.hasValue) return;
    final current = state.requireValue;

    var newActiveSegmentIndex = current.activeSegmentIndex;
    var newUserOverride = current.userOverrideActive;

    final videoIndexChanged = snap.activeVideoIndex != _lastVideoIndex;
    if (videoIndexChanged) {
      // The video crossed a boundary — always clear the override and sync.
      _lastVideoIndex = snap.activeVideoIndex;
      newUserOverride = false;
      if (snap.activeVideoIndex < _videoIndexToSegmentIndex.length) {
        newActiveSegmentIndex =
            _videoIndexToSegmentIndex[snap.activeVideoIndex];
      }
    } else if (!current.userOverrideActive) {
      // Normal auto-sync.
      if (snap.activeVideoIndex < _videoIndexToSegmentIndex.length) {
        newActiveSegmentIndex =
            _videoIndexToSegmentIndex[snap.activeVideoIndex];
      }
    }

    // Surface errors only when there's a new error message.
    final newError =
        snap.error != null && snap.error != current.errorMessage
            ? snap.error
            : (snap.error == null ? null : current.errorMessage);

    // Fire video_complete when playback transitions to complete for the first time.
    if (snap.isComplete && !current.isComplete) {
      final verticalId = _currentVerticalId;
      if (verticalId != null) {
        ref.read(analyticsServiceProvider).logVideoComplete(
          courseId: courseId,
          videoBlockId: verticalId,
          durationS: snap.totalDuration.round(),
        );
      }
    }

    state = AsyncData(current.copyWith(
      globalPosition: snap.globalPosition,
      isPlaying: snap.isPlaying,
      activeSegmentIndex: newActiveSegmentIndex,
      userOverrideActive: newUserOverride,
      isComplete: snap.isComplete,
      errorMessage: newError,
    ));
  }

  void _updateState(LecturePlayerState Function(LecturePlayerState) updater) {
    if (state.hasValue) {
      state = AsyncData(updater(state.requireValue));
    }
  }
}
