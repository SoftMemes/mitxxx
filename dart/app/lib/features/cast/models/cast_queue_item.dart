/// One video segment in the cast queue.
///
/// Built from a [VerticalSegment] but always carries the remote CDN URL
/// (never a local file path) so the cast receiver can stream from the CDN.
class CastQueueItem {
  const CastQueueItem({
    required this.verticalId,
    required this.title,
    required this.remoteUrl,
    required this.duration,
    required this.globalStartTime,
  });

  final String verticalId;
  final String title;

  /// Remote CDN mp4 URL — safe to hand to the cast receiver.
  final Uri remoteUrl;

  /// Duration of this segment in seconds.
  final double duration;

  /// Offset of this segment on the stitched lecture timeline (seconds).
  final double globalStartTime;
}
