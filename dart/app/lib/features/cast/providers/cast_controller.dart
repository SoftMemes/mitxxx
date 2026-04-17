// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/features/cast/models/cast_queue_item.dart';
import 'package:omnilect/features/cast/models/cast_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'cast_controller.g.dart';

final _log = Logger('cast');

/// Manages the Google Cast session lifecycle, queue loading, and position sync.
///
/// Use [castControllerProvider] to watch the current [CastState] from any
/// widget. Call methods on the notifier (via `.notifier`) to control playback.
@Riverpod(keepAlive: true)
class CastController extends _$CastController {
  Timer? _pollTimer;
  StreamSubscription<GoogleCastSession?>? _sessionSub;
  StreamSubscription<GoggleCastMediaStatus?>? _mediaStatusSub;

  // Pre-assigned item IDs: item at index i has id = i + 1 (1-based).
  // This lets us map currentItemId back to a 0-based queue index reliably.
  List<int> _itemIds = [];

  // Per-item global start times for computing globalPosition from
  // (activeItemIndex, withinItemPosition).
  List<double> _itemStartTimes = [];

  @override
  CastState build() {
    ref.onDispose(_cleanup);
    _init();
    return const CastState.disconnected();
  }

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------

  void _init() {
    GoogleCastDiscoveryManager.instance.startDiscovery();

    _sessionSub = GoogleCastSessionManager.instance.currentSessionStream
        .listen(_onSessionChange);
  }

  void _cleanup() {
    _pollTimer?.cancel();
    _sessionSub?.cancel();
    _mediaStatusSub?.cancel();
    GoogleCastDiscoveryManager.instance.stopDiscovery();
  }

  // ---------------------------------------------------------------------------
  // Session events
  // ---------------------------------------------------------------------------

  void _onSessionChange(GoogleCastSession? session) {
    if (session == null ||
        session.connectionState == GoogleCastConnectState.disconnected) {
      // Disconnected.
      _pollTimer?.cancel();
      _mediaStatusSub?.cancel();
      state = state.copyWith(
        status: CastConnectionStatus.disconnected,
        isPlaying: false,
      );
      return;
    }

    final name = session.device?.friendlyName ?? 'Cast device';
    state = state.copyWith(
      status: CastConnectionStatus.connected,
      deviceName: name,
    );

    // Subscribe to media status for item-index / player-state updates.
    _mediaStatusSub?.cancel();
    _mediaStatusSub = GoogleCastRemoteMediaClient.instance.mediaStatusStream
        .listen(_onMediaStatus);

    // Start 1 s position polling.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _onMediaStatus(GoggleCastMediaStatus? status) {
    if (status == null) return;
    final isPlaying = status.playerState == CastMediaPlayerState.playing;

    // Map receiver-assigned item ID back to our 0-based index.
    final itemIdx = _resolveItemIndex(status.currentItemId);

    state = state.copyWith(
      activeItemIndex: itemIdx,
      isPlaying: isPlaying,
      speed: status.playbackRate.toDouble(),
    );
  }

