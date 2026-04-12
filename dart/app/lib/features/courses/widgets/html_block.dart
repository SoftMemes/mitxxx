import 'package:mitx_api/mitx_api.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HtmlBlock extends ConsumerStatefulWidget {
  const HtmlBlock({super.key, required this.html});

  final String html;

  @override
  ConsumerState<HtmlBlock> createState() => _HtmlBlockState();
}

class _HtmlBlockState extends ConsumerState<HtmlBlock> {
  double _height = 400;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _injectCookies() async {
    // Copy Dio's cookies for both domains into the native WebView cookie store
    // so authenticated content (images, CDN assets) loads correctly.
    try {
      final client = ref.read(dioClientProvider);
      final cookieManager = CookieManager.instance();

      for (final domain in ['mitxonline.mit.edu', 'courses.learn.mit.edu']) {
        final dioCookies = await client.cookieJar
            .loadForRequest(Uri.parse('https://$domain'));
        for (final c in dioCookies) {
          await cookieManager.setCookie(
            url: WebUri('https://$domain/'),
            name: c.name,
            value: c.value,
            domain: domain,
            isSecure: true,
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
    return SizedBox(
      height: _height,
      child: InAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
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
        onLoadStart: (controller, url) async {
          // Inject Dio cookies into the native store before the page loads.
          await _injectCookies();
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
