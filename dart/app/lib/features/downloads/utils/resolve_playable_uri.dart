import 'dart:io';

import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/downloads/models/download_status.dart';
import 'package:omnilect/features/downloads/utils/download_paths.dart';

final _log = Logger('downloads.resolve');

/// Resolves the best playable URI for [video].
///
/// Returns a `file://` URI when the MP4 has been downloaded and we can find
/// the file on disk. Otherwise returns the CDN URL as an HTTPS URI (which
/// will fail offline — the caller decides how to handle that). Returns null
/// if the block has no usable URL at all.
///
/// Resolution order for a downloaded video:
/// 1. The canonical path derived from the URL
///    (`<applicationSupport>/downloads/<sha1(url)>.mp4` — deterministic).
/// 2. The `localFilePath` stored in the DB (what the download manager
///    recorded at completion time).
///
/// We prefer (1) because the stored absolute path can go stale — most
/// commonly on iOS, where the data-container UUID changes across a
/// reinstall and breaks any previously-saved absolute path, and defensively
/// anywhere the download-time and read-time resolutions of
/// `getApplicationSupportDirectory()` could differ.
Future<Uri?> resolvePlayableUri(
  ParsedVideoBlock video,
  AppDatabase db,
) async {
  final url = video.mp4Url ?? video.hlsUrl;
  if (url == null) return null;

  final mp4 = video.mp4Url;
  if (mp4 != null) {
    final downloaded = await db.getDownloadedVideo(mp4);
    if (downloaded != null &&
        downloaded.status == DownloadStatus.downloaded.name) {
      final canonical = await localPathForUrl(mp4);
      if (File(canonical).existsSync()) {
        return Uri.file(canonical);
      }
      if (downloaded.localFilePath.isNotEmpty &&
          File(downloaded.localFilePath).existsSync()) {
        return Uri.file(downloaded.localFilePath);
      }
      _log.warning(
        'status=downloaded but file missing at canonical=$canonical '
        'stored=${downloaded.localFilePath} — falling back to network '
        '(playback will fail offline)',
      );
    }
  }

  return Uri.parse(url);
}
