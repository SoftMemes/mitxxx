import 'dart:convert';

import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:html_unescape/html_unescape.dart';

final _unescape = HtmlUnescape();

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
