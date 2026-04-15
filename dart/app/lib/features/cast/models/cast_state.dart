import 'package:emajtee/features/cast/models/cast_queue_item.dart';

enum CastConnectionStatus {
  /// No active cast session.
  disconnected,

  /// Connecting to a device.
  connecting,

  /// Session active and queue loaded.
  connected,
}

/// Snapshot of the current cast session state, polled every ~1 second.
class CastState {
  const CastState({
    required this.status,
    required this.queue,
    this.deviceName,
    this.globalPosition = 0.0,
    this.totalDuration = 0.0,
    this.activeItemIndex = 0,
    this.isPlaying = false,
    this.speed = 1.0,
  });

  const CastState.disconnected()
      : status = CastConnectionStatus.disconnected,
        queue = const [],
        deviceName = null,
        globalPosition = 0.0,
        totalDuration = 0.0,
        activeItemIndex = 0,
        isPlaying = false,
        speed = 1.0;

  final CastConnectionStatus status;

  /// The queue items for the current lecture. Empty when disconnected.
  final List<CastQueueItem> queue;

  /// Display name of the cast receiver (e.g. "Living Room TV").
  final String? deviceName;

  /// Current playback position on the full stitched lecture timeline (seconds).
  final double globalPosition;

  /// Total duration of the stitched lecture (sum of all queue-item durations).
  final double totalDuration;

  /// Index into [queue] of the item currently playing on the receiver.
  final int activeItemIndex;

  final bool isPlaying;

  /// Current playback speed (1.0 = normal).
  final double speed;

  bool get isConnected => status == CastConnectionStatus.connected;
  bool get isConnecting => status == CastConnectionStatus.connecting;

  CastState copyWith({
    CastConnectionStatus? status,
    List<CastQueueItem>? queue,
    String? deviceName,
    double? globalPosition,
    double? totalDuration,
    int? activeItemIndex,
    bool? isPlaying,
    double? speed,
  }) =>
      CastState(
        status: status ?? this.status,
        queue: queue ?? this.queue,
        deviceName: deviceName ?? this.deviceName,
        globalPosition: globalPosition ?? this.globalPosition,
        totalDuration: totalDuration ?? this.totalDuration,
        activeItemIndex: activeItemIndex ?? this.activeItemIndex,
        isPlaying: isPlaying ?? this.isPlaying,
        speed: speed ?? this.speed,
      );
}
