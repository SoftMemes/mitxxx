// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:emajtee/core/network/dio_client.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/auth/models/user.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auth_provider.g.dart';

final _log = Logger('auth');

@Riverpod(keepAlive: true)
class Auth extends _$Auth {
  static const _storage = FlutterSecureStorage();

  @override
  Future<User?> build() async {
    final client = ref.read(dioClientProvider)

    // Attach the 401 interceptor here (after auth_provider is created)
    // to avoid a circular dependency in the provider graph.
    ..addAuthInterceptor(
      onAuthFailed: () => Future<void>.delayed(Duration.zero, signOut),
    );

    // Try to resume an existing session on startup.
    _log.info('build: checking for existing session');
    try {
      final response = await client.mitxOnline
          .get<Map<String, dynamic>>('/api/v0/users/current_user/');
      _log.fine('build: current_user status=${response.statusCode} data=${response.data}');
      // The API returns a skeleton object with all fields null when
      // unauthenticated. Only parse into the User model once we know the
      // caller is authenticated, to avoid Freezed's non-null casts exploding.
      if (response.data?['is_authenticated'] != true) {
        _log.info('build: no active session (is_authenticated=false)');
        return null;
      }
      final user = User.fromJson(response.data!);
      _log.info('build: session resumed, user=${user.username}');

      // Our PersistCookieJar keeps the mitxonline session across restarts,
      // but the LMS-side JWT cookies are short-lived. Proactively run the
      // LMS OAuth handshake so the LMS recognises us for subsequent API
      // calls. If it fails, the 401 interceptor will still retry later.
      unawaited(_establishLmsSession(client));

      return user;
    } on Object catch (e, st) {
      _log.warning('build: session check failed', e, st);
    }
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
  /// into the Dio CookieJar. Triggers LMS OAuth then verifies the session.
  Future<void> onLoginComplete() async {
    _log.info('onLoginComplete: verifying mitxonline session before LMS OAuth');
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = ref.read(dioClientProvider);

      // Sanity-check: hit current_user on mitxonline BEFORE the LMS OAuth.
      // If our captured session cookie works, this must return
      // is_authenticated=true. If not, the cookie transfer is broken and
      // the LMS OAuth handshake can't possibly succeed.
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

      // Verify and return the authenticated user.
      try {
        final response = await client.mitxOnline
            .get<Map<String, dynamic>>('/api/v0/users/current_user/');
        _log.fine('onLoginComplete: current_user status=${response.statusCode} data=${response.data}');
        if (response.data?['is_authenticated'] != true) {
          throw Exception('current_user returned is_authenticated=false');
        }
        final user = User.fromJson(response.data!);
        _log.info('onLoginComplete: signed in as ${user.username}');
        return user;
      } on DioException catch (e, st) {
        _log.severe('onLoginComplete: current_user failed status=${e.response?.statusCode}', e, st);
        rethrow;
      }
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

    // Clear Dio cookie jar (PersistCookieJar — also wipes secure storage entries).
    await client.cookieJar.deleteAll();

    // Clear the native WebView cookie store so re-opening login doesn't
    // auto-reauthenticate via a persisted Keycloak SSO cookie.
    await CookieManager.instance().deleteAllCookies();

    // Clear all cached course data from Drift.
    await db.clearAll();

    // Clear any remaining persisted secure storage.
    await _storage.deleteAll();

    state = const AsyncData(null);
  }
}
