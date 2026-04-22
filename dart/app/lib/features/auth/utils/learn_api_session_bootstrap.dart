import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';

final _log = Logger('auth.learn_bootstrap');

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
/// Times out after [timeout] (default 5s) and cleans up regardless. A healthy
/// SSO handshake completes in well under a second; a longer wait means
/// Keycloak is itself dead (no `KEYCLOAK_IDENTITY` cookie) and is waiting for
/// credentials on its login page — which a headless WebView can't provide.
/// In that state the caller will see a stale-session error and surface the
/// reauth prompt instead; there's no point blocking on the bootstrap.
Future<void> bootstrapLearnApiSession(
  DioClient client, {
  Duration timeout = const Duration(seconds: 5),
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
    // Dio store before disposing the WebView. Whether the sync produced a
    // working session is decided by `SessionRefreshManager`, not here —
    // the consecutive-failure counter there escalates to the reauth dialog
    // when this bootstrap can't recover. Throwing on a heuristic here was
    // brittle: a freshly-logged-in WebView that finishes after our 5s timer
    // (or settles on a host we don't recognise) still produces valid
    // cookies, and the mitxonline reauth dialog should not pop in that
    // case.
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
