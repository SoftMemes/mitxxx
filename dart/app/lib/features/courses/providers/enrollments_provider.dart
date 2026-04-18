// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'enrollments_provider.g.dart';

final _log = Logger('enrollments');

/// Returns the cached enrollment list. Throws if no cache exists yet.
/// Network fetching is handled exclusively by `SyncController`.
@riverpod
Future<List<Enrollment>> enrollments(Ref ref) async {
  final db = ref.read(appDatabaseProvider);
  final cached = await db.getEnrollments();

  if (cached == null) {
    throw StateError('No enrollments cached. Run a sync first.');
  }

  final list = jsonDecode(cached.data) as List<dynamic>;
  return list
      .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Enrollments filtered to the user's current sync selection: only courses
/// that appear in at least one selected list's membership. This is what the
/// home screen shows — dropped courses (their local data has been wiped by
/// reconciliation) don't appear here either.
///
/// Before the first reconciliation sync completes after onboarding the
/// membership table is still empty, so this provider yields an empty list.
/// The home screen handles that by auto-triggering sync.
@riverpod
Stream<List<Enrollment>> activeEnrollments(Ref ref) async* {
  final db = ref.read(appDatabaseProvider);
  _log.info('activeEnrollments: subscribing to memberships watch');

  // Drive on membership changes so removing a list in settings updates the
  // home view as soon as reconciliation commits.
  await for (final memberships in db.select(db.courseListMemberships).watch()) {
    final allowedCourseIds = memberships.map((m) => m.courseId).toSet();
    final cached = await db.getEnrollments();
    if (cached == null) {
      _log.info(
        'activeEnrollments: memberships=${memberships.length} '
        'but no cached enrollments — yielding []',
      );
      yield const [];
      continue;
    }
    final list = jsonDecode(cached.data) as List<dynamic>;
    final all = list
        .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
        .toList();
    final filtered = all
        .where((e) => allowedCourseIds.contains(e.run.coursewareId))
        .toList();
    _log.info(
      'activeEnrollments: memberships=${memberships.length} '
      '(${allowedCourseIds.take(5).toList()}…) '
      'cached=${all.length} '
      '(${all.take(3).map((e) => e.run.coursewareId).toList()}…) '
      '→ yielding ${filtered.length}',
    );
    yield filtered;
  }
}
