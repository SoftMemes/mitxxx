// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/outline.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'outline_provider.g.dart';

@riverpod
Future<CourseOutline> courseOutline(
  Ref ref, {
  required String courseId,
}) async {
  final client = ref.read(dioClientProvider);
  final db = ref.read(appDatabaseProvider);

  final cached = await db.getOutline(courseId);

  if (cached != null) {
    final outline = CourseOutline.fromJson(
      jsonDecode(cached.data) as Map<String, dynamic>,
    );
    _refreshInBackground(client, db, courseId);
    return outline;
  }

  return _fetchAndCache(client, db, courseId);
}

Future<CourseOutline> _fetchAndCache(
  dynamic client,
  dynamic db,
  String courseId,
) async {
  final response = await client.lms.get(
    '/api/learning_sequences/v1/course_outline/$courseId',
  );
  final data = response.data as Map<String, dynamic>;
  await db.putOutline(courseId, jsonEncode(data));
  return CourseOutline.fromJson(data);
}

Future<void> _refreshInBackground(
  dynamic client,
  dynamic db,
  String courseId,
) async {
  try {
    await _fetchAndCache(client, db, courseId);
  } catch (_) {
    // Silent background refresh failure.
  }
}
