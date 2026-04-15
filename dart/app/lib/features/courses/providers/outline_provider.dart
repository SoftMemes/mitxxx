// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'outline_provider.g.dart';

/// Returns the cached course outline. Throws if no cache exists yet.
/// Network fetching is handled exclusively by `SyncController`.
@riverpod
Future<CourseOutline> courseOutline(
  Ref ref, {
  required String courseId,
}) async {
  final db = ref.read(appDatabaseProvider);
  final cached = await db.getOutline(courseId);

  if (cached == null) {
    throw StateError('No outline cached for $courseId. Run a sync first.');
  }

  return CourseOutline.fromJson(
    jsonDecode(cached.data) as Map<String, dynamic>,
  );
}
