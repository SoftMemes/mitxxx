import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/progress/services/next_video_lecture_resolver.dart';
import 'package:omnilect/features/progress/services/progress_tracker.dart';

final progressTrackerProvider = Provider<ProgressTracker>((ref) {
  final db = ref.read(appDatabaseProvider);
  return ProgressTracker(
    db: db,
    resolver: NextVideoLectureResolver(db),
  );
});
