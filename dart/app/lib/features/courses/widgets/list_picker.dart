import 'package:flutter/material.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';

/// Stateless, multi-select picker for sync lists. Parent holds the selection
/// state (a `Set<String>` of list ids) and is notified via [onToggle]. Shared
/// between onboarding and settings.
///
/// "All enrolled" is pinned first with a small system-list affordance; other
/// lists follow in the order provided.
class ListPicker extends StatelessWidget {
  const ListPicker({
    required this.available,
    required this.selectedIds,
    required this.onToggle,
    super.key,
  });

  final List<AppListSummary> available;
  final Set<String> selectedIds;
  final void Function(String listId, {required bool selected}) onToggle;

  @override
  Widget build(BuildContext context) {
    final sorted = [...available]..sort(_sortKey);
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final list = sorted[i];
        final selected = selectedIds.contains(list.id);
        return CheckboxListTile(
          value: selected,
          onChanged: (value) => onToggle(list.id, selected: value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          secondary: _leadingIcon(list),
          title: Text(list.name),
          subtitle: Text(
            list.totalCourseCount == 1
                ? '1 course'
                : '${list.totalCourseCount} courses',
          ),
        );
      },
    );
  }

  /// "All enrolled" first, then lists sorted by name.
  static int _sortKey(AppListSummary a, AppListSummary b) {
    if (a.id == kAllEnrolledListId) return -1;
    if (b.id == kAllEnrolledListId) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  Widget _leadingIcon(AppListSummary list) {
    if (list.source == ListSource.enrolled) {
      return const Icon(Icons.school_outlined);
    }
    return const Icon(Icons.bookmark_outline);
  }
}
