import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';
import 'package:omnilect/features/courses/providers/selected_lists_provider.dart';
import 'package:omnilect/features/courses/widgets/list_picker.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
import 'package:url_launcher/url_launcher.dart';

const String _kManageListsUrl = 'https://learn.mit.edu/dashboard/my-lists';

/// Settings → Courses. Lets the user change which lists to sync after
/// onboarding. Saving triggers a reconciliation sync immediately.
class CoursesScreen extends ConsumerStatefulWidget {
  const CoursesScreen({super.key});

  @override
  ConsumerState<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends ConsumerState<CoursesScreen> {
  late final Set<String> _draftSelection;
  late final Set<String> _initialSelection;
  bool _initialized = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _draftSelection = <String>{};
    _initialSelection = <String>{};
  }

  void _primeFromSelection(List<AppListSelection> selection) {
    if (_initialized) return;
    _draftSelection
      ..clear()
      ..addAll(selection.map((s) => s.id));
    _initialSelection.addAll(_draftSelection);
    _initialized = true;
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await ref.read(availableListsControllerProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _apply() async {
    final added = _draftSelection.difference(_initialSelection);
    final removed = _initialSelection.difference(_draftSelection);
    final hasAllEnrolled = _draftSelection.contains(kAllEnrolledListId);
    final hasMyLists = _draftSelection.any(
      (id) => id != kAllEnrolledListId,
    );

    await ref
        .read(selectedListsControllerProvider.notifier)
        .setSelection(_draftSelection);

    unawaited(
      ref.read(analyticsServiceProvider).logSettingsListSelectionChanged(
            listCount: _draftSelection.length,
            listsAdded: added.length,
            listsRemoved: removed.length,
            hasAllEnrolled: hasAllEnrolled,
            hasMyLists: hasMyLists,
          ),
    );

    // Restart sync from the top so the new selection takes effect
    // immediately — existing in-flight work is cancelled first.
    final syncController = ref.read(syncControllerProvider.notifier);
    unawaited(() async {
      try {
        await syncController.stopAll();
        await syncController.syncAll();
      } on Object catch (e, st) {
        debugPrint('courses apply: sync kickoff failed: $e\n$st');
      }
    }());

    if (!mounted) return;
    // Apply closes straight back to the home screen so the user sees the
    // sync progress on the course list rather than returning to /settings.
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final selectionAsync = ref.watch(selectedListsProvider);
    final availableAsync = ref.watch(availableListsProvider);

    selectionAsync.whenData(_primeFromSelection);

    final hasChanges =
        !_setEquals(_draftSelection, _initialSelection);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Courses'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Manage your enrolled courses and lists at MIT Learn.',
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(_kManageListsUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open MIT Learn'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: availableAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, st) => _ErrorState(
                message: err.toString(),
                onRetry: _refresh,
              ),
              data: (available) {
                if (_refreshing && available.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: available.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 80),
                            _EmptyListMessage(),
                          ],
                        )
                      : ListPicker(
                          available: available,
                          selectedIds: _draftSelection,
                          onToggle: (id, {required selected}) {
                            setState(() {
                              if (selected) {
                                _draftSelection.add(id);
                              } else {
                                _draftSelection.remove(id);
                              }
                            });
                          },
                        ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 4,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _draftSelection.isEmpty ? null : _apply,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      hasChanges ? 'Apply' : 'Done',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  for (final v in a) {
    if (!b.contains(v)) return false;
  }
  return true;
}

class _EmptyListMessage extends StatelessWidget {
  const _EmptyListMessage();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Icon(Icons.inbox_outlined, size: 48),
          const SizedBox(height: 16),
          Text(
            'No lists found',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Pull down to refresh. Create lists at MIT Learn to see them '
            'here.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(
              "Couldn't load lists",
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
