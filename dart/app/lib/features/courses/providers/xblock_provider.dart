// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'xblock_provider.g.dart';

/// Returns the cached xblock content. Throws if no cache exists yet.
/// Network fetching is handled exclusively by `SyncController`.
@riverpod
Future<XBlockContent> xblockContent(
  Ref ref, {
  required String blockId,
}) async {
  final db = ref.read(appDatabaseProvider);
  final cached = await db.getXblock(blockId);

  if (cached == null) {
    throw StateError('No xblock cached for $blockId. Run a sync first.');
  }

  return XBlockContent.fromJson(
    jsonDecode(cached.data) as Map<String, dynamic>,
  );
}
