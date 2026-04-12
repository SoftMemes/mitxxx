import 'dart:convert';

import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html_unescape/html_unescape.dart';

final _unescape = HtmlUnescape();

/// A segment of a rendered vertical page in document order.
/// Either an HTML chunk (to render in a WebView) or a reference to a native
/// video block by its index into [XBlockContent.videos].
sealed class PageSegment {}

final class HtmlSegment extends PageSegment {
  HtmlSegment(this.html);
  final String html;
}

final class VideoSegment extends PageSegment {
  VideoSegment(this.videoIndex);
  final int videoIndex;
}

bool _isVideoXBlock(dom.Element el) {
  final cls = el.className;
  return cls.contains('xblock-public_view-video') ||
      cls.contains('xblock-student_view-video') ||
      el.attributes['data-block-type'] == 'video';
}

/// Splits the rendered xblock HTML into document-order segments so that video
/// blocks can be rendered as native Flutter widgets in the correct position
/// while the surrounding HTML (text, images, problems) is rendered in WebViews.
List<PageSegment> splitXBlockIntoSegments(String html) {
  if (html.trim().isEmpty) return [];

  final doc = html_parser.parse(html);

  // Strip all <script> tags from the head so Open edX video-player JS doesn't
  // run inside the segment WebViews (it would get stuck in a loading spinner).
  // CSS <link>/<style> are kept so content styling is preserved.
  // MathJax is re-injected by HtmlBlock._injectMathJax independently.
  final head = doc.head;
  if (head != null) {
    for (final el in head.querySelectorAll('script').toList()) {
      el.remove();
    }
  }
  final headHtml = head?.outerHtml ?? '<head></head>';

  // Replace each video xblock with a sentinel span, counting in DOM order.
  int videoIdx = 0;
  final seen = <dom.Element>{};

  for (final el in doc.querySelectorAll('.xblock')) {
    if (!seen.contains(el) && _isVideoXBlock(el)) {
      seen.add(el);
      final span = dom.Element.tag('span')
        ..attributes['data-fv'] = '${videoIdx++}';
      el.replaceWith(span);
    }
  }
  // Fallback for elements tagged directly without the xblock class.
  for (final el in doc.querySelectorAll('[data-block-type="video"]')) {
    if (!seen.contains(el)) {
      final span = dom.Element.tag('span')
        ..attributes['data-fv'] = '${videoIdx++}';
      el.replaceWith(span);
    }
  }

  final bodyHtml = doc.body?.innerHtml ?? '';

  // Split bodyHtml on sentinel spans and build the segment list.
  final sentinelRe = RegExp(r'<span data-fv="(\d+)"></span>');
  final segments = <PageSegment>[];
  int lastEnd = 0;

  for (final match in sentinelRe.allMatches(bodyHtml)) {
    if (match.start > lastEnd) {
      final chunk = bodyHtml.substring(lastEnd, match.start).trim();
      if (chunk.isNotEmpty) {
        segments.add(HtmlSegment('<html>$headHtml<body>$chunk</body></html>'));
      }
    }
    segments.add(VideoSegment(int.parse(match.group(1)!)));
    lastEnd = match.end;
  }
  if (lastEnd < bodyHtml.length) {
    final chunk = bodyHtml.substring(lastEnd).trim();
    if (chunk.isNotEmpty) {
      segments.add(HtmlSegment('<html>$headHtml<body>$chunk</body></html>'));
    }
  }

  // Fall back to rendering everything as HTML if no sentinels were inserted
  // (i.e. the vertical has no video xblocks — or none we could identify).
  if (segments.isEmpty || !segments.any((s) => s is VideoSegment)) {
    if (videoIdx == 0) {
      // No videos found in DOM; return a single HTML segment.
      return [HtmlSegment(html)];
    }
  }

  return segments;
}

/// Extracts video metadata from raw xblock HTML.
/// Port of web/src/lib/proxy/xblock-parser.ts
List<ParsedVideoBlock> extractVideoMetadata(String html) {
  // Find all data-metadata="..." attribute values.
  final pattern = RegExp(r'data-metadata="([^"]*)"');
  final results = <ParsedVideoBlock>[];

  for (final match in pattern.allMatches(html)) {
    final rawAttr = match.group(1);
    if (rawAttr == null) continue;

    try {
      // The attribute value is HTML-entity-encoded JSON.
      final decoded = _unescape.convert(rawAttr);
      final meta = jsonDecode(decoded) as Map<String, dynamic>;

      final sources = meta['sources'];
      if (sources is! List || sources.isEmpty) continue;

      // Split sources into mp4 and hls by URL extension.
      String? mp4Url;
      String? hlsUrl;
      for (final src in sources) {
        final url = src.toString();
        if (url.endsWith('.mp4') || url.contains('video_custom')) {
          mp4Url ??= url;
        } else if (url.endsWith('.m3u8') || url.contains('__index')) {
          hlsUrl ??= url;
        }
      }

      // Extract video block ID from publishCompletionUrl.
      String? videoBlockId;
      final publishUrl = meta['publishCompletionUrl']?.toString();
      if (publishUrl != null) {
        final blockMatch =
            RegExp(r'/xblock/([^/]+)/handler').firstMatch(publishUrl);
        videoBlockId = blockMatch?.group(1);
      }

      final transcriptLanguages = <String, String>{};
      final langs = meta['transcriptLanguages'];
      if (langs is Map) {
        for (final entry in langs.entries) {
          transcriptLanguages[entry.key.toString()] =
              entry.value.toString();
        }
      }

      results.add(
        ParsedVideoBlock(
          videoBlockId: videoBlockId,
          mp4Url: mp4Url,
          hlsUrl: hlsUrl,
          duration: (meta['duration'] as num?)?.toDouble() ?? 0,
          transcriptLanguages: transcriptLanguages,
          transcriptTranslationUrl:
              meta['transcriptTranslationUrl']?.toString(),
        ),
      );
    } catch (_) {
      // Skip malformed metadata blocks.
    }
  }

  return results;
}
