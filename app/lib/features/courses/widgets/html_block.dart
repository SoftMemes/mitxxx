import 'dart:io';

import 'package:emajtee/core/network/dio_client.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

class HtmlBlock extends ConsumerStatefulWidget {
  const HtmlBlock({super.key, required this.html});

  final String html;

  @override
  ConsumerState<HtmlBlock> createState() => _HtmlBlockState();
}

class _HtmlBlockState extends ConsumerState<HtmlBlock> {
  late final WebViewController _controller;
  double _height = 400;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Block in-content navigation — open in external browser instead.
            if (request.isMainFrame &&
                !request.url.startsWith('about:') &&
                !request.url.startsWith('data:')) {
              // Don't navigate inside the WebView.
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'FlutterHeight',
        onMessageReceived: (msg) {
          final h = double.tryParse(msg.message);
          if (h != null && h > 0 && mounted) {
            setState(() => _height = h + 32);
          }
        },
      );

    _loadContent();
  }

  Future<void> _loadContent() async {
    // Inject LMS cookies into the WebView's cookie manager so authenticated
    // content (images, CDN assets) loads correctly.
    await _syncCookies();

    final html = _injectMathJax(widget.html);
    await _controller.loadHtmlString(
      html,
      baseUrl: kLmsBaseUrl,
    );
  }

  Future<void> _syncCookies() async {
    try {
      final client = ref.read(dioClientProvider);
      final cookieManager = WebViewCookieManager();

      for (final domain in ['mitxonline.mit.edu', 'courses.learn.mit.edu']) {
        final cookies = await client.cookieJar
            .loadForRequest(Uri.parse('https://$domain'));
        for (final cookie in cookies) {
          await cookieManager.setCookie(
            WebViewCookie(
              name: cookie.name,
              value: cookie.value,
              domain: domain,
            ),
          );
        }
      }
    } catch (_) {
      // Non-fatal — content may still load without auth cookies.
    }
  }

  String _injectMathJax(String html) {
    const mathjax = '''
<script>
MathJax = {
  tex: { inlineMath: [['\\\\(', '\\\\)'], ['\$', '\$']], displayMath: [['\\\\[', '\\\\]'], ['\$\$', '\$\$']] },
  startup: { ready() { MathJax.startup.defaultReady(); FlutterHeight.postMessage(document.body.scrollHeight.toString()); } }
};
</script>
<script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js" async></script>
<script>
window.addEventListener('load', function() {
  setTimeout(function() { FlutterHeight.postMessage(document.body.scrollHeight.toString()); }, 500);
});
</script>
''';

    if (html.contains('</head>')) {
      return html.replaceFirst('</head>', '$mathjax</head>');
    }
    if (html.contains('<body')) {
      return html.replaceFirst('<body', '$mathjax<body');
    }
    return '$mathjax$html';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: WebViewWidget(controller: _controller),
    );
  }
}
