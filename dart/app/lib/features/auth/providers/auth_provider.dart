// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/auth/models/user.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/learn_api_session_bootstrap.dart'
    as learn_bootstrap;
import 'package:omnilect/features/downloads/providers/video_download_manager.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
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
  /// Guard so the learnApi interceptor is attached at most once even if the
  /// provider rebuilds. Mirrors the `_authInterceptorAttached` pattern on
  /// `DioClient` for the LMS interceptor.
  bool _learnAuthInterceptorAttached = false;

  /// Guard so the learnApi headers interceptor is attached at most once.
  bool _learnHeadersInterceptorAttached = false;

  /// One-shot flag: have we attempted to warm up api.learn.mit.edu's own
  /// cookies this session? After a fresh mitxonline login the WebView
  /// never visits api.learn.mit.edu, so Dio has no `session_mitlearn` /
  /// `learn_csrftoken` — the first learnApi call would otherwise get 200
  /// with anonymous-empty results instead of any auth error our 401/403
  /// interceptor could catch. We run bootstrap ONCE (not per-operation) to
  /// populate them. Reset on sign-out so the next login re-warms.
  bool _learnWarmupAttempted = false;

  /// Single-flight gate for the learnApi bootstrap. Concurrent 401/403s on
  /// `client.learnApi` (e.g. `available_lists_provider.refresh` racing with
  /// `SyncController._reconcileMembership`'s userlist-items fetches) would
  /// otherwise each spawn their own `HeadlessInAppWebView` instance,
  /// competing on the shared cookie jar and producing inconsistent
  /// sessions. Instead, all concurrent callers await the same Future.
  Future<void>? _pendingLearnBootstrap;

  @override
  Future<User?> build() async {
    final client = ref.read(dioClientProvider)
      // Attach the 401 interceptor here (after auth_provider is created)
      // to avoid a circular dependency in the provider graph. On refresh
      // failure we surface the reauth prompt rather than signing the user
      // out — their cached content is still usable offline.
      ..addAuthInterceptor(
        onAuthFailed: () => Future<void>.delayed(Duration.zero, () {
          ref
              .read(reauthControllerProvider.notifier)
              .request(const SyncAllOperation());
        }),
      );
    // Order matters: attach the headers interceptor BEFORE the auth one so
    // its onRequest runs first. Dio runs request interceptors in attach
    // order, and we want Origin/Referer/X-CSRFToken set on the retried
    // request as well.
    _attachLearnApiHeadersInterceptor(client);
    _attachLearnApiAuthInterceptor(client);

    // Offline-first: if we have persisted cookies, treat the user as
    // authenticated without hitting the network. The LMS session will be
    // re-established when the user triggers a sync. If we have no cookies,
    // redirect to login.
    if (client.hasCookies) {
      _log.info('build: cookies found — resuming session offline-first');
      // Best-effort LMS session refresh in background so that the first
      // sync is more likely to succeed immediately.
      unawaited(_establishLmsSession(client));
      // learnApi cookies (`session_mitlearn` / `learn_csrftoken`) are set
      // on `api.learn.mit.edu` — a host the login WebView never visits,
      // so they're often absent on cold launch even when the rest of the
      // session is valid. Warm them up in the background now so the first
      // pull-to-refresh doesn't pay a 1–5s bootstrap stall.
      _maybeWarmupLearnApiInBackground(client);
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

  /// Fire-and-forget learnApi warm-up, sharing `_learnWarmupAttempted` and
  /// `_bootstrapLearnApiOnce` with the request-time interceptor path. Called
  /// from cold-start (`build()` with existing cookies) and post-login so the
  /// first pull-to-refresh doesn't stall on a just-in-time bootstrap.
  ///
  /// If the user later triggers a learnApi call before the bootstrap
  /// finishes, the interceptor's `_bootstrapLearnApiOnce` single-flight gate
  /// makes it `await` this same Future rather than spawning a second
  /// `HeadlessInAppWebView`.
  void _maybeWarmupLearnApiInBackground(DioClient client) {
    if (_learnWarmupAttempted) return;
    if (!client.hasCookies) return;
    final cookies = client.cookiesForHost('api.learn.mit.edu');
    final missing = cookies['session_mitlearn'] == null ||
        cookies['learn_csrftoken'] == null;
    if (!missing) {
      _learnWarmupAttempted = true;
      return;
    }
    _learnWarmupAttempted = true;
    unawaited(_bootstrapLearnApiOnce(client).catchError((Object e, StackTrace st) {
      _log.warning('background learnApi warm-up failed', e, st);
    }));
  }

  /// Installs a request-side interceptor on `client.learnApi` that always
  /// sets the three headers the api.learn.mit.edu backend uses to decide
  /// "is this request from an authenticated SPA at learn.mit.edu":
  ///
  /// - `Origin: https://learn.mit.edu` + `Referer: https://learn.mit.edu/` —
  ///   DRF's `SessionAuthentication` + Django CSRF middleware reject
  ///   session cookies on requests that don't declare a trusted origin;
  ///   instead of 401/403 they silently fall back to anonymous auth, which
  ///   returns `{"count":0,"results":[]}` for userlists even when the user
  ///   has lists. That's the "sometimes returns no results" behavior.
  /// - `X-CSRFToken: <learn_csrftoken>` — Django's double-submit CSRF
  ///   check. Sourced fresh from the cookie jar on every request so a
  ///   post-bootstrap cookie refresh is picked up immediately.
  ///
  /// Observed against the browser: a curl with these three headers plus
  /// `session_mitlearn` + `learn_csrftoken` cookies returns real data; the
  /// same curl minus any one of the three can silently return anonymous
  /// results. Matching the browser gets us out of the silent-anonymous
  /// fallback.
  void _attachLearnApiHeadersInterceptor(DioClient client) {
    if (_learnHeadersInterceptorAttached) return;
    _learnHeadersInterceptorAttached = true;
    client.learnApi.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // One-shot warm-up: if api.learn.mit.edu's own session cookies
          // aren't in Dio's jar yet, run the headless-WebView bootstrap
          // once so the SSO handshake on api.learn.mit.edu/login sets
          // them. Gated by `client.hasCookies` so we don't spin up a
          // bootstrap when the user isn't logged in (it would fail anyway
          // and the 401/403 path handles that cleanly).
          if (client.hasCookies && !_learnWarmupAttempted) {
            final cookies = client.cookiesForHost(options.uri.host);
            final missingLearn = cookies['session_mitlearn'] == null ||
                cookies['learn_csrftoken'] == null;
            if (missingLearn) {
              _learnWarmupAttempted = true;
              try {
                await _bootstrapLearnApiOnce(client);
              } on Object catch (e, st) {
                _log.warning(
                  '_attachLearnApiHeadersInterceptor: warm-up bootstrap failed',
                  e,
                  st,
                );
              }
            } else {
              _learnWarmupAttempted = true;
            }
          }

          // Re-serialize the `Cookie` header from the current jar. Dio's
          // built-in cookie interceptor (attached in `DioClient._buildDio`)
          // runs BEFORE this one and already set the header from the
          // pre-bootstrap jar; if we just ran the warm-up, those freshly
          // acquired cookies won't be on the request yet. Overwriting with
          // the current state guarantees `session_mitlearn` /
          // `learn_csrftoken` (and any other refreshed cookie) are sent on
          // this first request, not just subsequent ones.
          final refreshed = client.cookiesForHost(options.uri.host);
          if (refreshed.isNotEmpty) {
            options.headers['cookie'] = refreshed.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; ');
          }

          options.headers['Origin'] = 'https://learn.mit.edu';
          options.headers['Referer'] = 'https://learn.mit.edu/';
          final csrf = refreshed['learn_csrftoken'];
          if (csrf != null) {
            options.headers['X-CSRFToken'] = csrf;
          }
          handler.next(options);
        },
      ),
    );
  }

  /// Runs the headless-WebView learnApi bootstrap, single-flighting
  /// concurrent callers onto the same Future. A second 401/403 that arrives
  /// while a bootstrap is already in flight doesn't spawn a second
  /// `HeadlessInAppWebView` — it just awaits the in-progress one, retries,
  /// and benefits from the refreshed cookies.
  Future<void> _bootstrapLearnApiOnce(DioClient client) {
    final pending = _pendingLearnBootstrap;
    if (pending != null) return pending;
    final future = learn_bootstrap
        .bootstrapLearnApiSession(client)
        .whenComplete(() => _pendingLearnBootstrap = null);
    _pendingLearnBootstrap = future;
    return future;
  }

  /// Installs a 401/403 interceptor on the api.learn.mit.edu Dio so that a
  /// silently-stale `session_mitlearn` cookie is transparently refreshed via
  /// [learn_bootstrap.bootstrapLearnApiSession] before the original request
  /// is retried. This is the only recovery path we run for learnApi —
  /// there's no proactive "refresh before every operation" anywhere else.
  ///
  /// Failure modes:
  ///   - Bootstrap succeeds + retry succeeds → caller sees the response,
  ///     no reauth, no user-visible anything.
  ///   - Bootstrap fails OR retry still 401/403 → we surface the reauth
  ///     modal (via `SyncAllOperation`) and let the original error
  ///     propagate to the caller.
  void _attachLearnApiAuthInterceptor(DioClient client) {
    if (_learnAuthInterceptorAttached) return;
    _learnAuthInterceptorAttached = true;
    client.learnApi.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          final status = err.response?.statusCode;
          if (status != 401 && status != 403) {
            return handler.next(err);
          }
          // Don't attempt recovery if the original request was itself the
          // retry — avoids infinite loops when the bootstrap succeeded but
          // cookies still aren't accepted (e.g. full Keycloak expiry).
          if (err.requestOptions.extra['learnApiRetried'] == true) {
            return handler.next(err);
          }
          err.requestOptions.extra['learnApiRetried'] = true;
          try {
            await _bootstrapLearnApiOnce(client);
            final retry =
                await client.learnApi.fetch<dynamic>(err.requestOptions);
            return handler.resolve(retry);
          } on Object catch (e, st) {
            _log.warning(
              'learnApi auth-retry failed — surfacing reauth',
              e,
              st,
            );
            // Defer the reauth notification so we don't run it inside the
            // interceptor handler (matches the LMS interceptor pattern).
            Future<void>.delayed(Duration.zero, () {
              ref
                  .read(reauthControllerProvider.notifier)
                  .request(const SyncAllOperation());
            });
            return handler.next(err);
          }
        },
      ),
    );
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

      // Kick off the api.learn.mit.edu cookie warm-up in the background.
      // The login WebView only visits mitxonline, so `session_mitlearn` and
      // `learn_csrftoken` are missing from Dio's jar at this point — a
      // first pull-to-refresh would otherwise stall on the interceptor's
      // on-demand bootstrap. Unawaited here so login completion isn't
      // blocked; if the user triggers a refresh before warm-up finishes,
      // the interceptor's single-flight gate makes it join this Future.
      _maybeWarmupLearnApiInBackground(client);

      // Flush any LMS content cached while unauthenticated.
      final db = ref.read(appDatabaseProvider);
      await db.clearLmsCache();
      _log.info('onLoginComplete: cleared LMS cache');

      // Return placeholder user — home screen will trigger an initial sync.
      return _kCachedUser;
    });
    if (state.hasError) {
      _log.severe('onLoginComplete: guard caught error', state.error, state.stackTrace);
      unawaited(
        ref.read(analyticsServiceProvider).logLoginFailure(
          reason: 'unknown',
          stage: 'lms',
        ),
      );
    } else {
      unawaited(ref.read(analyticsServiceProvider).logLoginSuccess());
    }
  }

  /// Sign out: clears all cookies, cached data, and secure storage.
  Future<void> signOut() async {
    unawaited(ref.read(analyticsServiceProvider).logLogout());
    _log.info('signOut: clearing session');
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

    // Clear Dio cookie store (also wipes the SecureCookieStore entry).
    await client.clearCookies();
    // Reset the learnApi warm-up gate so the next sign-in re-runs the
    // bootstrap once `session_mitlearn` is missing again.
    _learnWarmupAttempted = false;

    // Clear the native WebView cookie store so re-opening login doesn't
    // auto-reauthenticate via a persisted Keycloak SSO cookie.
    await CookieManager.instance().deleteAllCookies();

    // Delete any downloaded video files from disk.
    await ref.read(videoDownloadManagerProvider).deleteAllFiles();

    // Clear all cached course data (and the now-empty download rows) from Drift.
    await db.clearAll();

    // Reset per-sequence in-memory sync state — otherwise its stale `synced`
    // entries cause the next sign-in's syncCourse run to skip every sequence
    // and finalise immediately with nothing actually fetched.
    ref.invalidate(sequenceSyncControllerProvider);

    state = const AsyncData(null);
  }
}
