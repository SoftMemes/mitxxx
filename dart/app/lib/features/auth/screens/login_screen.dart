import 'package:mitx_api/mitx_api.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('auth.login');

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _showWebView = false;
  bool _completingAuth = false;

  void _startWebViewAuth() {
    setState(() => _showWebView = true);
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
    } catch (e, st) {
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

    for (final baseUrl in [kMitxOnlineBaseUrl, kLmsBaseUrl]) {
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
          c.name.toString(): c.value.toString(),
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
            onPressed: () => setState(() => _showWebView = false),
          ),
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('$kMitxOnlineBaseUrl/login/'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
          ),
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

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'MITxxx',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Unofficial MITx Offline App',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              FilledButton(
                onPressed: _startWebViewAuth,
                child: const Text('Sign in with MITx'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
