import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('courses.html_block');

/// Base URL used to resolve relative links (e.g. `/assets/...`) clicked in the
/// WebView. The WebView itself stays on `about:blank` to avoid the iOS
/// WKWebView HTTPS-baseURL sandbox quirk — only link resolution uses this.
const _lmsOrigin = 'https://courses.learn.mit.edu';

/// Resolves a raw href from the page (may be absolute, protocol-relative, or
/// root-relative) to a launchable absolute URL.
Uri? _resolveLinkUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  if (parsed.hasScheme) return parsed;
  if (trimmed.startsWith('//')) return Uri.tryParse('https:$trimmed');
  if (trimmed.startsWith('/')) return Uri.tryParse('$_lmsOrigin$trimmed');
  return Uri.tryParse('$_lmsOrigin/$trimmed');
}

/// Renders a cached xblock HTML string in a WebView.
///
/// This widget is intentionally offline-first: it does not inject auth
/// cookies and does not point its baseUrl at the LMS. The HTML string
/// itself is the entire payload — it's read from the Drift-cached xblock
/// in `xblockContentProvider`, populated at sync time. Any sub-resources
/// the HTML references (images, stylesheets from `/static/...` or
/// `courses.learn.mit.edu`) may fail to load; that's acceptable for now
/// and shows up as broken-image placeholders rather than a blank page.
///
/// Why no LMS baseUrl: WKWebView on iOS has a long-standing quirk where
/// `loadHTMLString(baseURL: https://...)` sandboxes the document in a way
/// that can silently blank the whole render. Using `about:blank` (the
/// default when baseUrl is null) avoids that and reliably shows text.
class HtmlBlock extends ConsumerStatefulWidget {
  const HtmlBlock({required this.html, super.key});

  final String html;

  @override
  ConsumerState<HtmlBlock> createState() => _HtmlBlockState();
}

class _HtmlBlockState extends ConsumerState<HtmlBlock> {
  double _height = 400;

  String _wrapHtml(String html) {
    // Inject a viewport + base styles so text is readable and sized
    // appropriately, plus a scrollHeight callback for auto-sizing.
    const headExtras = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
  html, body { margin: 0; padding: 0; background: transparent; color: inherit; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; font-size: 16px; line-height: 1.5; padding: 12px; }
  img { max-width: 100%; height: auto; }
  pre, code { white-space: pre-wrap; word-wrap: break-word; }
  table { max-width: 100%; }
</style>
<script>
window.addEventListener('load', function() {
  function report() {
    try {
      var h = document.body ? document.body.scrollHeight : 0;
      window.flutter_inappwebview.callHandler('FlutterHeight', h.toString());
    } catch (e) {}
  }
  report();
  setTimeout(report, 300);
  setTimeout(report, 1000);

  // Open all links in the system browser rather than navigating inline.
  document.addEventListener('click', function(e) {
    var a = e.target.closest('a[href]');
    if (!a) return;
    e.preventDefault();
    try {
      window.flutter_inappwebview.callHandler('FlutterOpenUrl', a.href);
    } catch (_) {}
  });
});
</script>
''';

    // Ensure there's a proper document structure. The cached HTML from
    // the LMS already has <html><head></head><body>...</body></html>,
    // so we inject into the existing <head>. If not, wrap it.
    if (html.contains('</head>')) {
      return html.replaceFirst('</head>', '$headExtras</head>');
    }
    return '<!DOCTYPE html><html><head>$headExtras</head><body>$html</body></html>';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: InAppWebView(
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
          transparentBackground: true,
          // Allow the document to be a generic about:blank origin so no
          // cross-origin sandboxing kicks in. Assets loaded from the LMS
          // (if online) will simply fail CORS/network — acceptable.
        ),
        onWebViewCreated: (controller) {
          controller
            ..addJavaScriptHandler(
              handlerName: 'FlutterHeight',
              callback: (args) {
                final h = double.tryParse(args.isNotEmpty ? args[0].toString() : '');
                if (h != null && h > 0 && mounted && (h - _height).abs() > 4) {
                  setState(() => _height = h + 24);
                }
              },
            )
            ..addJavaScriptHandler(
              handlerName: 'FlutterOpenUrl',
              callback: (args) async {
                final raw = args.isNotEmpty ? args[0].toString() : '';
                final uri = _resolveLinkUri(raw);
                if (uri == null) return;
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } else {
                  _log.warning('Cannot launch URL: $uri (from raw: $raw)');
                }
              },
            );
        },
        initialData: InAppWebViewInitialData(
          data: _wrapHtml(widget.html),
          // No baseUrl → defaults to about:blank, avoiding the iOS
          // WKWebView HTTPS-baseURL sandbox quirk.
        ),
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final uri = navigationAction.request.url;
          if (navigationAction.isForMainFrame &&
              uri != null &&
              uri.scheme != 'about' &&
              uri.scheme != 'data') {
            // Open in system browser; JS click handler is the primary path but
            // this catches any navigation the JS handler misses (redirects, etc).
            final resolved = _resolveLinkUri(uri.toString()) ?? uri;
            if (await canLaunchUrl(resolved)) {
              await launchUrl(resolved, mode: LaunchMode.externalApplication);
            }
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onConsoleMessage: (controller, message) {
          _log.fine('WebView console [${message.messageLevel}]: ${message.message}');
        },
        onReceivedError: (controller, request, error) {
          _log.warning('WebView error loading ${request.url}: ${error.description}');
        },
      ),
    );
  }
}
