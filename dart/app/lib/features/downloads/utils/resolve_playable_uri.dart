import 'dart:io';

import 'package:emajtee/core/storage/app_database.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';

/// Resolves the best playable URI for [video].
///
/// If the video's MP4 URL has been downloaded and the local file still exists,
/// returns a `file://` URI pointing to it. Otherwise returns the CDN URL as an
/// HTTPS URI. Returns null if the block has no usable URL at all.
Future<Uri?> resolvePlayableUri(
  ParsedVideoBlock video,
  AppDatabase db,
) async {
  final url = video.mp4Url ?? video.hlsUrl;
  if (url == null) return null;

  if (video.mp4Url != null) {
    final downloaded = await db.getDownloadedVideo(video.mp4Url!);
    if (downloaded != null &&
        downloaded.status == DownloadStatus.downloaded.name &&
        downloaded.localFilePath.isNotEmpty &&
        File(downloaded.localFilePath).existsSync()) {
      return Uri.file(downloaded.localFilePath);
    }
  }

  return Uri.parse(url);
}
