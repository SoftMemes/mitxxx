import 'dart:async';

import 'package:omnilect/core/storage/database_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'course_image_provider.g.dart';

/// Streams the local file path for a downloaded course image, keyed by its
/// remote URL. Emits `null` until the downloader has persisted a row (first
/// sync) — the UI falls back to network or placeholder in that window.
@riverpod
Stream<String?> courseImageLocalPath(Ref ref, String url) {
  final db = ref.watch(appDatabaseProvider);
  return db.watchCourseImage(url).map((row) => row?.localFilePath);
}
