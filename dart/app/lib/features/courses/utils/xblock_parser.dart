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

/// Sanitizes xblock HTML for display in the lecture content list.
///
/// Strips:
/// - Video xblock containers (same as [stripVideoBlocks])
/// - Problem / assessment xblock containers (Open edX `xblock-*-problem`,
///   `xblock-*-library_content`, `capa_module`, etc.)
/// - Unsafe tags: `<script>`, `<style>`, `<iframe>`, `<form>`, `<input>`,
///   `<button>`, `<select>`, `<textarea>`
///
/// Returns sanitized outer HTML. Safe to pass directly to `HtmlBlock`.
String sanitizeXBlockHtml(String html) {
  if (html.trim().isEmpty) return html;

  // First strip video xblocks using the existing logic.
  final stripped = stripVideoBlocks(html);

  final doc = html_parser.parse(stripped);

  // Strip problem/assessment xblocks.
  final problemToRemove = <dom.Element>{};
  for (final el in doc.querySelectorAll('.xblock')) {
    final cls = el.className;
    if (cls.contains('-problem') ||
        cls.contains('-library_content') ||
        el.attributes['data-block-type'] == 'problem' ||
        el.attributes['data-block-type'] == 'library_content') {
      problemToRemove.add(el);
    }
  }
  for (final el in doc.querySelectorAll(
    '[data-block-type="problem"], [data-block-type="library_content"]',
  )) {
    problemToRemove.add(el);
  }
  // Also strip any element with a class suggesting it is a CAPA problem.
  for (final el in doc.querySelectorAll('.capa_inputtype, .problem-feedback')) {
    problemToRemove.add(el);
  }
  for (final el in problemToRemove) {
    var target = el;
    while (true) {
      final parent = target.parent;
      if (parent is! dom.Element) break;
      final hasOther = parent.nodes.any((n) {
        if (identical(n, target)) return false;
        if (n is dom.Text) return n.text.trim().isNotEmpty;
        return true;
      });
      if (hasOther) break;
      if (parent.localName != 'div') break;
      target = parent;
    }
    target.remove();
  }

  // Strip unsafe tags entirely (including their children for script/style;
  // for form elements strip the element but keep inner text where present).
  const removeWithChildren = {'script', 'style', 'iframe'};
  const removeTagOnly = {'form', 'input', 'button', 'select', 'textarea'};

  for (final tag in removeWithChildren) {
    for (final el in List.of(doc.querySelectorAll(tag))) {
      el.remove();
    }
  }
  for (final tag in removeTagOnly) {
    for (final el in List.of(doc.querySelectorAll(tag))) {
      // Unwrap: replace the element with its text content.
      el.replaceWith(dom.Text(el.text));
    }
  }

  return doc.documentElement?.outerHtml ?? stripped;
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
