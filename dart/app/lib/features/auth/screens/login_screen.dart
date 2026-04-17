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

      // If this login was prompted by a stale-session modal, clear the
      // pending request and let the reauth controller re-run the halted
      // sync operation.
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
    final cookieManager = CookieManager.instance();

    // Also grab sso.ol.mit.edu so the Keycloak identity cookies (KEYCLOAK_IDENTITY,
    // KEYCLOAK_SESSION) land in the Dio store — without them, server-side OAuth
    // redirect chains (establishLmsSession, establishLearnApiSession) bounce to
    // the SSO login page instead of completing silently.
    const ssoBaseUrl = 'https://sso.ol.mit.edu';
    for (final baseUrl in [kMitxOnlineBaseUrl, kLmsBaseUrl, ssoBaseUrl]) {
      final host = Uri.parse(baseUrl).host;
      final webCookies = await cookieManager.getCookies(
        url: WebUri(baseUrl),
      );
      _log.info('cookies from native store for $baseUrl: ${webCookies.length} total');
      for (final c in webCookies) {
        _log.fine('  cookie: name=${c.name} domain=${c.domain} httpOnly=${c.isHttpOnly} secure=${c.isSecure}');
      }

      if (webCookies.isEmpty) continue;

      // Save raw name→value pairs directly — no dart:io Cookie parsing.
      final raw = <String, String>{
        for (final c in webCookies)
          c.name: c.value as String,
      };
      await client.saveCookies(host, raw);
      _log.info('saved ${raw.length} cookies for $host');
    }
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
          // iOS auto-zooms on <input> focus when font-size < 16px (Keycloak's
          // default). Clamp maximum-scale at document start to prevent this.
          initialUserScripts: UnmodifiableListView([
            UserScript(
              source: """
                var _m = document.querySelector('meta[name=viewport]');
                if (!_m) { _m = document.createElement('meta'); _m.name = 'viewport'; document.head.appendChild(_m); }
                _m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
              """,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
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
