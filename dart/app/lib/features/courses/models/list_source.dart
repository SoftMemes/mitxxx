/// Discriminator for where a sync list came from.
///
/// - [enrolled]: the synthetic "All enrolled" list backed by the mitxonline
///   enrollments endpoint.
/// - [learnMyList]: a user-created list under `learn.mit.edu/dashboard/my-lists`.
enum ListSource {
  enrolled,
  learnMyList;

  /// Parse from the `source` column value stored in the Drift tables.
  static ListSource fromStorage(String value) {
    switch (value) {
      case 'enrolled':
        return ListSource.enrolled;
      case 'learn_my_list':
        return ListSource.learnMyList;
    }
    // Forward-compatible: unknown sources fall back to the custom-list bucket
    // since that's the growth area. We never persist unknown sources here.
    return ListSource.learnMyList;
  }

  String get storageValue {
    switch (this) {
      case ListSource.enrolled:
        return 'enrolled';
      case ListSource.learnMyList:
        return 'learn_my_list';
    }
  }
}

/// A list as shown in the picker UI. Combines the cached list-of-lists row
/// with the selection flag.
class AppListSummary {
  const AppListSummary({
    required this.id,
    required this.source,
    required this.name,
    required this.totalCourseCount,
  });

  final String id;
  final ListSource source;
  final String name;
  final int totalCourseCount;
}

/// A list the user has opted to sync.
class AppListSelection {
  const AppListSelection({
    required this.id,
    required this.source,
    required this.name,
    required this.selectedAt,
  });

  final String id;
  final ListSource source;
  final String name;
  final DateTime selectedAt;
}
