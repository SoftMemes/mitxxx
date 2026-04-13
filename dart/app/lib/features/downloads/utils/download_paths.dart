import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Computes the SHA-1 hex digest of [url], used as a stable filesystem name.
String urlToSha1(String url) => sha1.convert(utf8.encode(url)).toString();

/// Returns the absolute path where the MP4 for [url] is stored:
/// `<applicationSupportDir>/downloads/<sha1>.mp4`.
Future<String> localPathForUrl(String url) async {
  final dir = await _downloadsDir();
  return p.join(dir, '${urlToSha1(url)}.mp4');
}

/// Ensures the downloads directory exists and returns its absolute path.
Future<String> _downloadsDir() async {
  final supportDir = await getApplicationSupportDirectory();
  final dir = Directory(p.join(supportDir.path, 'downloads'));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir.path;
}
