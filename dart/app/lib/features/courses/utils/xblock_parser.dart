import 'dart:convert';

import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html_unescape/html_unescape.dart';

final _unescape = HtmlUnescape();

/// Removes video xblock containers from the rendered vertical HTML so the
/// remaining HTML (text, images, problems, etc.) can be rendered in a single
/// WebView alongside our native Flutter video players rendered above it.
/// Matches Open edX wrappers with classes like `xblock-public_view-video` or
/// `xblock-student_view-video`, or elements carrying `data-block-type="video"`.
String stripVideoBlocks(String html) {
  if (html.trim().isEmpty) return html;

  final doc = html_parser.parse(html);

  final toRemove = <dom.Element>{};
  for (final el in doc.querySelectorAll('.xblock')) {
    final cls = el.className;
    if (cls.contains('xblock-public_view-video') ||
        cls.contains('xblock-student_view-video') ||
        el.attributes['data-block-type'] == 'video') {
      toRemove.add(el);
    }
  }
  for (final el in doc.querySelectorAll('[data-block-type="video"]')) {
    toRemove.add(el);
  }

  for (final el in toRemove) {
    // Walk up while the ancestor would become empty after removal — Open edX
    // wraps each xblock in a `.vert` div that keeps its divider border even
    // when the inner xblock is gone, causing stacked empty dividers.
    var target = el;
    while (true) {
      final parent = target.parent;
      if (parent is! dom.Element) break;
      // Would the parent have any remaining rendered content after we remove
      // `target`? (Ignore whitespace text nodes.)
      final hasOtherContent = parent.nodes.any((n) {
        if (identical(n, target)) return false;
        if (n is dom.Text) return n.text.trim().isNotEmpty;
        return true;
      });
      if (hasOtherContent) break;
      // Only bubble up through the wrapper divs, not e.g. <body>.
      if (parent.localName != 'div') break;
      target = parent;
    }
    target.remove();
  }

  return doc.documentElement?.outerHtml ?? html;
}

/// Extracts video metadata from raw xblock HTML.
/// Port of web/src/lib/proxy/xblock-parser.ts
List<ParsedVideoBlock> extractVideoMetadata(String html) {
  // Find all data-metadata="..." attribute values.
  final pattern = RegExp('data-metadata="([^"]*)"');
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
            RegExp('/xblock/([^/]+)/handler').firstMatch(publishUrl);
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
    } on Object catch (_) {
      // Skip malformed metadata blocks.
    }
  }

  return results;
}
