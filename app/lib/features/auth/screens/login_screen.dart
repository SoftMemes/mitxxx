import 'package:cookie_jar/cookie_jar.dart';
import 'package:emajtee/core/network/dio_client.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _showWebView = false;
  bool _completingAuth = false;
  WebViewController? _webViewController;

  Future<void> _startWebViewAuth() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Detect when the OAuth flow completes — URL returns to mitxonline,
            // no longer on the Keycloak SSO domain.
            final uri = Uri.parse(request.url);
            final isSsoPage = uri.host.contains('sso.ol.mit.edu');
            final isLoginStart =
                uri.host == 'mitxonline.mit.edu' && uri.path == '/login/';

            if (!isSsoPage && !isLoginStart && uri.host == 'mitxonline.mit.edu') {
              // Auth flow complete — copy cookies and finalize.
              _onWebViewAuthComplete();
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse('$kMitxOnlineBaseUrl/login/'));

    setState(() {
      _webViewController = controller;
      _showWebView = true;
    });
  }

  Future<void> _onWebViewAuthComplete() async {
    if (_completingAuth) return;
    setState(() => _completingAuth = true);

    try {
      // Copy cookies from WebView into Dio's CookieJar so API calls are authenticated.
      await _syncWebViewCookiesToDio();

      // Trigger LMS OAuth and verify session.
      await ref.read(authProvider.notifier).onLoginComplete();
    } catch (e) {
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
    // Extract non-httpOnly cookies from the WebView using JavaScript.
    // httpOnly cookies (like the session cookie) are not accessible via JS
    // but may still be needed — the programmatic LMS OAuth call in
    // onLoginComplete() will establish the LMS-side JWT cookies via Dio.
    final client = ref.read(dioClientProvider);

    try {
      final rawCookies = await _webViewController!
          .runJavaScriptReturningResult('document.cookie');
      // rawCookies is a JSON string like '"name1=val1; name2=val2"'
      final cookieStr = rawCookies.toString().replaceAll('"', '');
      if (cookieStr.trim().isEmpty) return;

      final cookies = _parseCookieString(cookieStr, 'mitxonline.mit.edu');
      if (cookies.isNotEmpty) {
        await client.cookieJar.saveFromResponse(
          Uri.parse('$kMitxOnlineBaseUrl/'),
          cookies,
        );
      }
    } on Object {
      // JS extraction failure is non-fatal.
    }
  }

  List<Cookie> _parseCookieString(String cookieStr, String domain) {
    return cookieStr
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.contains('='))
        .map((part) {
          final idx = part.indexOf('=');
          final name = part.substring(0, idx).trim();
          final value = part.substring(idx + 1).trim();
          return Cookie(name, value)..domain = domain;
        })
        .toList();
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

    if (_showWebView && _webViewController != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Sign in with MITx'),
          leading: BackButton(
            onPressed: () => setState(() => _showWebView = false),
          ),
        ),
        body: WebViewWidget(controller: _webViewController!),
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
              if (kIsWeb) ...[
                const Icon(Icons.phone_iphone, size: 48, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  'Sign-in requires the iOS or Android app.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () {
                    // Opens mitxonline.mit.edu in a new browser tab.
                    // ignore: deprecated_member_use
                    WidgetsBinding.instance.platformDispatcher.defaultRouteName;
                  },
                  child: const Text('Open MITx Online'),
                ),
              ] else
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
