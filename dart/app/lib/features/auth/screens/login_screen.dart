import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';

final _log = Logger('auth.login');

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
  bool _loginSucceeded = false;

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
    if (!_loginSucceeded) {
      ref.read(reauthControllerProvider.notifier).onLoginAbandoned();
    }
    super.dispose();
  }

  Future<void> _onWebViewAuthComplete() async {
    if (_completingAuth) return;
    _log.info('WebView auth complete — syncing cookies and finalising');
    setState(() => _completingAuth = true);

    try {
      await _syncWebViewCookiesToDio();
      await ref.read(authProvider.notifier).onLoginComplete();

      // onLoginComplete() uses AsyncValue.guard internally — exceptions are
      // stored on the provider rather than re-thrown. Propagate failures so
      // the catch block below can reset the spinner and show the error.
      final authState = ref.read(authProvider);
      if (authState.hasError) throw Exception(authState.error);
      _loginSucceeded = true;

      if (!mounted) return;
      // Close the sheet BEFORE clearing the reauth state. Clearing reauth
      // bumps the router's refresh notifier which re-runs redirects; doing
      // it before the pop was safer with the old full-screen /login route.
      // For a bottom sheet the ordering matters less (there's no
      // isLoginRoute rule), but keeping the same order avoids surprises.
      Navigator.of(context).pop(true);

      // Clear the pending reauth request and let the reauth controller
      // re-run the halted sync operation. Retry is unawaited — whatever
      // screen sits behind the sheet picks up the sync via its normal
      // observers.
      ref.read(reauthControllerProvider.notifier).onLoginSucceeded();
    } on Object catch (e, st) {
      _log.severe('_onWebViewAuthComplete failed', e, st);
      if (mounted) {
        setState(() => _completingAuth = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign in failed: $e')),
        );
      }
    }
  }

  Future<void> _syncWebViewCookiesToDio() async {
    final client = ref.read(dioClientProvider);
    // All five hosts that can carry an auth-relevant cookie after a fresh
    // login. This is the ONLY place `syncWebViewCookiesToDio` runs post-
    // login — subsequent operations trust Dio's cookie jar. Adding
    // api.learn.mit.edu + learn.mit.edu here means the next userlist call
    // uses whatever the WebView captured for them (typically nothing fresh
    // unless the Keycloak redirect chain happened to visit them). For
    // silently-stale `session_mitlearn` the `client.learnApi` 401/403
    // interceptor reactively runs `bootstrapLearnApiSession`.
    await syncWebViewCookiesToDio(client, const [
      'mitxonline.mit.edu',
      'courses.learn.mit.edu',
      'sso.ol.mit.edu',
      'api.learn.mit.edu',
      'learn.mit.edu',
    ]);
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
          child: Stack(
            children: [
              InAppWebView(
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
                shouldOverrideUrlLoading:
                    (controller, navigationAction) async {
                  _log.fine(
                    'WebView navigating to: ${navigationAction.request.url}',
                  );
                  return NavigationActionPolicy.ALLOW;
                },
                onLoadStop: (controller, uri) async {
                  _log.fine('WebView onLoadStop: $uri');
                  if (uri == null) return;

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
                  if (uri.path.startsWith('/login/') ||
                      uri.path == '/login') {
                    return;
                  }

                  _log.info(
                    'WebView landed on authenticated page ${uri.path} — completing sign-in',
                  );
                  await _onWebViewAuthComplete();
                },
              ),
              if (_completingAuth)
                const ColoredBox(
                  color: Color(0x99000000),
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
            ],
          ),
        ),
      ],
    );
  }
}
