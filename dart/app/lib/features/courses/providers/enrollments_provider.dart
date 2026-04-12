// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'enrollments_provider.g.dart';

@riverpod
Future<List<Enrollment>> enrollments(Ref ref) async {
  final client = ref.read(dioClientProvider);
  final db = ref.read(appDatabaseProvider);

  final cached = await db.getEnrollments();

  if (cached != null) {
    // Return cached data immediately.
    final list = jsonDecode(cached.data) as List<dynamic>;
    final enrollments = list
        .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
        .toList();

    // Refresh in background — failures are silent.
    _fetchAndCache(client, db);

    return enrollments;
  }

  // No cache — fetch from API.
  return _fetchAndCache(client, db);
}

Future<List<Enrollment>> _fetchAndCache(dynamic client, dynamic db) async {
  final response = await client.mitxOnline.get('/api/v1/enrollments/');
  final list = response.data as List<dynamic>;
  await db.putEnrollments(jsonEncode(list));
  return list
      .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
      .toList();
}
