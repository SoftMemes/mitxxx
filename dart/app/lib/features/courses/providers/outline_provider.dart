// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/outline.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'outline_provider.g.dart';

final _log = Logger('courses.outline');

@riverpod
Future<CourseOutline> courseOutline(
  Ref ref, {
  required String courseId,
}) async {
  _log.info('courseOutline($courseId): start');
  final client = ref.read(dioClientProvider);
  final db = ref.read(appDatabaseProvider);

  final cached = await db.getOutline(courseId);

  if (cached != null) {
    final outline = CourseOutline.fromJson(
      jsonDecode(cached.data) as Map<String, dynamic>,
    );
    // Empty outlines are almost always the result of an unauthenticated LMS
    // fetch. Discard them and force a fresh network call so the user gets
    // real content once auth is fixed.
    if (outline.outline.sections.isNotEmpty) {
      _log.info(
        'courseOutline($courseId): returning cached (sections=${outline.outline.sections.length})',
      );
      _refreshInBackground(client, db, courseId);
      return outline;
    }
    _log.info('courseOutline($courseId): cached outline is empty, refetching');
  }

  _log.info('courseOutline($courseId): no cache, fetching');
  return _fetchAndCache(client, db, courseId);
}

Future<CourseOutline> _fetchAndCache(
  dynamic client,
  dynamic db,
  String courseId,
) async {
  try {
    final response = await client.lms.get(
      '/api/learning_sequences/v1/course_outline/$courseId',
    );
    final data = response.data as Map<String, dynamic>;
    _log.fine('_fetchAndCache($courseId): status=${response.statusCode} keys=${data.keys.toList()}');
    final outline = CourseOutline.fromJson(data);
    _log.info('_fetchAndCache($courseId): sections=${outline.outline.sections.length}');
    // Skip caching empty outlines — they're usually a signal that the LMS
    // didn't see us as authenticated. Caching them would poison the next
    // app launch.
    if (outline.outline.sections.isNotEmpty) {
      await db.putOutline(courseId, jsonEncode(data));
    }
    return outline;
  } on Object catch (e, st) {
    _log.severe('_fetchAndCache($courseId) failed', e, st);
    rethrow;
  }
}

Future<void> _refreshInBackground(
  dynamic client,
  dynamic db,
  String courseId,
) async {
  try {
    await _fetchAndCache(client, db, courseId);
  } on Object catch (e, st) {
    _log.warning('_refreshInBackground($courseId) failed', e, st);
  }
}
