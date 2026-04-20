import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/api_constants.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/router/app_router.dart';
import 'package:omnilect/core/screenshots/screenshot_mode.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';

final _log = Logger('auth.login');

String _jsString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('<', r'\u003C');
  return "'$escaped'";
}

/// Shows the MIT login WebView as a dismissible modal bottom sheet that
/// covers ~90% of the screen. Dismissing before completion (drag down or
/// scrim tap) surfaces the reauth prompt again if one was active — same
/// behavior as if the user had backed out of a full-screen login route.
///
/// Returns a Future that resolves when the sheet closes. Resolves to `true`
/// if login completed successfully, otherwise `null` (dismissed).
Future<bool?> showLoginSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    clipBehavior: Clip.antiAlias,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (ctx) => const _LoginSheetBody(),
  );
}

class _LoginSheetBody extends ConsumerStatefulWidget {
  const _LoginSheetBody();

  @override
  ConsumerState<_LoginSheetBody> createState() => _LoginSheetBodyState();
}

class _LoginSheetBodyState extends ConsumerState<_LoginSheetBody> {
  bool _completingAuth = false;
  // True once we've decided how the login resolves (success, failure, or
  // we've taken over the abandonment signal ourselves). Suppresses
  // dispose()'s default onLoginAbandoned call.
  bool _outcomeHandled = false;

  @override
  void initState() {
    super.initState();
    // Clear stale Keycloak cookies immediately so the WebView starts fresh.
    CookieManager.instance().deleteAllCookies();
  }

  @override
  void dispose() {
    // If the user dismissed the sheet (drag / scrim) without completing the
    // WebView OAuth, let the reauth controller know so it can re-surface
    // the prompt rather than silently stranding the user.
    if (!_outcomeHandled) {
      ref.read(reauthControllerProvider.notifier).onLoginAbandoned();
    }
    super.dispose();
  }

