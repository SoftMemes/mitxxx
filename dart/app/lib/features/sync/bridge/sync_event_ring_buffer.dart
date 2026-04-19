import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// A bounded ring buffer of recent [SyncEvent]s. Wired on the main isolate
/// so the dev debugger can render a scrolling event log without the isolate
/// retaining anything itself.
class SyncEventRingBuffer extends ChangeNotifier {
  SyncEventRingBuffer({this.capacity = 500});

  final int capacity;
  final Queue<TimestampedSyncEvent> _queue = Queue<TimestampedSyncEvent>();

  UnmodifiableListView<TimestampedSyncEvent> get entries =>
      UnmodifiableListView(_queue.toList(growable: false));

  StreamSubscription<SyncEvent>? _sub;

  void bind(Stream<SyncEvent> events) {
    _sub?.cancel();
    _sub = events.listen(add);
  }

  void add(SyncEvent event) {
    _queue.addFirst(TimestampedSyncEvent(DateTime.now(), event));
    while (_queue.length > capacity) {
      _queue.removeLast();
    }
    notifyListeners();
  }

  void clear() {
    _queue.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

@immutable
class TimestampedSyncEvent {
  const TimestampedSyncEvent(this.at, this.event);
  final DateTime at;
  final SyncEvent event;
}
