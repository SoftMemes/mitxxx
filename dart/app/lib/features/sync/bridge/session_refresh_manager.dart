import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/learn_api_session_bootstrap.dart'
    as learn_bootstrap;
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/sync_manager.dart';

final _log = Logger('sync.session-refresh');

/// Handles `SessionRefreshRequired` events from the sync isolate by running
/// the appropriate main-side recovery path and reporting the result back
/// through [SyncManager].
///
/// - [SessionKind.lms]: silent `client.establishLmsSession()`. Escalates to
///   `mitxonline` on failure.
/// - [SessionKind.learnApi]: silent `bootstrapLearnApiSession`. Escalates to
///   `mitxonline` on failure.
/// - [SessionKind.mitxonline]: surfaces the reauth prompt via
///   [ReauthController] and awaits the terminal outcome.
///
/// On success, the manager sends `ReloadCookies` so the isolate's Dio picks
/// up whatever the main-side flow wrote to the cookie jar.
class SessionRefreshManager {
  SessionRefreshManager({
    required SyncManager syncManager,
    required DioClient client,
    required ReauthController reauthController,
  })  : _syncManager = syncManager,
        _client = client,
        _reauthController = reauthController {
    _sub = _syncManager.events
        .where((e) => e is SessionRefreshRequired)
        .cast<SessionRefreshRequired>()
        .listen(_handle);
  }

  final SyncManager _syncManager;
  final DioClient _client;
  final ReauthController _reauthController;
  late final StreamSubscription<SessionRefreshRequired> _sub;

  /// Tracks the currently-handled refresh so overlapping
  /// `SessionRefreshRequired` events don't spawn parallel recoveries.
  Future<void>? _inFlight;

  Future<void> dispose() async {
    await _sub.cancel();
    await _inFlight;
  }

  void _handle(SessionRefreshRequired event) {
    final pending = _inFlight;
    if (pending != null) {
      _log.info('refresh already in flight for previous kind — chaining');
      _inFlight = pending.then((_) => _run(event.kind));
      return;
    }
    _inFlight = _run(event.kind).whenComplete(() => _inFlight = null);
  }

  Future<void> _run(SessionKind kind) async {
    switch (kind) {
      case SessionKind.lms:
        await _runLms();
      case SessionKind.learnApi:
        await _runLearnApi();
      case SessionKind.mitxonline:
        await _runMitxOnline();
    }
  }

  Future<void> _runLms() async {
    try {
      await _client.establishLmsSession();
      _log.info('silent LMS refresh succeeded');
      _syncManager
        ..reloadCookies()
        ..signalSessionRefreshCompleted(SessionKind.lms);
    } on Object catch (e, st) {
      _log.warning('silent LMS refresh failed — escalating to mitxonline', e, st);
      await _runMitxOnline();
    }
  }

  Future<void> _runLearnApi() async {
    try {
      await learn_bootstrap.bootstrapLearnApiSession(_client);
      _log.info('silent learnApi refresh succeeded');
      _syncManager
        ..reloadCookies()
        ..signalSessionRefreshCompleted(SessionKind.learnApi);
    } on Object catch (e, st) {
      _log.warning(
        'silent learnApi refresh failed — escalating to mitxonline',
        e,
        st,
      );
      await _runMitxOnline();
    }
  }

  Future<void> _runMitxOnline() async {
    // Capture the outcome stream BEFORE surfacing the prompt — `request()`
    // emits synchronously on controllers that already have the prompt up,
    // but a fresh subscription must be live before the user acts.
    final outcome = _reauthController.outcomes.first;
    _reauthController.request();
    final bool succeeded;
    try {
      succeeded = await outcome;
    } on Object catch (e, st) {
      _log.warning('reauth outcome stream errored', e, st);
      _syncManager.signalSessionRefreshFailed(SessionKind.mitxonline, '$e');
      return;
    }
    if (succeeded) {
      _log.info('user reauth succeeded');
      _syncManager
        ..reloadCookies()
        ..signalSessionRefreshCompleted(SessionKind.mitxonline);
    } else {
      _log.info('user reauth dismissed');
      _syncManager.signalSessionRefreshFailed(SessionKind.mitxonline);
    }
  }
}
