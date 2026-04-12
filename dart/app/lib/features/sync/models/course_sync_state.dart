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
