// ignore_for_file: uri_has_not_been_generated
import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/cast/models/cast_queue_item.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/courses/providers/sequence_provider.dart';
import 'package:omnilect/features/courses/providers/xblock_provider.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_html_builder.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';
import 'package:omnilect/features/downloads/utils/resolve_playable_uri.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';
import 'package:omnilect/features/player/models/lecture_player_state.dart';
import 'package:omnilect/features/player/models/vertical_segment.dart';
import 'package:omnilect/features/progress/providers/progress_tracker_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'lecture_player_provider.g.dart';

final _log = Logger('player.lecture-provider');

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

  /// Latest known global position, mirrored from playback snapshots. Used on
  /// dispose to flush a final progress write without reading the disposed
  /// controller.
  double _lastKnownPosition = 0;

  /// Tracks the previous snapshot's isPlaying flag so we can detect the
  /// false→true transition (i.e. the first frame of actual playback after a
  /// tap). On that transition we flush immediately — bypassing the throttle
  /// — so a Continue tile appears as soon as the user hits play, not 5 s
  /// later.
  bool _wasPlaying = false;

  /// Set by `ref.onDispose` so background controller-init work knows to bail
  /// out instead of writing to a disposed `state` notifier.
  bool _buildDisposed = false;

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
    ref.onDispose(() => _buildDisposed = true);

    // Dispatch by course platform. For OCW courses, `sequenceId` is the
    // lecture slug (e.g. `lecture-1-introduction`) rather than an Open edX
    // block id — we load from `cached_ocw_*` tables and synthesize a
    // length-1 segment so the shared LectureScreen widget works unchanged.
    if (courseId.startsWith('ocw:')) {
      return _buildOcw(courseId: courseId, lectureSlug: sequenceId);
    }

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
          Future<Uri?>.value(),
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

    // Create and attach the playback controller, but don't block the page on
    // its initialization — `_startControllerInitialization` runs in the
    // background and flips `controllerReady` when the first segment is
    // loaded. The content list, title, and scrub bar frame appear as soon as
    // this method returns.
    final controller = LecturePlaybackController(videoSchedule);
    _playbackController = controller;
    ref
      ..onDispose(_flushOnDispose)
      ..onDispose(controller.dispose);

    // Listen for playback updates and mirror them into Riverpod state.
    void onPlaybackChange() => _handlePlaybackSnapshot(
          controller.snapshot.value,
          segments,
        );
    controller.snapshot.addListener(onPlaybackChange);
    ref.onDispose(() => controller.snapshot.removeListener(onPlaybackChange));

    unawaited(_startControllerInitialization(controller));

    return LecturePlayerState(
      segments: segments,
      activeSegmentIndex: videoSchedule.first.segmentIndex,
    );
  }

  /// Canonical lecture id for the progress tracker. For OCW courses the
  /// tracked id is `$courseId/$lectureSlug`; for MITx it's the sequence
  /// block id (i.e. `sequenceId`).
  String get _trackedLectureId =>
      courseId.startsWith('ocw:') ? '$courseId/$sequenceId' : sequenceId;

  Future<double> _readSavedPosition() async {
    final row = await ref
        .read(progressTrackerProvider)
        .db
        .getCoursePosition(courseId);
    if (row == null || row.lectureId != _trackedLectureId) return 0;
    return row.positionSeconds;
  }

  void _flushOnDispose() {
    // Fire-and-forget — the provider is tearing down so we can't await.
    unawaited(ref.read(progressTrackerProvider).flushPosition(
          courseId: courseId,
          lectureId: _trackedLectureId,
          positionSeconds: _lastKnownPosition,
        ));
  }

  // ---------------------------------------------------------------------------
  // OCW variant — one lecture, one segment. The rest of the widget tree
  // (LectureScreen, LectureVideoPlayer, VerticalSectionTile, scrub bar,
  // fullscreen, cast) runs unchanged because the state shape is identical.
  // ---------------------------------------------------------------------------

  Future<LecturePlayerState> _buildOcw({
    required String courseId,
    required String lectureSlug,
  }) async {
    final db = ref.read(appDatabaseProvider);
    final lectureId = '$courseId/$lectureSlug';
    final lecture = await db.getOcwLecture(lectureId);
    if (lecture == null) {
      return const LecturePlayerState(segments: []);
    }

    // Gather resources matched to this lecture + render them through the
    // same sanitizer that MITx HTML blocks use so the tile looks identical.
    final resources = await db.getOcwResources(courseId);
    final matched = resources
        .where((r) => r.lectureId == lecture.lectureId)
        .map((r) => OcwResource(
              id: r.resourceId,
              type: _decodeOcwType(r.type),
              title: r.title,
              url: r.url,
              lectureId: r.lectureId,
            ))
        .toList();
    final rawHtml = buildOcwResourceHtml(matched);
    // Use the same sanitized-HTML cache MITx uses. The cache is keyed by an
    // opaque string, and OCW `lectureId` (`ocw:<slug>/<lecture-slug>`) cannot
    // collide with Open edX `block-v1:...` usage keys. Using the
    // course-namespaced `lectureId` (not just the slug) keeps entries
    // distinct across OCW courses.
    final safeHtml = await getOrComputeSanitizedXBlockHtml(
      db: db,
      blockId: lectureId,
      rawHtml: rawHtml,
    );

    // Resolve local-file-first playback URI. OCW MP4s may be null for
    // YouTube-only / in-class-dissection lectures; we surface that as a
    // segment with no videoUrl, which LectureScreen already handles.
    Uri? resolvedUri;
    final mp4 = lecture.mp4Url;
    final remoteUrl = mp4;
    final duration = (lecture.durationSeconds ?? 0).toDouble();
    if (mp4 != null) {
      resolvedUri = await resolvePlayableUri(
        ParsedVideoBlock(
          videoBlockId: lecture.lectureId,
          mp4Url: mp4,
          hlsUrl: null,
          duration: duration,
          transcriptLanguages: const {},
          transcriptTranslationUrl: null,
        ),
        db,
      );
    }
    _log.info('_buildOcw $lectureId: mp4Url=$mp4 resolved=$resolvedUri '
        'duration=$duration');

    final segment = VerticalSegment(
      verticalId: lecture.lectureId,
      title: lecture.title,
      videoUrl: resolvedUri,
      videoDuration: duration,
      globalStartTime: 0,
      safeHtmlContent: safeHtml,
      remoteVideoUrl: remoteUrl,
    );
    _segments = [segment];

    if (resolvedUri == null) {
      // No playable video — let LectureScreen render the resource tile only.
      return LecturePlayerState(segments: [segment]);
    }

    final videoSchedule = [
      VideoScheduleEntry(
        segmentIndex: 0,
        uri: resolvedUri,
        duration: duration,
        globalStartTime: 0,
      ),
    ];
    _videoIndexToSegmentIndex.add(0);

    final controller = LecturePlaybackController(videoSchedule);
    _playbackController = controller;
    ref
      ..onDispose(_flushOnDispose)
      ..onDispose(controller.dispose);

    final segments = [segment];
    void onPlaybackChange() => _handlePlaybackSnapshot(
          controller.snapshot.value,
          segments,
        );
    controller.snapshot.addListener(onPlaybackChange);
    ref.onDispose(() => controller.snapshot.removeListener(onPlaybackChange));

    unawaited(_startControllerInitialization(controller));

    return LecturePlayerState(segments: segments);
  }

  /// Runs `controller.initialize()` off the critical path of `build()`.
  ///
  /// Reads the saved position in parallel with video init, seeks to it after
  /// init completes, and finally flips `controllerReady` so the video area's
  /// own spinner is replaced with the first frame. Bails out if the provider
  /// is disposed mid-flight — writing to a disposed notifier would throw.
  Future<void> _startControllerInitialization(
    LecturePlaybackController controller,
  ) async {
    final savedFuture = _readSavedPosition();

    await controller.initialize();
    if (_buildDisposed) return;

    final savedPosition = await savedFuture;
    if (_buildDisposed) return;

    if (savedPosition > 0 && savedPosition < controller.totalDuration) {
      await controller.seekGlobal(savedPosition);
      if (_buildDisposed) return;
      _lastKnownPosition = savedPosition;
    }

    if (!state.hasValue) return;
    state = AsyncData(state.requireValue.copyWith(controllerReady: true));
  }

  OcwResourceType _decodeOcwType(String name) {
    for (final t in OcwResourceType.values) {
      if (t.name == name) return t;
    }
    return OcwResourceType.lectureNotes;
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

    await ref.read(progressTrackerProvider).flushPosition(
          courseId: courseId,
          lectureId: _trackedLectureId,
          positionSeconds: snap?.globalPosition ?? _lastKnownPosition,
        );

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
    unawaited(ref.read(progressTrackerProvider).flushPosition(
          courseId: courseId,
          lectureId: _trackedLectureId,
          positionSeconds: toPositionS,
        ));
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
    // Immediate write — every seek is a deliberate user action and should
    // persist right away. Covers scrub-release, skip-10/skip-30, and any
    // other programmatic seek.
    unawaited(ref.read(progressTrackerProvider).flushPosition(
          courseId: courseId,
          lectureId: _trackedLectureId,
          positionSeconds: globalSeconds,
        ));
    _lastKnownPosition = globalSeconds;
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

  /// Manually select a section: seeks the video to the segment's start and
  /// expands the tile. Play/pause state is preserved — if playback was paused
  /// it stays paused, if playing it keeps playing from the new position.
  /// Suspends auto-sync until the next video boundary is crossed so the
  /// tapped section stays expanded even when the seek lands on a shared
  /// video boundary.
  Future<void> selectSegment(int index) async {
    if (!state.hasValue) return;
    final seg = state.requireValue.segments[index];
    _log.info('selectSegment($index): globalStartTime=${seg.globalStartTime} '
        'videoUrl=${seg.videoUrl} controller=${_playbackController != null}');
    await _playbackController?.seekGlobal(seg.globalStartTime);
    unawaited(ref.read(progressTrackerProvider).flushPosition(
          courseId: courseId,
          lectureId: _trackedLectureId,
          positionSeconds: seg.globalStartTime,
        ));
    _lastKnownPosition = seg.globalStartTime;
    _updateState((s) => s.copyWith(
          activeSegmentIndex: index,
          userOverrideActive: true,
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

    // Mirror the latest position into _lastKnownPosition so onDispose can
    // flush it once the controller is torn down, and feed the throttled
    // progress writer. The tracker itself enforces the 5-second gap.
    _lastKnownPosition = snap.globalPosition;
    final startedPlaying = !_wasPlaying && snap.isPlaying;
    _wasPlaying = snap.isPlaying;
    if (startedPlaying) {
      // First playback tick after a tap — persist immediately so the
      // Continue section shows up the moment the user starts watching.
      unawaited(ref.read(progressTrackerProvider).flushPosition(
            courseId: courseId,
            lectureId: _trackedLectureId,
            positionSeconds: snap.globalPosition,
          ));
    } else if (snap.isPlaying) {
      unawaited(ref.read(progressTrackerProvider).recordPosition(
            courseId: courseId,
            lectureId: _trackedLectureId,
            positionSeconds: snap.globalPosition,
          ));
    }

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
      // Advance the "continue" row to the next video-bearing sequence (or
      // clear it when none remains).
      unawaited(ref.read(progressTrackerProvider).recordCompletion(
            courseId: courseId,
            completedLectureId: _trackedLectureId,
          ));
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
