import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:video_player/video_player.dart';

final _log = Logger('player.lecture');

/// How long to wait for `VideoPlayerController.initialize()` before surfacing
/// a "video failed to load" error. The native player can silently hang on
/// network issues (DNS, redirect handling, server stalls) — without this the
/// UI sits on a forever spinner. 25 s is generous for a slow first byte but
/// short enough that the user sees something actionable.
const _initTimeout = Duration(seconds: 25);

/// A snapshot of the current playback state exposed by [LecturePlaybackController].
@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.globalPosition,
    required this.totalDuration,
    required this.isPlaying,
    required this.activeVideoIndex,
    required this.isComplete,
    this.error,
  });

  const PlaybackSnapshot.initial()
      : globalPosition = 0,
        totalDuration = 0,
        isPlaying = false,
        activeVideoIndex = 0,
        isComplete = false,
        error = null;

  final double globalPosition;
  final double totalDuration;
  final bool isPlaying;

  /// Index into the video-only segment list (not the full segments list).
  final int activeVideoIndex;
  final bool isComplete;
  final String? error;
}

/// One entry in the video playback schedule.
@immutable
class VideoScheduleEntry {
  const VideoScheduleEntry({
    required this.segmentIndex,
    required this.uri,
    required this.duration,
    required this.globalStartTime,
  });

  /// Index into the full `VerticalSegment` list (including no-video verticals).
  final int segmentIndex;
  final Uri uri;

  /// Known duration in seconds (from LMS metadata). Used to pre-compute
  /// [globalStartTime] before the controller is initialized.
  final double duration;
  final double globalStartTime;
}

/// Manages sequential playback of multiple video segments, presenting them as
/// a single continuous timeline to the UI.
///
/// The controller owns one active [VideoPlayerController] at a time and
/// pre-initializes the next one as the active segment nears its end.
///
/// Usage:
/// ```dart
/// final controller = LecturePlaybackController(schedule);
/// await controller.initialize();
/// controller.snapshot.addListener(() { ... });
/// await controller.play();
/// ...
/// controller.dispose();
/// ```
class LecturePlaybackController {
  LecturePlaybackController(this.schedule)
      : assert(schedule.isNotEmpty, 'schedule must not be empty'),
        _scheduledTotalDuration =
            schedule.fold(0, (sum, e) => sum + e.duration);

  final List<VideoScheduleEntry> schedule;

  /// Metadata-provided total duration (seconds). For MITx lectures this is
  /// reliable — all segments have durations in the xblock metadata. OCW
  /// pages don't surface duration, so OCW schedules arrive with entries
  /// whose `duration` is 0 and this sum is 0.
  final double _scheduledTotalDuration;

  /// Total duration of the lecture in seconds. Uses the schedule sum when
  /// available (>0); otherwise back-fills from the active
  /// [VideoPlayerController]'s loaded duration once it initializes. This
  /// makes the scrub bar seekable for OCW lectures where metadata duration
  /// is unknown.
  double get totalDuration {
    if (_scheduledTotalDuration > 0) return _scheduledTotalDuration;
    final actual = _activeVpc?.value.duration;
    if (actual != null && actual.inMilliseconds > 0) {
      return actual.inMilliseconds / 1000.0;
    }
    return 0;
  }

  /// Current playback state. UI widgets should listen to this.
  final ValueNotifier<PlaybackSnapshot> snapshot = ValueNotifier(
    const PlaybackSnapshot.initial(),
  );

  VideoPlayerController? _activeVpc;
  VideoPlayerController? _preloadedVpc;
  int _activeVideoIndex = 0;
  bool _disposed = false;
  bool _boundaryFired = false;
  bool _preloadStarted = false;

  /// Whether the controller is currently playing (regardless of position).
  bool _wantPlaying = false;

  /// Cached playback speed — applied to the active controller and re-applied
  /// to any newly loaded segment so speed persists across segment swaps.
  double _playbackSpeed = 1;
  double get playbackSpeed => _playbackSpeed;

