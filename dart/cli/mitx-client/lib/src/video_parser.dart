import 'dart:convert';

/// Extracts video metadata objects from xblock HTML.
///
/// Looks for elements with a `data-metadata` attribute containing a JSON
/// object with a `sources` key (list of video URLs).
///
/// Port of python-tools/mitx-client/client.py:extract_video_metadata().
List<Map<String, dynamic>> extractVideoMetadata(String html) {
  // Match data-metadata="..." attributes (handles both single and double quotes
  // and HTML-encoded content).
  final pattern = RegExp(r'data-metadata="([^"]*)"');
  final results = <Map<String, dynamic>>[];

  for (final match in pattern.allMatches(html)) {
    final raw = match.group(1)!
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'");
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded.containsKey('sources')) {
        results.add(decoded);
      }
    } on FormatException {
      continue;
    }
  }
  return results;
}
