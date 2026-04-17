import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';

final _log = Logger('auth.login');

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _showWebView = true;
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
    // If the user backed out of the login screen without completing the
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
      // Navigate AWAY FROM /login BEFORE clearing the reauth state. Order
      // matters: `onLoginSucceeded()` sets the reauth state to null, which
      // synchronously bumps the router's refresh notifier and causes
      // GoRouter to re-evaluate its redirect. The
      // `isAuthenticated && isLoginRoute && !reauthActive → /home` rule
      // would then fire while we're still on `/login`, racing with the
      // explicit `context.pop()` below — and since GoRouter treats the
      // redirect as a push, the pop ends up stripping the redirected
      // `/home` off the stack instead of our `/login`, leaving the user
      // back on the WebView.
      //
      // Popping first means the current location is already on the
      // underlying screen by the time reauth clears, so the redirect is
      // a no-op.
      if (context.canPop()) {
        context.pop();
      } else {
        // `/login` was reached via `context.go('/login')` (e.g. from the
        // "Log in to sync" button on home) — nothing beneath it. Replace.
        context.go('/home');
      }

      // Clear the pending reauth request and let the reauth controller
      // re-run the halted sync operation. Retry is unawaited so the
      // caller (this screen) can finish teardown immediately — the sync
      // progress appears on whatever screen we just returned to via its
      // usual observers.
      ref.read(reauthControllerProvider.notifier).onLoginSucceeded();
    } on Object catch (e, st) {
      _log.severe('_onWebViewAuthComplete failed', e, st);
      if (mounted) {
        setState(() {
          _showWebView = false;
          _completingAuth = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign in failed: $e')),
        );
      }
    }
  }

  Future<void> _syncWebViewCookiesToDio() async {
    final client = ref.read(dioClientProvider);
    // Include sso.ol.mit.edu so Keycloak identity cookies land in the Dio
    // store — without them, server-side OAuth redirect chains bounce to the
    // SSO login page instead of completing silently.
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
    if (_completingAuth) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Signing in…'),
            ],
          ),
        ),
      );
    }

    if (_showWebView) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Sign in with MITx'),
          leading: BackButton(
            onPressed: () => context.go('/home'),
          ),
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('$kMitxOnlineBaseUrl/login/'),
          ),
          initialSettings: InAppWebViewSettings(
            useShouldOverrideUrlLoading: true,
            // iOS: make WKWebView share the cookie store that CookieManager
            // writes to, so Keycloak session cookies are visible cross-host.
            sharedCookiesEnabled: true,
          ),
          // iOS auto-zooms on <input> focus when the input's font-size is
          // below 16px (Keycloak's default). Force inputs to 16px via an
          // injected stylesheet — more accessibility-friendly than disabling
          // user-scalable on the viewport.
          initialUserScripts: UnmodifiableListView([
            UserScript(
              source: """
                var _s = document.createElement('style');
                _s.textContent = 'input, textarea, select { font-size: 16px !important; }';
                (document.head || document.documentElement).appendChild(_s);
              """,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
            ),
          ]),
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            _log.fine('WebView navigating to: ${navigationAction.request.url}');
            return NavigationActionPolicy.ALLOW;
          },
          onLoadStop: (controller, uri) async {
            _log.fine('WebView onLoadStop: $uri');
            if (uri == null) return;

            // We only care about pages fully loaded on mitxonline.mit.edu,
            // OUTSIDE the /login/ flow. The sequence during OAuth is:
            //   /login/ → Keycloak SSO → /login/.apisix/redirect?code=... →
            //   (server exchanges code, sets authenticated session) → /dashboard/
            // We must wait for the final hop so we capture the upgraded
            // session cookie, not the anonymous pre-login one.
            if (uri.host != 'mitxonline.mit.edu') return;
            if (uri.path.startsWith('/login/') || uri.path == '/login') return;

            _log.info('WebView landed on authenticated page ${uri.path} — completing sign-in');
            await _onWebViewAuthComplete();
          },
        ),
      );
    }

    // _showWebView is always true on this screen; this branch is unreachable
    // but kept to satisfy the Dart return-type requirement.
    return const SizedBox.shrink();
  }
}
