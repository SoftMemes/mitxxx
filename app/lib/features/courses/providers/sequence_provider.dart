// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sequence_provider.g.dart';

@riverpod
Future<SequenceDetail> sequenceDetail(
  Ref ref, {
  required String blockId,
}) async {
  final client = ref.read(dioClientProvider);
  final db = ref.read(appDatabaseProvider);

  final cached = await db.getSequence(blockId);

  if (cached != null) {
    final detail = SequenceDetail.fromJson(
      jsonDecode(cached.data) as Map<String, dynamic>,
    );
    _refreshInBackground(client, db, blockId);
    return detail;
  }

  return _fetchAndCache(client, db, blockId);
}

Future<SequenceDetail> _fetchAndCache(
  dynamic client,
  dynamic db,
  String blockId,
) async {
  final response = await client.lms.get('/api/courseware/sequence/$blockId');
  final data = response.data as Map<String, dynamic>;
  await db.putSequence(blockId, jsonEncode(data));
  return SequenceDetail.fromJson(data);
}

Future<void> _refreshInBackground(
  dynamic client,
  dynamic db,
  String blockId,
) async {
  try {
    await _fetchAndCache(client, db, blockId);
  } catch (_) {
    // Silent background refresh failure.
  }
}
