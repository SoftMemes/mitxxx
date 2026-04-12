// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/utils/xblock_parser.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'xblock_provider.g.dart';

@riverpod
Future<XBlockContent> xblockContent(
  Ref ref, {
  required String blockId,
}) async {
  final client = ref.read(dioClientProvider);
  final db = ref.read(appDatabaseProvider);

  final cached = await db.getXblock(blockId);

  if (cached != null) {
    final content = XBlockContent.fromJson(
      jsonDecode(cached.data) as Map<String, dynamic>,
    );
    _refreshInBackground(client, db, blockId);
    return content;
  }

  return _fetchAndCache(client, db, blockId);
}

Future<XBlockContent> _fetchAndCache(
  dynamic client,
  dynamic db,
  String blockId,
) async {
  final response = await client.lms.get<dynamic>('/xblock/$blockId');
  final html = response.data is String
      ? response.data as String
      : response.data.toString();

  final videos = extractVideoMetadata(html);

  final content = XBlockContent(
    videos: videos,
    htmlContent: html,
    hasContent: html.trim().isNotEmpty,
  );

  await db.putXblock(blockId, jsonEncode(content.toJson()));
  return content;
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
