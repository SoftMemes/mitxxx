// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reauth_provider.g.dart';

/// Describes a sync operation that was halted by a stale-session failure and
/// should be re-run once the user signs back in.
sealed class PendingSyncOperation {
  const PendingSyncOperation({required this.trigger});
  final String trigger;
}

final class SyncAllOperation extends PendingSyncOperation {
  const SyncAllOperation({super.trigger = kTriggerManual});
}

final class SyncCourseOperation extends PendingSyncOperation {
  const SyncCourseOperation({
    required this.courseId,
    super.trigger = kTriggerManual,
  });
  final String courseId;
}

/// State held by [ReauthController]. Non-null means a sync just hit a stale
/// session; the prompt is shown unless [isLoggingIn] is true (which indicates
/// the user already accepted the prompt and is mid-login, so the router
/// should allow `/login`).
class ReauthRequest {
  const ReauthRequest({required this.operation, required this.isLoggingIn});
  final PendingSyncOperation operation;
  final bool isLoggingIn;

  ReauthRequest copyWith({bool? isLoggingIn}) => ReauthRequest(
        operation: operation,
        isLoggingIn: isLoggingIn ?? this.isLoggingIn,
      );
}

/// Coordinates the "session expired" flow: receives a signal from the sync
/// layer when a 401/403 surfaces, asks the user (via the global dialog shown
/// by `ReauthGate`) whether to re-authenticate, and — on success — resumes
/// the originating sync operation.
///
/// The user's cached content is left untouched; only a full Settings → Sign
/// Out wipes the local database.
@Riverpod(keepAlive: true)
class ReauthController extends _$ReauthController {
  @override
  ReauthRequest? build() => null;

  /// Called by the sync layer when it detects a stale session. Coalesces:
  /// while a request is pending (or the user is mid-login), subsequent
  /// triggers are ignored so we don't stack dialogs or clobber a retry target.
  void request(PendingSyncOperation op) {
    if (state != null) return;
    state = ReauthRequest(operation: op, isLoggingIn: false);
  }

  /// User tapped "Dismiss" — drop the pending request and halt any in-flight
  /// sync work so we don't keep firing 401s in the background.
  void dismiss() {
    if (state == null) return;
    state = null;
    ref.read(syncControllerProvider.notifier).halt();
  }

  /// User tapped "Log in" — hide the dialog but keep the pending op around so
  /// the router permits `/login` and so login completion can trigger a retry.
  void beginLogin() {
    final cur = state;
    if (cur == null || cur.isLoggingIn) return;
    state = cur.copyWith(isLoggingIn: true);
  }

  /// Called by `LoginScreen` after `onLoginComplete` succeeds. Clears the
  /// request and kicks off the retry in the background.
  void onLoginSucceeded() {
    final cur = state;
    if (cur == null) return;
    final op = cur.operation;
    state = null;
    unawaited(_retry(op));
  }

  /// Called if `LoginScreen` is torn down without a successful login (e.g.
  /// the user backs out). Re-surfaces the prompt so the user can choose
  /// again instead of being silently stranded.
  void onLoginAbandoned() {
    final cur = state;
    if (cur == null || !cur.isLoggingIn) return;
    state = cur.copyWith(isLoggingIn: false);
  }

  Future<void> _retry(PendingSyncOperation op) async {
    final sync = ref.read(syncControllerProvider.notifier);
    switch (op) {
      case SyncAllOperation():
        await sync.syncAll(trigger: op.trigger);
      case SyncCourseOperation():
        await sync.syncCourse(op.courseId, trigger: op.trigger);
    }
  }
}
