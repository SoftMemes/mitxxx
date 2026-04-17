import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';

final _log = Logger('auth.learn_bootstrap');

/// Host list used by [ensureLearnApiSession] + [bootstrapLearnApiSession]
/// when pulling WebView cookies into Dio. Covers every origin that can carry
/// a relevant Keycloak identity or MIT Learn session cookie.
const List<String> _webviewHosts = [
  'sso.ol.mit.edu',
  'mitxonline.mit.edu',
  'courses.learn.mit.edu',
  'api.learn.mit.edu',
  'learn.mit.edu',
];

/// Best-effort: make sure Dio has a fresh, authenticated MIT Learn API
/// session. Lifts WebView cookies into Dio (covers freshly-set post-login
/// values for all relevant hosts), probes `/api/v0/users/me/`, and if that
/// says we're not authenticated, runs the headless-WebView bootstrap to
/// complete the SSO handshake on `api.learn.mit.edu`.
///
/// Swallows all errors — a failed attempt just means subsequent userlist
/// calls will 403, which the caller surfaces through the usual reauth path.
///
/// Prefer this over `DioClient.ensureLearnApiSession` anywhere you're about
/// to hit api.learn.mit.edu: the Dio-only handshake there can't complete the
/// Keycloak redirect chain when the HttpOnly identity cookies live solely in
/// the WebView cookie jar.
Future<void> ensureLearnApiSession(DioClient client) async {
  try {
    await syncWebViewCookiesToDio(client, _webviewHosts);
  } on Object catch (e, st) {
    _log.warning('ensureLearnApiSession: cookie sync failed', e, st);
  }

  var ok = false;
  try {
    final me =
        await client.learnApi.get<dynamic>('/api/v0/users/me/');
    final body = me.data as Map<String, dynamic>;
    ok = body['is_authenticated'] == true;
  } on Object catch (e, st) {
    _log.warning('ensureLearnApiSession: users/me probe failed', e, st);
  }
  if (ok) return;

  _log.info('ensureLearnApiSession: session stale — bootstrapping via WebView');
  try {
    await bootstrapLearnApiSession(client);
  } on Object catch (e, st) {
    _log.warning('ensureLearnApiSession: bootstrap failed', e, st);
  }
}

/// Bootstraps the MIT Learn API session (`session_mitlearn` + `learn_csrftoken`
/// cookies on `api.learn.mit.edu`) using a headless WebView.
///
/// Dio-only OAuth handshakes can't complete the SSO chain for existing
/// installs, because the full set of Keycloak identity cookies is only in the
/// system WebView's cookie jar (HttpOnly / session-scoped cookies we don't
/// have in Dio). This helper runs a short-lived `HeadlessInAppWebView`
/// pointing at `api.learn.mit.edu/login` — the WebView transparently uses
/// those cookies to complete SSO, lands back on api.learn.mit.edu with
/// `session_mitlearn` set, and we then pull those cookies into Dio.
///
/// Times out after [timeout] (default 15s) and cleans up regardless.
Future<void> bootstrapLearnApiSession(
  DioClient client, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final completer = Completer<void>();
  HeadlessInAppWebView? webView;

  Future<void> finishIfPossible(WebUri? uri) async {
    if (completer.isCompleted) return;
    // We consider the flow settled when the WebView lands on api.learn.mit.edu
    // at a path other than /login (i.e., after /login/.apisix/redirect has
    // set the session cookie and bounced us somewhere final).
    if (uri == null) return;
    final onApi = uri.host == 'api.learn.mit.edu' &&
        !uri.path.startsWith('/login');
    final onLearnSpa = uri.host == 'learn.mit.edu';
    if (!onApi && !onLearnSpa) return;
    _log.info('bootstrap: WebView settled on $uri — syncing cookies');
    completer.complete();
  }

  webView = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(
      url: WebUri('https://api.learn.mit.edu/login'),
    ),
    initialSettings: InAppWebViewSettings(
      sharedCookiesEnabled: true,
    ),
    onLoadStop: (controller, uri) async => finishIfPossible(uri),
    onReceivedError: (controller, request, error) {
      _log.warning('bootstrap: WebView error for ${request.url}: '
          '${error.description}');
      if (!completer.isCompleted) completer.complete();
    },
  );

  try {
    await webView.run();
  } on Object catch (e, st) {
    _log.warning('bootstrap: WebView run failed', e, st);
    if (!completer.isCompleted) completer.complete();
  }

  try {
    await completer.future.timeout(
      timeout,
      onTimeout: () {
        _log.warning('bootstrap: WebView timed out after $timeout');
      },
    );
  } finally {
    // Regardless of how we got here, pull api.learn.mit.edu cookies into the
    // Dio store before disposing the WebView.
    try {
      await syncWebViewCookiesToDio(client, const [
        'api.learn.mit.edu',
        'learn.mit.edu',
        'sso.ol.mit.edu',
      ]);
    } on Object catch (e, st) {
      _log.warning('bootstrap: cookie sync after WebView failed', e, st);
    }
    try {
      await webView.dispose();
    } on Object catch (e, st) {
      _log.warning('bootstrap: WebView dispose failed', e, st);
    }
  }
}
