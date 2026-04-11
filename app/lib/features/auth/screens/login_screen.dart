import 'dart:io' show Cookie;

import 'package:emajtee/core/network/dio_client.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:flutter/material.dart';
// Hide flutter_inappwebview's Cookie to avoid shadowing dart:io's Cookie,
// which cookie_jar's saveFromResponse expects.
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    setState(() => _completingAuth = true);

    try {
      // Copy all cookies (including httpOnly session cookie) from the native
      // WebView cookie store into Dio's PersistCookieJar.
      await _syncWebViewCookiesToDio();

      // Trigger LMS OAuth handshake and verify session.
      await ref.read(authProvider.notifier).onLoginComplete();

      // onLoginComplete() uses AsyncValue.guard internally — exceptions are
      // stored on the provider rather than re-thrown. Propagate failures so
      // the catch block below can reset the spinner and show the error.
      final authState = ref.read(authProvider);
      if (authState.hasError) throw Exception(authState.error);
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
    final client = ref.read(dioClientProvider);
    final cookieManager = CookieManager.instance();

    for (final baseUrl in [kMitxOnlineBaseUrl, kLmsBaseUrl]) {
      final webCookies = await cookieManager.getCookies(
        url: WebUri(baseUrl),
      );
      if (webCookies.isEmpty) continue;

      // Convert flutter_inappwebview cookies to dart:io Cookies for cookie_jar.
      final dartCookies = webCookies.map((c) {
        return Cookie(c.name.toString(), c.value.toString())
          ..domain = c.domain?.toString() ?? Uri.parse(baseUrl).host
          ..path = c.path?.toString() ?? '/';
      }).toList();

      await client.cookieJar.saveFromResponse(Uri.parse(baseUrl), dartCookies);
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
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;

            final isSsoPage = uri.host.contains('sso.ol.mit.edu');
            final isLoginStart =
                uri.host == 'mitxonline.mit.edu' && uri.path == '/login/';

            if (!isSsoPage && !isLoginStart && uri.host == 'mitxonline.mit.edu') {
              // Auth flow complete — allow navigation to finish so cookies are
              // committed to the native store, then sync them into Dio.
              Future.microtask(_onWebViewAuthComplete);
            }
            return NavigationActionPolicy.ALLOW;
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
