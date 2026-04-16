enum DownloadStatus {
  notDownloaded,
  /// Written to the DB queue but not yet handed to background_downloader.
  pending,
  /// Handed to background_downloader and waiting in its holding queue.
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
    required this.pending,
    required this.failed,
    required this.stale,
  });

  final int total;
  final int downloaded;
  final int downloading;
  final int pending;
  final int failed;
  final int stale;

  bool get isEmpty => total == 0;
  bool get isFullyDownloaded => total > 0 && downloaded == total;
  bool get isDownloading => downloading > 0;
  bool get isPending => pending > 0 && downloading == 0;
  bool get hasStale => stale > 0;
  bool get hasFailed => failed > 0 && downloading == 0 && pending == 0;

  double get progress => total > 0 ? downloaded / total : 0.0;

  /// Videos that have been explicitly requested (pending, queued, in-progress,
  /// completed, or failed). Excludes untouched videos in the scope.
  int get requested => downloaded + downloading + pending + failed + stale;

  /// Progress over only the requested videos (ignores unqueued ones in scope).
  double get requestedProgress => requested > 0 ? downloaded / requested : 0.0;

  /// Overall UI status for this scope.
  ///
  /// Partial states (some videos downloaded, nothing in flight, no errors)
  /// collapse to [DownloadStatus.notDownloaded] so the UI offers the user a
  /// way to fetch the remaining videos rather than a dead-end spinner.
  DownloadStatus get status {
    if (isDownloading) return DownloadStatus.downloading;
    if (isPending) return DownloadStatus.pending;
    if (isFullyDownloaded) return DownloadStatus.downloaded;
    if (hasStale) return DownloadStatus.stale;
    if (hasFailed) return DownloadStatus.failed;
    return DownloadStatus.notDownloaded;
  }

  @override
  String toString() =>
      'ScopeDownloadState(total: $total, downloaded: $downloaded, '
      'downloading: $downloading, pending: $pending, failed: $failed, '
      'stale: $stale)';
}
