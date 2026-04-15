import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Formats a Flutter [Color] as a CSS `rgba(r,g,b,a)` string.
String _cssColor(Color c) {
  final r = (c.r * 255).round();
  final g = (c.g * 255).round();
  final b = (c.b * 255).round();
  return 'rgba($r,$g,$b,${c.a})';
}

/// Formats a Flutter [Color] with an alpha override (0.0–1.0).
String _cssColorA(Color c, double alpha) {
  final r = (c.r * 255).round();
  final g = (c.g * 255).round();
  final b = (c.b * 255).round();
  return 'rgba($r,$g,$b,$alpha)';
}

class _HtmlBlockState extends ConsumerState<HtmlBlock> {
  double _height = 0;
  InAppWebViewController? _webViewController;
  Brightness? _lastBrightness;

  // Loaded once from assets and shared across all HtmlBlock instances.
  static String? _mathJaxJs;

  @override
  void initState() {
    super.initState();
    _ensureMathJax();
  }

  Future<void> _ensureMathJax() async {
    if (_mathJaxJs != null) return;
    final js = await rootBundle.loadString('assets/js/mathjax.min.js');
    _mathJaxJs = js;
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness != null && _lastBrightness != brightness) {
      // Reload the WebView HTML with updated theme colors.
      _webViewController?.loadData(
        data: _wrapHtml(widget.html, Theme.of(context)),
      );
    }
    _lastBrightness = brightness;
  }

  String _wrapHtml(String html, ThemeData theme) {
    // MathJax 3 config: match the delimiters the LMS uses.
    const mathJaxConfig = r'''
<script>
  window.MathJax = {
    tex: {
      inlineMath: [["\\(","\\)"], ["[mathjaxinline]","[/mathjaxinline]"]],
      displayMath: [["\\[","\\]"], ["[mathjax]","[/mathjax]"]]
    },
    options: { enableMenu: false }
  };
</script>
''';

    final mathJaxScript = _mathJaxJs != null
        ? '<script>$_mathJaxJs</script>'
        : '';

    // Inject a viewport + base styles so text is readable and sized
    // appropriately, plus a scrollHeight callback for auto-sizing.
    // Typography is tuned to match the app (system font stack, Material 3 scale,
    // MIT brand red for links). Heading sizes are scaled down relative to browser
    // defaults so they complement rather than dominate body text. List indentation
    // is reduced from the browser default 40px to a tighter 1.3em.
    // Colors are derived from the Flutter ThemeData so they respond to dark mode.
    final cs = theme.colorScheme;
    final bodyColor = _cssColor(cs.onSurface);
    final linkColor = _cssColor(cs.primary);
    final codeBg = _cssColorA(cs.onSurface, 0.06);
    final tableBorder = _cssColorA(cs.onSurface, 0.15);
    final tableHeadBg = _cssColorA(cs.onSurface, 0.05);
    final bqBorder = _cssColorA(cs.onSurface, 0.18);
    final bqColor = _cssColor(cs.onSurfaceVariant);

    final headExtras = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
  html, body { margin: 0; padding: 0; background: transparent; color: $bodyColor; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    font-size: 15px;
    line-height: 1.6;
    padding: 12px;
  }

  /* Heading hierarchy — scaled down to sit naturally alongside 15px body text */
  h1, h2, h3, h4, h5, h6 {
    line-height: 1.3;
    margin: 0.85em 0 0.35em;
    font-weight: 600;
  }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.25em; }
  h3 { font-size: 1.1em; }
  h4, h5, h6 { font-size: 1em; font-weight: 500; }

  /* Lists — tighter indent than browser default (40px → 1.3em ≈ 20px) */
  ul, ol { padding-left: 1.3em; margin: 0.4em 0; }
  li { margin-bottom: 0.25em; }
  ul ul, ol ol, ul ol, ol ul { margin: 0.15em 0; }

  /* Links */
  a { color: $linkColor; }

  /* Images & media */
  img { max-width: 100%; height: auto; display: block; }

  /* Code */
  code {
    font-family: 'SFMono-Regular', Menlo, Consolas, 'Courier New', monospace;
    font-size: 0.875em;
    background: $codeBg;
    padding: 0.1em 0.3em;
    border-radius: 3px;
  }
  pre { white-space: pre-wrap; word-wrap: break-word; }
  pre code { background: none; padding: 0; border-radius: 0; }

  /* Tables */
  table { max-width: 100%; border-collapse: collapse; margin: 0.5em 0; }
  td, th { padding: 5px 8px; border: 1px solid $tableBorder; font-size: 0.933em; }
  th { font-weight: 600; background: $tableHeadBg; }

  /* Blockquotes */
  blockquote {
    margin: 0.6em 0;
    padding: 0.4em 0.75em;
    border-left: 3px solid $bqBorder;
    color: $bqColor;
  }
</style>
$mathJaxConfig$mathJaxScript<script>
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
    // Wait for MathJax to be loaded from the asset bundle before creating the
    // WebView. With _height=0 this is invisible anyway; we just defer WebView
    // creation until the inline script is ready so the initial load includes it.
    if (_mathJaxJs == null) return const SizedBox.shrink();

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
          _webViewController = controller;
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
          data: _wrapHtml(widget.html, Theme.of(context)),
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