  Future<void> _onWebViewAuthComplete() async {
    if (_completingAuth) return;
    _completingAuth = true;
    // We're going to signal success or failure ourselves; dispose() must
    // not also fire onLoginAbandoned when the sheet pops below.
    _outcomeHandled = true;
    _log.info('WebView auth complete — closing sheet and finalising');

    // Capture everything that depends on this widget's BuildContext / ref
    // BEFORE popping the sheet — the State is unmounted as soon as the
    // bottom-sheet route closes, after which `ref` and `context` are gone.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);

    // Pop the sheet ("browser card") FIRST so the WebView is gone before
    // the Signing in… spinner shows up — the overlay-on-WebView combo was
    // visually distracting.
    Navigator.of(context).pop(true);

    final rootCtx = rootNavigatorKey.currentContext;
    if (rootCtx == null) {
      _log.warning('_onWebViewAuthComplete: no root navigator context');
      return;
    }

    // Spinner as a global modal barrier on the root navigator. Unawaited —
    // the showDialog Future only completes when we pop it ourselves.
    unawaited(
      showDialog<void>(
        context: rootCtx,
        barrierDismissible: false,
        barrierColor: const Color(0x99000000),
        builder: (_) => const PopScope(
          canPop: false,
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Signing in…',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final client = container.read(dioClientProvider);
      // All five hosts that can carry an auth-relevant cookie after a
      // fresh login. This is the ONLY place `syncWebViewCookiesToDio`
      // runs post-login — subsequent operations trust Dio's cookie jar.
      // Adding api.learn.mit.edu + learn.mit.edu here means the next
      // userlist call uses whatever the WebView captured for them
      // (typically nothing fresh unless the Keycloak redirect chain
      // happened to visit them). For silently-stale `session_mitlearn`
      // the `client.learnApi` 401/403 interceptor reactively runs
      // `bootstrapLearnApiSession`.
      await syncWebViewCookiesToDio(client, const [
        'mitxonline.mit.edu',
        'courses.learn.mit.edu',
        'sso.ol.mit.edu',
        'api.learn.mit.edu',
        'learn.mit.edu',
      ]);
      await container.read(authProvider.notifier).onLoginComplete();

      // onLoginComplete() uses AsyncValue.guard internally — exceptions
      // are stored on the provider rather than re-thrown. Propagate
      // failures so the catch block below can show the error.
      final authState = container.read(authProvider);
      if (authState.hasError) throw Exception(authState.error);

      _dismissSpinner();
      container.read(reauthControllerProvider.notifier).onLoginSucceeded();
    } on Object catch (e, st) {
      _log.severe('_onWebViewAuthComplete failed', e, st);
      _dismissSpinner();
      messenger.showSnackBar(SnackBar(content: Text('Sign in failed: $e')));
      // Sheet is already gone; treat as abandonment so reauth re-prompts.
      container.read(reauthControllerProvider.notifier).onLoginAbandoned();
    }
  }

  void _dismissSpinner() {
    final navState = rootNavigatorKey.currentState;
    if (navState != null && navState.canPop()) navState.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Sign in with MIT',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('$kMitxOnlineBaseUrl/login/'),
            ),
            initialSettings: InAppWebViewSettings(
              useShouldOverrideUrlLoading: true,
              // iOS: make WKWebView share the cookie store that
              // CookieManager writes to, so Keycloak session cookies
              // are visible cross-host.
              sharedCookiesEnabled: true,
            ),
            // iOS auto-zooms on <input> focus when the input's font-size
            // is below 16px (Keycloak's default). Force inputs to 16px
            // via an injected stylesheet — more accessibility-friendly
            // than disabling user-scalable on the viewport.
            initialUserScripts: UnmodifiableListView([
              UserScript(
                source: '''
                      var _s = document.createElement('style');
                      _s.textContent = 'input, textarea, select { font-size: 16px !important; }';
                      (document.head || document.documentElement).appendChild(_s);
                    ''',
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
              ),
            ]),
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              _log.fine(
                'WebView navigating to: ${navigationAction.request.url}',
              );
              return NavigationActionPolicy.ALLOW;
            },
            onConsoleMessage: ScreenshotMode.enabled
                ? (controller, msg) =>
                      _log.info('WebView console: ${msg.message}')
                : null,
            onLoadStop: (controller, uri) async {
              if (ScreenshotMode.enabled) {
                _log.info('WebView onLoadStop: $uri');
              } else {
                _log.fine('WebView onLoadStop: $uri');
              }
              if (uri == null) return;

              if (ScreenshotMode.enabled &&
                  uri.host == 'sso.ol.mit.edu' &&
                  ScreenshotMode.email.isNotEmpty) {
                _log.info(
                  'screenshot mode: injecting auto-fill on ${uri.host}',
                );
                // MIT Keycloak is a two-step login: username on the
                // first page, then a password page. This polls for
                // whichever form is on the current page and submits
                // it; onLoadStop fires again for the password step
                // and this handler re-runs.
                await controller.evaluateJavascript(
                  source:
                      '''
                      (function() {
                        var attempts = 0;
                        var EMAIL = ${_jsString(ScreenshotMode.email)};
                        var PASSWORD = ${_jsString(ScreenshotMode.password)};
                        function tryFill() {
                          var u = document.querySelector('#username, input[name="username"]');
                          var p = document.querySelector('#password, input[name="password"]');
                          var f = document.querySelector('form#kc-form-login, form');
                          console.log('[screenshots] attempt=' + attempts +
                            ' u=' + !!u + ' p=' + !!p + ' f=' + !!f);
                          if (f && p) {
                            if (p.value) return; // avoid double-submit
                            if (u) { u.value = EMAIL; u.dispatchEvent(new Event('input', {bubbles: true})); }
                            p.value = PASSWORD;
                            p.dispatchEvent(new Event('input', {bubbles: true}));
                            f.submit();
                            return;
                          }
                          if (f && u) {
                            if (u.value) return;
                            u.value = EMAIL;
                            u.dispatchEvent(new Event('input', {bubbles: true}));
                            f.submit();
                            return;
                          }
                          if (++attempts < 40) setTimeout(tryFill, 250);
                        }
                        tryFill();
                      })();
                    ''',
                );
                return;
              }

              // We only care about pages fully loaded on
              // mitxonline.mit.edu, OUTSIDE the /login/ flow. The OAuth
              // sequence is:
              //   /login/ → Keycloak SSO → /login/.apisix/redirect?code=…
              //   → (server exchanges code, sets authenticated session)
              //   → /dashboard/
              // We must wait for the final hop so we capture the
              // upgraded session cookie, not the anonymous pre-login
              // one.
              if (uri.host != 'mitxonline.mit.edu') return;
              if (uri.path.startsWith('/login/') || uri.path == '/login') {
                return;
              }

              _log.info(
                'WebView landed on authenticated page ${uri.path} — completing sign-in',
              );
              await _onWebViewAuthComplete();
            },
          ),
        ),
      ],
    );
  }
}
