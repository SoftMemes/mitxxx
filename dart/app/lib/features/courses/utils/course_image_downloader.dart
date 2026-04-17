import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'course_image_downloader.g.dart';

final _log = Logger('course-image');

/// Downloads a course artwork image, rescales it for fast on-device load, and
/// records the resulting local path in [AppDatabase.courseImages].
///
/// Both MITx (`feature_image_src` from the enrollments API) and OCW
/// (`<meta property="og:image">` on the course overview page) feed through
/// this same pipeline. Shared URLs dedup naturally — the remote URL is the
/// primary key.
class CourseImageDownloader {
  CourseImageDownloader(
    this._db, {
    Dio? dio,
    this.targetWidth = 240,
    this.jpegQuality = 80,
  }) : _dio = dio ?? Dio();

  final AppDatabase _db;
  final Dio _dio;

  /// Rescale target width in pixels. Tiles render at 72 logical px; 240 px
  /// leaves enough headroom for 3x devices and future UI sites (e.g. a larger
  /// course detail header) while keeping files under ~30 KB.
  final int targetWidth;

  /// JPEG encode quality (0..100). 80 is a good balance for course art.
  final int jpegQuality;

  /// Download + resize + persist. Returns the local path on success, or null
  /// on any failure (callers fall back to a placeholder — never throw into
  /// the sync flow).
  ///
  /// Idempotent: if a DB row exists AND the file still lives on disk, returns
  /// the existing path without re-downloading.
  Future<String?> ensureDownloaded(String url) async {
    if (url.isEmpty) return null;
    try {
      final existing = await _db.getCourseImage(url);
      if (existing != null && File(existing.localFilePath).existsSync()) {
        return existing.localFilePath;
      }

      final bytes = await _fetch(url);
      if (bytes == null) return null;

      final resized = _resizeJpeg(bytes);
      if (resized == null) {
        _log.warning('decode failed for $url (${bytes.length} bytes)');
        return null;
      }

      final dest = await _pathFor(url);
      await File(dest).writeAsBytes(resized, flush: true);
      await _db.upsertCourseImage(url: url, localFilePath: dest);
      return dest;
    } on Object catch (e, st) {
      _log.warning('ensureDownloaded failed for $url: $e', e, st);
      return null;
    }
  }

  Future<List<int>?> _fetch(String url) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    return resp.data;
  }

  Uint8List? _resizeJpeg(List<int> bytes) {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) return null;
    final width = decoded.width <= targetWidth ? decoded.width : targetWidth;
    final resized = img.copyResize(decoded, width: width);
    return img.encodeJpg(resized, quality: jpegQuality);
  }

  Future<String> _pathFor(String url) async {
    final dir = await _imagesDir();
    final name = sha1.convert(utf8.encode(url)).toString();
    return p.join(dir, '$name.jpg');
  }

  Future<String> _imagesDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'course_images'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
}

@Riverpod(keepAlive: true)
CourseImageDownloader courseImageDownloader(Ref ref) =>
    CourseImageDownloader(ref.read(appDatabaseProvider));
