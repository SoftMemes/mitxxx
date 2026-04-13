import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/sequence_provider.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/courses/utils/xblock_parser.dart'
    show stripVideoBlocks;
import 'package:emajtee/features/courses/widgets/html_block.dart';
import 'package:emajtee/features/courses/widgets/video_block.dart';
import 'package:emajtee/features/downloads/widgets/download_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ContentScreen extends ConsumerStatefulWidget {
  const ContentScreen({
    required this.courseId,
    required this.sequenceId,
    super.key,
  });

  final String courseId;
  final String sequenceId;

  @override
  ConsumerState<ContentScreen> createState() => _ContentScreenState();
}

class _ContentScreenState extends ConsumerState<ContentScreen> {
  late final PageController _pageController;
  int _currentIndex = 0;
  bool _autoAdvance = false;
  // Index of the vertical that should auto-play when it becomes visible.
  // -1 means no pending auto-play.
  int _autoPlayIndex = -1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Called when any video on [verticalIndex] completes.
  /// If auto-advance is on, pages to the next vertical and marks it for
  /// auto-play. Does nothing if already on the last vertical.
  void _onVideoCompleted(int verticalIndex, SequenceDetail sequence) {
    if (!_autoAdvance) return;
    final next = verticalIndex + 1;
    if (next >= sequence.items.length) return; // end of sequence — stop
    setState(() => _autoPlayIndex = next);
    _goTo(next);
  }

  @override
  Widget build(BuildContext context) {
    final sequenceAsync =
        ref.watch(sequenceDetailProvider(blockId: widget.sequenceId));

    final currentVerticalId = sequenceAsync.asData?.value.items
        .elementAtOrNull(_currentIndex)
        ?.id;

    return Scaffold(
      appBar: AppBar(
        title: sequenceAsync.maybeWhen(
          data: (s) => s.items.isNotEmpty
              ? Text(
                  s.items[_currentIndex].pageTitle,
                  overflow: TextOverflow.ellipsis,
                )
              : const Text('Content'),
          orElse: () => const Text('Content'),
        ),
        actions: [
          if (currentVerticalId != null)
            DownloadButton(
              courseId: widget.courseId,
              sequenceId: widget.sequenceId,
              verticalId: currentVerticalId,
            ),
          const SizedBox(width: 8),
        ],
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
                  sequenceDetailProvider(blockId: widget.sequenceId),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (sequence) {
          if (sequence.items.isEmpty) {
            return const Center(child: Text('No content'));
          }

          final total = sequence.items.length;

          return Column(
            children: [
              // Progress bar.
              LinearProgressIndicator(
                value: ((_currentIndex + 1) / total).clamp(0.0, 1.0),
                minHeight: 4,
              ),

              // Content pages.
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: total,
                  onPageChanged: (index) {
                    setState(() {
                      _currentIndex = index;
                      // Clear auto-play if the user navigated manually.
                      if (index != _autoPlayIndex) _autoPlayIndex = -1;
                    });
                  },
                  itemBuilder: (context, index) {
                    final item = sequence.items[index];
                    return _VerticalPage(
                      item: item,
                      autoPlay: index == _autoPlayIndex,
                      onVideoCompleted: () =>
                          _onVideoCompleted(index, sequence),
                    );
                  },
                ),
              ),

              // Prev / Next / Complete navigation bar + auto-advance toggle.
              _NavBar(
                canGoPrev: _currentIndex > 0,
                canGoNext: _currentIndex < total - 1,
                autoAdvance: _autoAdvance,
                onPrev: () => _goTo(_currentIndex - 1),
                onNext: () => _goTo(_currentIndex + 1),
                onComplete: () => Navigator.of(context).pop(),
                onAutoAdvanceChanged: (v) => setState(() => _autoAdvance = v),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.canGoPrev,
    required this.canGoNext,
    required this.autoAdvance,
    required this.onPrev,
    required this.onNext,
    required this.onComplete,
    required this.onAutoAdvanceChanged,
  });

  final bool canGoPrev;
  final bool canGoNext;
  final bool autoAdvance;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onComplete;
  final ValueChanged<bool> onAutoAdvanceChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Auto-advance toggle.
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Auto-advance',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Switch(
                  value: autoAdvance,
                  onChanged: onAutoAdvanceChanged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Prev / Next / Complete.
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: canGoPrev ? onPrev : null,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.arrow_back, size: 18),
                        SizedBox(width: 4),
                        Text('Previous'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: canGoNext
                      ? FilledButton(
                          onPressed: onNext,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Next'),
                              SizedBox(width: 4),
                              Icon(Icons.arrow_forward, size: 18),
                            ],
                          ),
                        )
                      : FilledButton(
                          onPressed: onComplete,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check, size: 18),
                              SizedBox(width: 4),
                              Text('Complete'),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _VerticalPage extends ConsumerWidget {
  const _VerticalPage({
    required this.item,
    required this.onVideoCompleted,
    this.autoPlay = false,
  });

  final SequenceItem item;
  final bool autoPlay;
  final VoidCallback onVideoCompleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final xblockAsync = ref.watch(xblockContentProvider(blockId: item.id));

    return xblockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 8),
              Text(
                'Could not load: ${item.pageTitle}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
      data: (content) => _PageContent(
        content: content,
        item: item,
        autoPlay: autoPlay,
        onVideoCompleted: onVideoCompleted,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PageContent extends StatelessWidget {
  const _PageContent({
    required this.content,
    required this.item,
    required this.onVideoCompleted,
    this.autoPlay = false,
  });

  final XBlockContent content;
  final SequenceItem item;
  final bool autoPlay;
  final VoidCallback onVideoCompleted;

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    for (final video in content.videos) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: VideoBlock(
            video: video,
            autoPlay: autoPlay,
            onCompleted: onVideoCompleted,
          ),
        ),
      );
    }

    final strippedHtml = content.videos.isNotEmpty
        ? stripVideoBlocks(content.htmlContent)
        : content.htmlContent;
    if (strippedHtml.trim().isNotEmpty) {
      widgets.add(HtmlBlock(html: strippedHtml));
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

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widgets,
      ),
    );
  }
}
