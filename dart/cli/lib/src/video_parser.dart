import 'dart:convert';

import 'package:html_unescape/html_unescape.dart';

final _unescape = HtmlUnescape();

/// Extracts video metadata objects from xblock HTML.
///
/// Finds all `data-metadata="..."` attribute values, HTML-unescapes them
/// (using the full html_unescape table, same as the Flutter app), JSON-decodes
/// them, and returns those containing a `sources` key.
List<Map<String, dynamic>> extractVideoMetadata(String html) {
  final pattern = RegExp(r'data-metadata="([^"]*)"');
  final results = <Map<String, dynamic>>[];

  for (final match in pattern.allMatches(html)) {
    final rawAttr = match.group(1);
    if (rawAttr == null) continue;
    try {
      final decoded = _unescape.convert(rawAttr);
      final meta = jsonDecode(decoded);
      if (meta is Map<String, dynamic> && meta.containsKey('sources')) {
        results.add(meta);
      }
    } on Object {
      continue;
    }
  }
  return results;
}
