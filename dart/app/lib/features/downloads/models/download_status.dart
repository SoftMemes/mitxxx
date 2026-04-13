enum DownloadStatus {
  notDownloaded,
  queued,
  downloading,
  downloaded,
  failed,
  stale;

  static DownloadStatus fromName(String name) =>
      DownloadStatus.values.firstWhere(
        (e) => e.name == name,
        orElse: () => DownloadStatus.notDownloaded,
      );
}

/// Aggregate download state for a scope (course / sequence / vertical).
class ScopeDownloadState {
  const ScopeDownloadState({
    required this.total,
    required this.downloaded,
    required this.downloading,
    required this.failed,
    required this.stale,
  });

  final int total;
  final int downloaded;
  final int downloading;
  final int failed;
  final int stale;

  bool get isEmpty => total == 0;
  bool get isFullyDownloaded => total > 0 && downloaded == total;
  bool get isDownloading => downloading > 0;
  bool get hasStale => stale > 0;
  bool get hasFailed => failed > 0 && downloading == 0;

  double get progress => total > 0 ? downloaded / total : 0.0;

  /// Overall UI status for this scope.
  DownloadStatus get status {
    if (isDownloading) return DownloadStatus.downloading;
    if (isFullyDownloaded) return DownloadStatus.downloaded;
    if (hasStale) return DownloadStatus.stale;
    if (hasFailed) return DownloadStatus.failed;
    if (downloaded > 0) return DownloadStatus.downloading; // partially done but queued
    return DownloadStatus.notDownloaded;
  }

  @override
  String toString() =>
      'ScopeDownloadState(total: $total, downloaded: $downloaded, '
      'downloading: $downloading, failed: $failed, stale: $stale)';
}
