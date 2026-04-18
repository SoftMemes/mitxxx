import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/features/sync/bridge/sync_event_ring_buffer.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';
import 'package:omnilect/features/sync/providers/sync_providers.dart';

/// Dev-only introspection view for the sync isolate: shows the current op,
/// per-scope sub-task counters, a scrolling event log, and a snapshot of
/// the video download manager's job counts.
class SyncDebuggerScreen extends ConsumerWidget {
  const SyncDebuggerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(syncManagerStateProvider);
    final state = stateAsync.value ?? const SyncManagerState();
    final buffer = ref.watch(syncEventRingBufferProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync debugger'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear log',
            onPressed: buffer.clear,
          ),
        ],
      ),
      body: ListView(
        children: [
          _CurrentOpCard(state: state),
          const Divider(height: 1),
          _ScopeList(scopes: state.scopeStates),
          const Divider(height: 1),
          _EventLog(buffer: buffer),
        ],
      ),
    );
  }
}

class _CurrentOpCard extends StatelessWidget {
  const _CurrentOpCard({required this.state});

  final SyncManagerState state;

  @override
  Widget build(BuildContext context) {
    final op = state.currentOp;
    final label = switch (op) {
      NoOp() => 'Idle',
      FullSyncOpInfo() => 'Full sync',
      ListsRefreshOpInfo() => 'Lists refresh',
      CourseSyncOpInfo(courseId: final id) => 'Course sync · $id',
      LectureSyncOpInfo(sequenceId: final seq) => 'Lecture sync · $seq',
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current op',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          if (state.reauthPending) ...[
            const SizedBox(height: 8),
            const Chip(
              avatar: Icon(Icons.lock_outline, size: 16),
              label: Text('Reauth pending'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScopeList extends StatelessWidget {
  const _ScopeList({required this.scopes});

  final Map<String, ScopeState> scopes;

  @override
  Widget build(BuildContext context) {
    if (scopes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No tracked scopes'),
      );
    }
    final entries = scopes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Scopes',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        for (final entry in entries)
          ListTile(
            dense: true,
            title: Text(entry.key),
            subtitle: Text(entry.value.toString()),
          ),
      ],
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.buffer});

  final SyncEventRingBuffer buffer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: buffer,
      builder: (context, _) {
        final items = buffer.entries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Events (${items.length})',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('No events yet'),
              )
            else
              for (final entry in items)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(_formatEvent(entry.event)),
                  subtitle: Text(_formatTime(entry.at)),
                ),
          ],
        );
      },
    );
  }

  static String _formatTime(DateTime at) {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    final ms = at.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  static String _formatEvent(SyncEvent event) {
    return switch (event) {
      IsolateReady() => 'IsolateReady',
      IsolateExited() => 'IsolateExited',
      OpStarted(:final scopeId, :final trigger) =>
        'OpStarted $scopeId [$trigger]',
      OpCompleted(:final scopeId, :final itemsSynced) =>
        'OpCompleted $scopeId (items=$itemsSynced)',
      OpCancelled(:final scopeId) => 'OpCancelled $scopeId',
      OpErrored(:final scopeId, :final message) =>
        'OpErrored $scopeId: $message',
      ScopeStateChanged(:final scopeId, :final state) =>
        'ScopeStateChanged $scopeId → ${state.status.name}',
      SubtaskProgress(:final scopeId, :final completed, :final total) =>
        'SubtaskProgress $scopeId $completed/$total',
      RemovedVideoUrls(:final urls, :final courseId) =>
        'RemovedVideoUrls ${urls.length} in $courseId',
      SessionRefreshRequired(:final kind) =>
        'SessionRefreshRequired ${kind.name}',
      AnalyticsEventForwarded(:final eventName) =>
        'Analytics $eventName',
      LogRecordForwarded(:final loggerName, :final message) =>
        'Log[$loggerName] $message',
      DbInvalidated(:final family, :final arg) =>
        'DbInvalidated $family${arg == null ? '' : '($arg)'}',
      PrefetchCourseImages(:final urls) =>
        'PrefetchCourseImages (${urls.length})',
      ValidateTrackedLecture(:final courseId) =>
        'ValidateTrackedLecture $courseId',
    };
  }
}
