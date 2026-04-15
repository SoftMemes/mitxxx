import 'package:freezed_annotation/freezed_annotation.dart';

part 'course_sync_state.freezed.dart';

enum SyncStatus { idle, syncing, error }

@freezed
abstract class CourseSyncState with _$CourseSyncState {
  const factory CourseSyncState({
    @Default(SyncStatus.idle) SyncStatus status,
    DateTime? lastSyncedAt,
    String? errorMessage,
  }) = _CourseSyncState;
}

enum SequenceSyncStatus { idle, syncing, synced, error }

@freezed
abstract class SequenceSyncState with _$SequenceSyncState {
  const factory SequenceSyncState({
    @Default(SequenceSyncStatus.idle) SequenceSyncStatus status,
    DateTime? lastSyncedAt,
    String? errorMessage,
  }) = _SequenceSyncState;
}
