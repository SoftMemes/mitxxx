/// Kinds of session-refresh required when a sub-task returns 401/403.
///
/// `lms` and `learnApi` are refreshed silently by the main isolate (existing
/// bootstrap helpers — no dialog). `mitxonline` means the user's primary OAuth
/// session has expired and we must show the reauth dialog.
enum SessionKind { lms, learnApi, mitxonline }

/// Thrown inside the sync isolate when an HTTP call surfaces a 401/403.
///
/// Caught by `SyncManagerCore`, which transitions to `AwaitingSessionRefresh`
/// and emits a `SessionRefreshRequired` event so the main isolate can restore
/// the session.
class StaleSessionException implements Exception {
  const StaleSessionException(this.kind, [this.cause]);
  final SessionKind kind;
  final Object? cause;

  @override
  String toString() => 'StaleSessionException($kind)${cause == null ? '' : ': $cause'}';
}
