import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mitx_api/mitx_api.dart';

class HtmlBlock extends ConsumerStatefulWidget {
  const HtmlBlock({required this.html, super.key});

  final String html;

  @override
  ConsumerState<HtmlBlock> createState() => _HtmlBlockState();
}

class _HtmlBlockState extends ConsumerState<HtmlBlock> {
  double _height = 400;
  bool _cookiesReady = false;

  @override
  void initState() {
    super.initState();
    _injectCookies();
  }

  Future<void> _injectCookies() async {
    // Copy Dio's cookies for both domains into the native WebView cookie store
    // BEFORE the WebView is created — otherwise sub-resource requests fire
    // before cookies land and trigger OAuth redirects (ERR_BLOCKED_BY_ORB).
    try {
      final client = ref.read(dioClientProvider);
      final cookieManager = CookieManager.instance();

      for (final domain in ['mitxonline.mit.edu', 'courses.learn.mit.edu']) {
        final cookies = client.cookiesForHost(domain);
        for (final entry in cookies.entries) {
          await cookieManager.setCookie(
            url: WebUri('https://$domain/'),
            name: entry.key,
            value: entry.value,
            domain: domain,
            isSecure: true,
          );
        }
      }
    } on Object catch (_) {
      // Non-fatal — content may still load without auth cookies.
    }
    if (mounted) setState(() => _cookiesReady = true);
  }

  String _injectMathJax(String html) {
    const mathjax = r'''
<script>
MathJax = {
  tex: { inlineMath: [['\\(', '\\)'], ['$', '$']], displayMath: [['\\[', '\\]'], ['$$', '$$']] },
  startup: { ready() { MathJax.startup.defaultReady(); window.flutter_inappwebview.callHandler('FlutterHeight', document.body.scrollHeight.toString()); } }
};
</script>
<script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js" async></script>
<script>
window.addEventListener('load', function() {
  setTimeout(function() { window.flutter_inappwebview.callHandler('FlutterHeight', document.body.scrollHeight.toString()); }, 500);
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
    if (!_cookiesReady) {
      // Wait for cookies to land in the native store before mounting the
      // WebView so all sub-resource requests are authenticated from the start.
      return SizedBox(
        height: _height,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    return SizedBox(
      height: _height,
      child: InAppWebView(
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
        ),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'FlutterHeight',
            callback: (args) {
              final h = double.tryParse(args.isNotEmpty ? args[0].toString() : '');
              if (h != null && h > 0 && mounted) {
                setState(() => _height = h + 32);
              }
            },
          );
        },
        initialData: InAppWebViewInitialData(
          data: _injectMathJax(widget.html),
          baseUrl: WebUri(kLmsBaseUrl),
        ),
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final uri = navigationAction.request.url;
          // Block main-frame navigation — open external links in the system
          // browser instead of navigating within the WebView.
          if (navigationAction.isForMainFrame &&
              uri != null &&
              uri.scheme != 'about' &&
              uri.scheme != 'data') {
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}
