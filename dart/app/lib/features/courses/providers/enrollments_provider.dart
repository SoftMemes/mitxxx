// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'enrollments_provider.g.dart';

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
