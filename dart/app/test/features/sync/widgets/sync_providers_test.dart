import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';

void main() {
  group('SyncManagerState.scope', () {
    test('returns default idle ScopeState when key is absent', () {
      const s = SyncManagerState();
      final scope = s.scope(ScopeIds.course('c1'));
      expect(scope.status, ScopeStatus.idle);
      expect(scope.lastSyncedAt, isNull);
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
    test('drops an idle+no-metadata scope from the map', () {
      final s = SyncManagerState(
        scopeStates: {
          ScopeIds.course('c1'):
              const ScopeState(status: ScopeStatus.syncing),
        },
      ).withScope(ScopeIds.course('c1'), const ScopeState());
      expect(s.scopeStates, isEmpty);
    });

    test('keeps a scope that carries lastSyncedAt', () {
      final now = DateTime.now();
      final s = const SyncManagerState().withScope(
        ScopeIds.course('c1'),
        ScopeState(lastSyncedAt: now),
      );
      expect(s.scope(ScopeIds.course('c1')).lastSyncedAt, now);
    });

    test('keeps an error scope even with no lastSyncedAt', () {
      final s = const SyncManagerState().withScope(
        ScopeIds.course('c1'),
        const ScopeState(
          status: ScopeStatus.error,
          errorMessage: 'boom',
        ),
      );
      expect(s.scope(ScopeIds.course('c1')).status, ScopeStatus.error);
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
