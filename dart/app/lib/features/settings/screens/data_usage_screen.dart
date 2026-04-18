import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/providers/enrollments_provider.dart';
import 'package:omnilect/features/downloads/providers/video_download_manager.dart';
import 'package:omnilect/features/sync/providers/sync_providers.dart';

final _log = Logger('data_usage');

class DataUsageScreen extends ConsumerStatefulWidget {
  const DataUsageScreen({super.key});

  @override
  ConsumerState<DataUsageScreen> createState() => _DataUsageScreenState();
}

class _DataUsageScreenState extends ConsumerState<DataUsageScreen> {
  int? _metadataBytes;
  int? _videoBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    final db = ref.read(appDatabaseProvider);
    final dbPath = await AppDatabase.dbFilePath();

    var metadataBytes = 0;
    try {
      final file = File(dbPath);
      if (file.existsSync()) metadataBytes = file.lengthSync();
    } on Object catch (e) {
      _log.warning('Could not read DB file size: $e');
    }

    final videoBytes = await db.getTotalDownloadedBytes();

    if (!mounted) return;
    setState(() {
      _metadataBytes = metadataBytes;
      _videoBytes = videoBytes;
    });
  }

  Future<void> _deleteVideos() async {
    final videoBytes = _videoBytes ?? 0;
    final confirmed = await _confirm(
      context,
      title: 'Delete downloaded videos?',
      body: 'This will remove ${_formatBytes(videoBytes)} of video files '
          'from your device. Course metadata and your enrollment list '
          'will not be affected.',
      destructiveLabel: 'Delete videos',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      // Cancel any active/queued background downloads first — otherwise a
      // task completing mid-delete will re-insert a DB row and drop a file
      // back into the downloads directory after we've wiped them.
      await ref.read(videoDownloadManagerProvider).cancelAllTasks();

      final db = ref.read(appDatabaseProvider);
      final paths = await db.clearDownloadedVideosAndGetPaths();
      for (final path in paths) {
        try {
          File(path).deleteSync();
        } on Object catch (e) {
          _log.warning('Could not delete video file $path: $e');
        }
      }
      await _loadSizes();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloaded videos deleted.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAll() async {
    final confirmed = await _confirm(
      context,
      title: 'Delete all app data?',
      body: 'This will remove all downloaded videos and cached course '
          'content. Everything will be re-downloaded the next time '
          'you sync.',
      destructiveLabel: 'Delete all',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      // Stop any in-progress sync FIRST and wait for in-flight workers to
      // drain. Otherwise a task holding an xblock response may call
      // db.putXblock after we've cleared the tables, leaving orphan rows
      // behind. Cancel background downloads for the same reason.
      final manager = ref.read(syncManagerOrNullProvider);
      if (manager != null) {
        await manager.stopAndWait();
      }
      await ref.read(videoDownloadManagerProvider).cancelAllTasks();

      final db = ref.read(appDatabaseProvider);
      final paths = await db.clearAllAndGetDownloadPaths();
      for (final path in paths) {
        try {
          File(path).deleteSync();
        } on Object catch (e) {
          _log.warning('Could not delete video file $path: $e');
        }
      }
      // Invalidate cached data providers so downstream screens re-read the
      // (now empty) DB rather than serving stale cached values. The sync
      // manager's in-memory scope state clears naturally on the next sync.
      ref.invalidate(enrollmentsProvider);
      if (!mounted) return;
      // Clearing selected_lists puts the user back in the "choose what to
      // sync" onboarding state. Navigate there directly instead of bouncing
      // through an empty home screen — the router's hasSelectedLists gate
      // would eventually redirect anyway, but the Drift stream emission
      // isn't synchronous so the user would flash empty state first.
      context.go('/onboarding/list-selection');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loading = _metadataBytes == null || _videoBytes == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Data Usage')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Course metadata'),
                  subtitle: const Text('Cached course outlines and content'),
                  trailing: Text(
                    _formatBytes(_metadataBytes!),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.video_library_outlined),
                  title: const Text('Downloaded videos'),
                  subtitle: const Text('Offline video files'),
                  trailing: Text(
                    _formatBytes(_videoBytes!),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: OutlinedButton.icon(
                    onPressed: _busy || _videoBytes == 0 ? null : _deleteVideos,
                    icon: Icon(Icons.video_library_outlined, color: cs.error),
                    label: Text(
                      'Delete downloaded videos',
                      style: TextStyle(color: cs.error),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: cs.error.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _deleteAll,
                    icon: Icon(Icons.delete_forever_outlined, color: cs.error),
                    label: Text(
                      'Delete all data',
                      style: TextStyle(color: cs.error),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: cs.error.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Delete all data removes videos and all cached course '
                    'content. Everything will be re-downloaded on the next sync.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes == 0) return '0 KB';
  if (bytes < 1024 * 1024) {
    final kb = (bytes / 1024).ceil();
    return '${kb < 1 ? 1 : kb} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
  final gb = bytes / (1024 * 1024 * 1024);
  return '${gb.toStringAsFixed(2)} GB';
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String destructiveLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(destructiveLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
