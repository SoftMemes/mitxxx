import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

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
        totalDuration = schedule.fold(0, (sum, e) => sum + e.duration);

  final List<VideoScheduleEntry> schedule;

  /// Total duration of all segments combined (seconds, from metadata).
  final double totalDuration;

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
    _wantPlaying = false;
    await _activeVpc!.pause();
    _updateSnapshot();
  }

  /// Seeks to [globalSeconds] anywhere in the stitched timeline.
  Future<void> seekGlobal(double globalSeconds) async {
    if (_disposed) return;

    final clamped = globalSeconds.clamp(0.0, totalDuration);
    final targetIndex = _videoIndexForGlobalTime(clamped);

    if (targetIndex != _activeVideoIndex) {
      // Cancel any pending preloads for the old segment.
      await _discardPreloaded();
      await _loadSegment(targetIndex);
    }

    final within = clamped - schedule[targetIndex].globalStartTime;
    await _activeVpc!
        .seekTo(Duration(milliseconds: (within * 1000).round()));

    _boundaryFired = false;
    _preloadStarted = false;

    if (_wantPlaying) {
      await _activeVpc!.play();
    }

    _updateSnapshot();
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
      vpc = _createController(entry.uri);
      try {
        await vpc.initialize();
      } on Object catch (e) {
        await vpc.dispose();
        if (!_disposed) {
          snapshot.value = PlaybackSnapshot(
            globalPosition: _currentGlobalPosition(),
            totalDuration: totalDuration,
            isPlaying: false,
            activeVideoIndex: index,
            isComplete: false,
            error: 'Failed to load segment: $e',
          );
        }
        return;
      }
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
      await vpc.initialize();
    } on Object {
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
    if (uri.isScheme('file')) {
      return VideoPlayerController.file(File(uri.toFilePath()));
    }
    return VideoPlayerController.networkUrl(uri);
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
    if (_disposed) return;
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
