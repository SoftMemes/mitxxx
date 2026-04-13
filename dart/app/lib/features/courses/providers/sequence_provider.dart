// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sequence_provider.g.dart';

/// Returns the cached sequence detail. Throws if no cache exists yet.
/// Network fetching is handled exclusively by `SyncController`.
@riverpod
Future<SequenceDetail> sequenceDetail(
  Ref ref, {
  required String blockId,
}) async {
  final db = ref.read(appDatabaseProvider);
  final cached = await db.getSequence(blockId);

  if (cached == null) {
    throw StateError('No sequence cached for $blockId. Run a sync first.');
  }

  return SequenceDetail.fromJson(
    jsonDecode(cached.data) as Map<String, dynamic>,
  );
}
