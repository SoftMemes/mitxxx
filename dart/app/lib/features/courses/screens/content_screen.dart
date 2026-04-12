import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/sequence_provider.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/courses/widgets/html_block.dart';
import 'package:emajtee/features/courses/widgets/video_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ContentScreen extends ConsumerWidget {
  const ContentScreen({
    super.key,
    required this.courseId,
    required this.sequenceId,
  });

  final String courseId;
  final String sequenceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sequenceAsync =
        ref.watch(sequenceDetailProvider(blockId: sequenceId));

    return Scaffold(
      appBar: AppBar(
        title: sequenceAsync.maybeWhen(
          data: (s) => s.items.isNotEmpty
              ? Text(s.items.first.pageTitle, overflow: TextOverflow.ellipsis)
              : const Text('Content'),
          orElse: () => const Text('Content'),
        ),
      ),
      body: sequenceAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('Could not load content'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(
                  sequenceDetailProvider(blockId: sequenceId),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (sequence) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(
            sequenceDetailProvider(blockId: sequenceId),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sequence.items.length,
            itemBuilder: (context, index) => _VerticalBlock(
              item: sequence.items[index],
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalBlock extends ConsumerWidget {
  const _VerticalBlock({required this.item});

  final SequenceItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final xblockAsync = ref.watch(xblockContentProvider(blockId: item.id));

    return xblockAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.pageTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Failed to load: $error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(xblockContentProvider(blockId: item.id)),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (content) => _BlockContent(content: content, item: item),
    );
  }
}

class _BlockContent extends StatelessWidget {
  const _BlockContent({required this.content, required this.item});

  final XBlockContent content;
  final SequenceItem item;

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    // Render video blocks.
    for (final video in content.videos) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: VideoBlock(video: video),
        ),
      );
    }

    // Render HTML content if present and no videos consumed it.
    // Problem xblocks ARE HTML — render them in a WebView too.
    if (content.videos.isEmpty && content.htmlContent.trim().isNotEmpty) {
      widgets.add(HtmlBlock(html: content.htmlContent));
    }

    if (widgets.isEmpty) {
      widgets.add(
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${item.pageTitle} — no displayable content',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }
}