  void _poll() {
    final posSeconds =
        GoogleCastRemoteMediaClient.instance.playerPosition.inMilliseconds /
            1000.0;

    final idx = state.activeItemIndex;
    final itemStart =
        idx < _itemStartTimes.length ? _itemStartTimes[idx] : 0.0;
    final global = (itemStart + posSeconds).clamp(0.0, state.totalDuration);

    state = state.copyWith(globalPosition: global);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Connect to [device] without loading a queue yet.
  Future<void> connectToDevice(GoogleCastDevice device) async {
    state = state.copyWith(status: CastConnectionStatus.connecting);
    await GoogleCastSessionManager.instance.startSessionWithDevice(device);
  }

  /// Disconnect from the current cast session.
  Future<void> disconnect() async {
    await GoogleCastSessionManager.instance.endSessionAndStopCasting();
  }

  /// Load [queue] into the current cast session, starting from [startIndex] at
  /// [startOffset] seconds into that item.
  Future<void> loadQueue(
    List<CastQueueItem> queue, {
    int startIndex = 0,
    double startOffset = 0,
  }) async {
    if (queue.isEmpty) return;

    // Compute per-item global start times.
    _itemStartTimes = [];
    var t = 0.0;
    for (final item in queue) {
      _itemStartTimes.add(t);
      t += item.duration;
    }
    final totalDuration = t;

    // Pre-assign 1-based item IDs so we can map back from currentItemId.
    _itemIds = List.generate(queue.length, (i) => i + 1);

    final queueItems = queue.asMap().entries.map((e) {
      final i = e.key;
      final item = e.value;
      return GoogleCastQueueItem(
        itemId: _itemIds[i],
        mediaInformation: GoogleCastMediaInformation(
          contentId: item.verticalId,
          streamType: CastMediaStreamType.buffered,
          contentType: 'video/mp4',
          contentUrl: item.remoteUrl,
          metadata: GoogleCastGenericMediaMetadata(title: item.title),
        ),
        preLoadTime: i < queue.length - 1
            ? const Duration(seconds: 10)
            : null,
      );
    }).toList();

    await GoogleCastRemoteMediaClient.instance.queueLoadItems(
      queueItems,
      options: GoogleCastQueueLoadOptions(
        startIndex: startIndex,
        playPosition: Duration(
          milliseconds: (startOffset * 1000).round(),
        ),
      ),
    );

    state = state.copyWith(
      queue: queue,
      totalDuration: totalDuration,
      activeItemIndex: startIndex,
      globalPosition: _itemStartTimes[startIndex] + startOffset,
    );

    _log.fine(
        'Cast queue loaded: ${queue.length} items, starting at $startIndex/$startOffset');
  }

  Future<void> play() async {
    await GoogleCastRemoteMediaClient.instance.play();
    state = state.copyWith(isPlaying: true);
  }

  Future<void> pause() async {
    await GoogleCastRemoteMediaClient.instance.pause();
    state = state.copyWith(isPlaying: false);
  }

  /// Seek to [globalSeconds] on the stitched lecture timeline.
  Future<void> seekGlobal(double globalSeconds) async {
    if (state.queue.isEmpty) return;
    final clamped = globalSeconds.clamp(0.0, state.totalDuration);

    // Determine which queue item contains the target position.
    var targetItemIndex = 0;
    for (var i = 0; i < _itemStartTimes.length; i++) {
      if (_itemStartTimes[i] <= clamped) targetItemIndex = i;
    }
    final withinItem = clamped - _itemStartTimes[targetItemIndex];

    if (targetItemIndex == state.activeItemIndex) {
      // Same queue item — plain seek within it.
      await GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(
          position: Duration(milliseconds: (withinItem * 1000).round()),
          resumeState: GoogleCastMediaResumeState.unchanged,
        ),
      );
    } else {
      // Different item — jump to the item first, then seek within it.
      final itemId = _itemIds[targetItemIndex];
      await GoogleCastRemoteMediaClient.instance
          .queueJumpToItemWithId(itemId);
      // Give the receiver a moment to transition, then seek within the item.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(
          position: Duration(milliseconds: (withinItem * 1000).round()),
          resumeState: GoogleCastMediaResumeState.unchanged,
        ),
      );
    }

    state = state.copyWith(
      globalPosition: clamped,
      activeItemIndex: targetItemIndex,
    );
  }

  Future<void> setSpeed(double speed) async {
    await GoogleCastRemoteMediaClient.instance.setPlaybackRate(speed);
    state = state.copyWith(speed: speed);
  }

  /// Stream of discovered Cast devices.
  Stream<List<GoogleCastDevice>> get devicesStream =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Map a receiver-assigned Cast item ID back to our 0-based queue index.
  int _resolveItemIndex(int? castItemId) {
    if (castItemId == null) return state.activeItemIndex;
    final idx = _itemIds.indexOf(castItemId);
    return idx >= 0 ? idx : state.activeItemIndex;
  }
}
