// ignore_for_file: uri_has_not_been_generated
import 'package:dio/dio.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/auth/models/user.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auth_provider.g.dart';

@Riverpod(keepAlive: true)
class Auth extends _$Auth {
  static const _storage = FlutterSecureStorage();

  @override
  Future<User?> build() async {
    final client = ref.read(dioClientProvider);

    // Attach the 401 interceptor here (after auth_provider is created)
    // to avoid a circular dependency in the provider graph.
    client.addAuthInterceptor(
      onAuthFailed: () => Future<void>.delayed(Duration.zero, signOut),
    );

    // Try to resume an existing session on startup.
    try {
      final response = await client.mitxOnline
          .get<Map<String, dynamic>>('/api/v0/users/current_user/');
      final user = User.fromJson(response.data!);
      if (user.isAuthenticated) return user;
    } on Object {
      // No valid session — unauthenticated.
    }
    return null;
  }

  /// Called after the WebView OAuth flow completes and cookies are injected
  /// into the Dio CookieJar. Triggers LMS OAuth then verifies the session.
  Future<void> onLoginComplete() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = ref.read(dioClientProvider);

      // Trigger LMS OAuth handshake — follows redirect chain, sets JWT cookies.
      await client.lms.get<dynamic>(
        '/auth/login/ol-oauth2/',
        queryParameters: {'auth_entry': 'login'},
        options: Options(followRedirects: true, maxRedirects: 10),
      );

      // Verify and return the authenticated user.
      final response = await client.mitxOnline
          .get<Map<String, dynamic>>('/api/v0/users/current_user/');
      final user = User.fromJson(response.data!);
      if (!user.isAuthenticated) throw Exception('Authentication failed');
      return user;
    });
  }

  /// Sign out: clears all cookies, cached data, and secure storage.
  Future<void> signOut() async {
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
