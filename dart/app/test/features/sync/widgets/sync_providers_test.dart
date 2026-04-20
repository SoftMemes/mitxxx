import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';

void main() {
  group('SyncManagerState.scope', () {
    test('returns default idle ScopeState when key is absent', () {
      const s = SyncManagerState();
      final scope = s.scope(ScopeIds.course('c1'));
      expect(scope.status, ScopeStatus.idle);
      expect(scope.completed, 0);
      expect(scope.total, 0);
    });

    test('returns stored ScopeState when key is present', () {
      final s = SyncManagerState(
        scopeStates: {
          ScopeIds.course('c1'): const ScopeState(
            status: ScopeStatus.syncing,
          ),
        },
      );
      expect(s.scope(ScopeIds.course('c1')).status, ScopeStatus.syncing);
    });
  });

  group('SyncManagerState.withScope', () {
    test('drops an idle+no-progress scope from the map', () {
      final s = SyncManagerState(
        scopeStates: {
          ScopeIds.course('c1'):
              const ScopeState(status: ScopeStatus.syncing),
        },
      ).withScope(ScopeIds.course('c1'), const ScopeState());
      expect(s.scopeStates, isEmpty);
    });

    test('keeps a scope with a non-idle status', () {
      final s = const SyncManagerState().withScope(
        ScopeIds.course('c1'),
        const ScopeState(status: ScopeStatus.syncing),
      );
      expect(
        s.scope(ScopeIds.course('c1')).status,
        ScopeStatus.syncing,
      );
    });

    test('keeps an error scope', () {
      final s = const SyncManagerState().withScope(
        ScopeIds.course('c1'),
        const ScopeState(status: ScopeStatus.error),
      );
      expect(s.scope(ScopeIds.course('c1')).status, ScopeStatus.error);
    });

    test('keeps a scope with progress counters even when idle', () {
      final s = const SyncManagerState().withScope(
        ScopeIds.course('c1'),
        const ScopeState(completed: 2, total: 5),
      );
      expect(s.scope(ScopeIds.course('c1')).completed, 2);
      expect(s.scope(ScopeIds.course('c1')).total, 5);
    });
  });

  group('CurrentOp variants', () {
    test('FullSyncOpInfo.scopeId = all-courses', () {
      expect(const FullSyncOpInfo().scopeId, ScopeIds.allCourses);
    });
    test('ListsRefreshOpInfo.scopeId = lists', () {
      expect(const ListsRefreshOpInfo().scopeId, ScopeIds.lists);
    });
    test('CourseSyncOpInfo.scopeId has course: prefix', () {
      expect(
        const CourseSyncOpInfo('c1').scopeId,
        ScopeIds.course('c1'),
      );
    });
    test('LectureSyncOpInfo.scopeId uses sequenceId', () {
      expect(
        const LectureSyncOpInfo('c1', 'seq-1').scopeId,
        ScopeIds.lecture('seq-1'),
      );
    });
  });
}
