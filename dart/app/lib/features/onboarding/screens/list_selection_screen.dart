import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';
import 'package:omnilect/features/courses/providers/selected_lists_provider.dart';
import 'package:omnilect/features/courses/widgets/list_picker.dart';
import 'package:omnilect/features/sync/providers/sync_providers.dart';
import 'package:url_launcher/url_launcher.dart';

const String _kManageListsUrl = 'https://learn.mit.edu/dashboard/my-lists';

/// Onboarding step 3: pick which lists to sync. Shown exactly once after
/// disclosure + login, before the home screen. The router gates this via
/// [hasSelectedListsProvider].
class ListSelectionScreen extends ConsumerStatefulWidget {
  const ListSelectionScreen({super.key});

  @override
  ConsumerState<ListSelectionScreen> createState() =>
      _ListSelectionScreenState();
}

class _ListSelectionScreenState extends ConsumerState<ListSelectionScreen> {
  final Set<String> _draftSelection = <String>{};
  // Start in the refreshing state so the first build shows a spinner instead
  // of briefly flashing the "No lists found" empty state.
  bool _refreshing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _refreshing = true);
    try {
      await ref.read(availableListsControllerProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _continue() async {
    final available = ref.read(availableListsProvider).asData?.value ??
        const <AppListSummary>[];
    final hasAllEnrolled = _draftSelection.contains(kAllEnrolledListId);
    final hasMyLists = _draftSelection.any(
      (id) => id != kAllEnrolledListId,
    );
    await ref
        .read(selectedListsControllerProvider.notifier)
        .setSelection(_draftSelection);
    unawaited(
      ref.read(analyticsServiceProvider).logOnboardingListSelectionCompleted(
            listCount: _draftSelection.length,
            hasAllEnrolled: hasAllEnrolled,
            hasMyLists: hasMyLists,
            availableCount: available.length,
          ),
    );

    // Kick off the initial sync immediately so the user sees progress on
    // the home screen instead of an empty list that only starts populating
    // after a pull-to-refresh. Matches the settings Courses `_apply` flow.
    // Await the manager future so the request isn't dropped if the isolate
    // is still spawning — common on first login.
    (await ref.read(syncManagerProvider.future))?.requestFullSync();

    if (!mounted) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final availableAsync = ref.watch(availableListsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose what to sync'),
        automaticallyImplyLeading: false,
      ),
      body: availableAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => _ErrorState(
          message: err.toString(),
          onRetry: _refresh,
        ),
        data: (available) {
          if (available.isEmpty && _refreshing) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: available.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 80),
                            _EmptyState(),
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
                      onPressed:
                          _draftSelection.isEmpty ? null : _continue,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Continue'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'No lists found',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Enroll in a course or create a list at MIT Learn to start '
              'syncing.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(_kManageListsUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open MIT Learn'),
            ),
          ],
        ),
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
