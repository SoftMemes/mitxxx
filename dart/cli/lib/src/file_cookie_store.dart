import 'dart:convert';
import 'dart:io';

import 'package:mitx_api/mitx_api.dart';
import 'package:path/path.dart' as p;

/// [CookieStore] implementation that persists cookies to a JSON file.
///
/// File format: `{"host": {"name": "value", ...}, ...}`
class FileCookieStore implements CookieStore {
  FileCookieStore(String dir) : _file = File(p.join(dir, 'cookies.json'));

  final File _file;

  @override
  Future<Map<String, Map<String, String>>> loadAll() async {
    if (!_file.existsSync()) return {};
    try {
      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, String>>{};
      for (final entry in decoded.entries) {
        final host = entry.key as String;
        final cookies = entry.value;
        if (cookies is Map) {
          result[host] = {
            for (final c in cookies.entries)
              c.key as String: c.value as String,
          };
        }
      }
      return result;
    } on Object {
      return {};
    }
  }

  @override
  Future<void> saveAll(Map<String, Map<String, String>> cookies) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(cookies),
    );
  }

  @override
  Future<void> deleteAll() async {
    if (_file.existsSync()) await _file.delete();
  }
}
