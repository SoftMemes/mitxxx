// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/auth/models/user.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auth_provider.g.dart';

final _log = Logger('auth');

// Placeholder user returned on cold start when cookies exist.
// The real user profile is only needed for display purposes, which is
// not used anywhere in the current UI.
const _kCachedUser = User(
  id: 0,
  username: '',
  name: '',
  email: '',
  isAuthenticated: true,
  isAnonymous: false,
);

@Riverpod(keepAlive: true)
class Auth extends _$Auth {
  @override
  Future<User?> build() async {
    final client = ref.read(dioClientProvider)
      // Attach the 401 interceptor here (after auth_provider is created)
      // to avoid a circular dependency in the provider graph.
      ..addAuthInterceptor(
        onAuthFailed: () => Future<void>.delayed(Duration.zero, signOut),
      );

    // Offline-first: if we have persisted cookies, treat the user as
    // authenticated without hitting the network. The LMS session will be
    // re-established when the user triggers a sync. If we have no cookies,
    // redirect to login.
    if (client.hasCookies) {
      _log.info('build: cookies found — resuming session offline-first');
      // Best-effort LMS session refresh in background so that the first
      // sync is more likely to succeed immediately.
      unawaited(_establishLmsSession(client));
      return _kCachedUser;
    }

    _log.info('build: no cookies — user must log in');
    return null;
  }

  /// Hits the LMS OAuth login endpoint so courses.learn.mit.edu issues us
  /// fresh session + JWT cookies. Safe to call on every startup.
  Future<void> _establishLmsSession(DioClient client) async {
    try {
      await client.establishLmsSession();
    } on Object catch (e, st) {
      _log.warning('_establishLmsSession failed', e, st);
    }
  }

  /// Called after the WebView OAuth flow completes and cookies are injected
  /// into the Dio CookieJar. Triggers LMS OAuth then marks the user as
  /// authenticated.
  Future<void> onLoginComplete() async {
    _log.info('onLoginComplete: verifying mitxonline session before LMS OAuth');
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = ref.read(dioClientProvider);

      // Sanity-check: hit current_user on mitxonline BEFORE the LMS OAuth.
      try {
        final pre = await client.mitxOnline
            .get<Map<String, dynamic>>('/api/v0/users/current_user/');
        _log.info(
          'onLoginComplete: mitxonline pre-check is_authenticated=${pre.data?['is_authenticated']}',
        );
        if (pre.data?['is_authenticated'] != true) {
          throw Exception(
            'mitxonline session cookie not accepted — pre-check returned '
            'is_authenticated=false. LMS OAuth cannot proceed.',
          );
        }
      } on DioException catch (e, st) {
        _log.severe(
          'onLoginComplete: mitxonline pre-check failed status=${e.response?.statusCode}',
          e,
          st,
        );
        rethrow;
      }

      // Trigger LMS OAuth handshake — sets session + JWT cookies on the LMS.
      await _establishLmsSession(client);

      // Flush any LMS content cached while unauthenticated.
      final db = ref.read(appDatabaseProvider);
      await db.clearLmsCache();
      _log.info('onLoginComplete: cleared LMS cache');

      // Return placeholder user — home screen will trigger an initial sync.
      return _kCachedUser;
    });
    if (state.hasError) {
      _log.severe('onLoginComplete: guard caught error', state.error, state.stackTrace);
    }
  }

  /// Sign out: clears all cookies, cached data, and secure storage.
  Future<void> signOut() async {
    _log.info('signOut: clearing session');
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

    // Clear Dio cookie store (also wipes the SecureCookieStore entry).
    await client.clearCookies();

    // Clear the native WebView cookie store so re-opening login doesn't
    // auto-reauthenticate via a persisted Keycloak SSO cookie.
    await CookieManager.instance().deleteAllCookies();

    // Clear all cached course data from Drift.
    await db.clearAll();

    state = const AsyncData(null);
  }
}
