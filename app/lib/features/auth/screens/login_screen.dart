import 'dart:io';

import 'package:emajtee/core/network/dio_client.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
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
    final cookieManager = WebViewCookieManager();
    final client = ref.read(dioClientProvider);

    for (final domain in ['mitxonline.mit.edu', 'courses.learn.mit.edu']) {
      final cookies =
          await cookieManager.getCookies('https://$domain');
      if (cookies.isEmpty) continue;

      final dartCookies = cookies
          .map(
            (wc) => Cookie(wc.name, wc.value)..domain = wc.domain,
          )
          .toList();

      await client.cookieJar.saveFromResponse(
        Uri.parse('https://$domain'),
        dartCookies,
      );
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