  // ---------------------------------------------------------------------------
  // Seek serialisation
  // ---------------------------------------------------------------------------
  // Suppresses _updateSnapshot while a seekGlobal is in flight so the UI
  // never sees an intermediate boundary position.
  bool _seekInProgress = false;

  // Latest-wins: if a second seekGlobal arrives while one is running, the
  // new target is stored here and executed after the current one finishes.
  double? _pendingSeekTarget;

  // Controllers queued for disposal (async, after swap).
  final List<VideoPlayerController> _pendingDispose = [];

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  VideoPlayerController? get activeController => _activeVpc;

  /// Loads and initialises the first segment. Must be called before [play].
  Future<void> initialize() async {
    if (_disposed) return;
    await _loadSegment(0);
    _updateSnapshot();
  }

  Future<void> play() async {
    if (_disposed || _activeVpc == null) return;
    _wantPlaying = true;
    await _activeVpc!.play();
    _updateSnapshot();
  }

  Future<void> pause() async {
    if (_disposed || _activeVpc == null) return;
    _log.info('pause() called\n${StackTrace.current}');
    _wantPlaying = false;
    await _activeVpc!.pause();
    _updateSnapshot();
  }

  /// Sets playback speed (1.0 = normal). Applied immediately to the active
  /// segment and cached so later segment swaps inherit it.
  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    if (_disposed || _activeVpc == null) return;
    await _activeVpc!.setPlaybackSpeed(speed);
  }

  /// Seeks to [globalSeconds] anywhere in the stitched timeline.
  ///
  /// If a seek is already in progress the target is updated (latest-wins) and
  /// the new seek runs immediately after the current one finishes. Intermediate
  /// snapshots are suppressed so the UI never sees a boundary-flicker.
  Future<void> seekGlobal(double globalSeconds) async {
    if (_disposed) return;

    if (_seekInProgress) {
      // Another seek is running — queue this target and return; the running
      // seek will pick it up when it finishes.
      _pendingSeekTarget = globalSeconds;
      return;
    }

    _seekInProgress = true;
    try {
      await _doSeek(globalSeconds);
      // Drain any queued target (latest-wins).
      while (_pendingSeekTarget != null && !_disposed) {
        final next = _pendingSeekTarget!;
        _pendingSeekTarget = null;
        await _doSeek(next);
      }
    } finally {
      _seekInProgress = false;
      _updateSnapshot();
    }
  }

  Future<void> _doSeek(double globalSeconds) async {
    if (_disposed) return;
    final clamped = globalSeconds.clamp(0.0, totalDuration);
    final targetIndex = _videoIndexForGlobalTime(clamped);

    if (targetIndex != _activeVideoIndex) {
      // Suppress the snapshot that _loadSegment emits after swapping the
      // active controller so the UI doesn't briefly show the boundary start.
      await _discardPreloaded();
      await _loadSegmentSuppressed(targetIndex);
    }

    if (_activeVpc == null || _disposed) return;

    final within = clamped - schedule[targetIndex].globalStartTime;
    await _activeVpc!
        .seekTo(Duration(milliseconds: (within * 1000).round()));

    _boundaryFired = false;
    _preloadStarted = false;

    if (_wantPlaying && !_disposed) {
      await _activeVpc!.play();
    }
  }

  /// Like [_loadSegment] but skips the trailing [_updateSnapshot] call.
  Future<void> _loadSegmentSuppressed(int index) async {
    final entry = schedule[index];

    VideoPlayerController? vpc;
    if (_preloadedVpc != null && index == _activeVideoIndex + 1) {
      vpc = _preloadedVpc;
      _preloadedVpc = null;
    } else {
      await _discardPreloaded();
      _log.info('_loadSegmentSuppressed[$index]: initializing ${entry.uri}');
      vpc = _createController(entry.uri);
      try {
        await vpc.initialize().timeout(_initTimeout);
      } on Object catch (e) {
        _log.warning(
          '_loadSegmentSuppressed[$index]: init failed for ${entry.uri}',
          e,
        );
        await vpc.dispose();
        if (!_disposed) {
          snapshot.value = PlaybackSnapshot(
            globalPosition: _currentGlobalPosition(),
            totalDuration: totalDuration,
            isPlaying: false,
            activeVideoIndex: index,
            isComplete: false,
            error: 'Failed to load video: $e',
          );
        }
        return;
      }
    }

    // The controller may have been disposed while `vpc.initialize()` was in
    // flight (e.g. the user popped the lecture page during load). Drop the
    // freshly-initialized controller instead of wiring it up — wiring into a
    // disposed snapshot/notifier throws.
    if (_disposed) {
      await vpc!.dispose();
      return;
    }

    _activeVpc?.removeListener(_onControllerUpdate);
    if (_activeVpc != null) {
      _pendingDispose.add(_activeVpc!);
      scheduleMicrotask(_flushPendingDispose);
    }

    _activeVpc = vpc;
    _activeVideoIndex = index;
    _boundaryFired = false;
    _preloadStarted = false;
    _activeVpc!.addListener(_onControllerUpdate);
    if (_playbackSpeed != 1.0) {
      await _activeVpc!.setPlaybackSpeed(_playbackSpeed);
    }
    // No _updateSnapshot here — suppressed while seek is in flight.
  }

  void dispose() {
    _disposed = true;
    _activeVpc?.removeListener(_onControllerUpdate);
    _activeVpc?.dispose();
    _preloadedVpc?.dispose();
    for (final vpc in _pendingDispose) {
      vpc.dispose();
    }
    snapshot.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _loadSegment(int index) async {
    final entry = schedule[index];

    // Reuse preloaded controller if it's for the right segment.
    VideoPlayerController? vpc;
    if (_preloadedVpc != null && index == _activeVideoIndex + 1) {
      vpc = _preloadedVpc;
      _preloadedVpc = null;
    } else {
      await _discardPreloaded();
      _log.info('_loadSegment[$index]: initializing ${entry.uri}');
      vpc = _createController(entry.uri);
      try {
        await vpc.initialize().timeout(_initTimeout);
        _log.info('_loadSegment[$index]: initialized in '
            '${vpc.value.duration.inMilliseconds}ms duration');
      } on Object catch (e) {
        _log.warning('_loadSegment[$index]: init failed for ${entry.uri}', e);
        await vpc.dispose();
        if (!_disposed) {
          snapshot.value = PlaybackSnapshot(
            globalPosition: _currentGlobalPosition(),
            totalDuration: totalDuration,
            isPlaying: false,
            activeVideoIndex: index,
            isComplete: false,
            error: 'Failed to load video: $e',
          );
        }
        return;
      }
    }

    // Drop the freshly-initialized controller if the player was disposed
    // mid-flight (mirrors the guard in `_preloadNextSegment`).
    if (_disposed) {
      await vpc!.dispose();
      return;
    }

    // Remove listener from old controller before swapping.
    _activeVpc?.removeListener(_onControllerUpdate);
    if (_activeVpc != null) {
      _pendingDispose.add(_activeVpc!);
      // Dispose on next microtask to avoid tearing down VideoPlayer widget
      // in the same frame.
      scheduleMicrotask(_flushPendingDispose);
    }

    _activeVpc = vpc;
    _activeVideoIndex = index;
    _boundaryFired = false;
    _preloadStarted = false;
    _activeVpc!.addListener(_onControllerUpdate);
    if (_playbackSpeed != 1.0) {
      await _activeVpc!.setPlaybackSpeed(_playbackSpeed);
    }

    _updateSnapshot();
  }

  void _onControllerUpdate() {
    if (_disposed) return;
    final vpc = _activeVpc;
    if (vpc == null || !vpc.value.isInitialized) return;

    final posMs = vpc.value.position.inMilliseconds;
    final durMs = vpc.value.duration.inMilliseconds;
    if (durMs == 0) return;

    final frac = posMs / durMs;

    // Pre-initialise the next segment when we're 80% through.
    if (!_preloadStarted && frac > 0.8) {
      _preloadStarted = true;
      final nextIndex = _activeVideoIndex + 1;
      if (nextIndex < schedule.length) {
        unawaited(_preloadNextSegment(nextIndex));
      }
    }

    // Advance when within 300ms of the segment end.
    final remaining = durMs - posMs;
    if (!_boundaryFired && vpc.value.isPlaying && remaining <= 300) {
      _boundaryFired = true;
      unawaited(_advanceToNext());
      return; // snapshot will be updated by _advanceToNext
    }

    _updateSnapshot();
  }

  Future<void> _advanceToNext() async {
    if (_disposed) return;

    final nextIndex = _activeVideoIndex + 1;
    if (nextIndex >= schedule.length) {
      // Reached the end of the lecture.
      _wantPlaying = false;
      await _activeVpc?.pause();
      if (!_disposed) {
        snapshot.value = PlaybackSnapshot(
          globalPosition: totalDuration,
          totalDuration: totalDuration,
          isPlaying: false,
          activeVideoIndex: _activeVideoIndex,
          isComplete: true,
        );
      }
      return;
    }

    await _loadSegment(nextIndex);
    if (_disposed) return;

    if (_wantPlaying) {
      await _activeVpc?.play();
    }
    _updateSnapshot();
  }

  Future<void> _preloadNextSegment(int index) async {
    if (_disposed || index >= schedule.length) return;
    final vpc = _createController(schedule[index].uri);
    try {
      await vpc.initialize().timeout(_initTimeout);
    } on Object catch (e) {
      _log.fine('preload[$index]: ${schedule[index].uri} failed: $e');
      await vpc.dispose();
      return;
    }
    if (_disposed) {
      await vpc.dispose();
      return;
    }
    _preloadedVpc = vpc;
  }

  Future<void> _discardPreloaded() async {
    final vpc = _preloadedVpc;
    _preloadedVpc = null;
    await vpc?.dispose();
  }

  void _flushPendingDispose() {
    for (final vpc in List.of(_pendingDispose)) {
      vpc.dispose();
    }
    _pendingDispose.clear();
  }

  VideoPlayerController _createController(Uri uri) {
    // Without this, video_player installs a lifecycle observer that pauses
    // the controller on AppLifecycleState.paused — cutting iOS audio ~1s
    // after backgrounding despite UIBackgroundModes: audio being set.
    final options = VideoPlayerOptions(allowBackgroundPlayback: true);
    if (uri.isScheme('file')) {
      return VideoPlayerController.file(
        File(uri.toFilePath()),
        videoPlayerOptions: options,
      );
    }
    return VideoPlayerController.networkUrl(uri, videoPlayerOptions: options);
  }

  int _videoIndexForGlobalTime(double globalSeconds) {
    for (var i = schedule.length - 1; i >= 0; i--) {
      if (globalSeconds >= schedule[i].globalStartTime) return i;
    }
    return 0;
  }

  double _currentGlobalPosition() {
    final vpc = _activeVpc;
    if (vpc == null || !vpc.value.isInitialized) {
      return schedule[_activeVideoIndex].globalStartTime;
    }
    return schedule[_activeVideoIndex].globalStartTime +
        vpc.value.position.inMilliseconds / 1000.0;
  }

  void _updateSnapshot() {
    if (_disposed || _seekInProgress) return;
    final vpc = _activeVpc;
    snapshot.value = PlaybackSnapshot(
      globalPosition: _currentGlobalPosition(),
      totalDuration: totalDuration,
      isPlaying: vpc?.value.isPlaying ?? false,
      activeVideoIndex: _activeVideoIndex,
      isComplete: false,
    );
  }
}

void unawaited(Future<void> future) {
  // Intentionally not awaited — callers acknowledge that.
}
