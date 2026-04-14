import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/auto_advance_provider.dart';
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
  // Index of the vertical that should auto-play when it becomes visible.
  // -1 means no pending auto-play.
  int _autoPlayIndex = -1;
  // Index of the vertical that should auto-enter fullscreen when visible.
  // Set alongside _autoPlayIndex when the previous video completed while
  // in fullscreen, so the fullscreen experience persists across advances.
  int _autoFullScreenIndex = -1;

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
  /// auto-play. If the completed video was in fullscreen, also marks it
  /// to re-enter fullscreen so the experience carries across advances.
  /// Does nothing if already on the last vertical.
  void _onVideoCompleted(
    int verticalIndex,
    SequenceDetail sequence, {
    required bool wasFullScreen,
  }) {
    // Read the current persisted preference synchronously — if it hasn't
    // loaded yet, default to off rather than auto-advancing by surprise.
    final autoAdvance = ref.read(autoAdvanceProvider).value ?? false;
    if (!autoAdvance) return;
    final next = verticalIndex + 1;
    if (next >= sequence.items.length) return; // end of sequence — stop
    setState(() {
      _autoPlayIndex = next;
      _autoFullScreenIndex = wasFullScreen ? next : -1;
    });
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
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                      // Clear auto-play / auto-fullscreen if the user
                      // navigated manually rather than auto-advancing.
                      if (index != _autoPlayIndex) _autoPlayIndex = -1;
                      if (index != _autoFullScreenIndex) {
                        _autoFullScreenIndex = -1;
                      }
                    });
                  },
                  itemBuilder: (context, index) {
                    final item = sequence.items[index];
                    return _VerticalPage(
                      item: item,
                      autoPlay: index == _autoPlayIndex,
                      autoFullScreen: index == _autoFullScreenIndex,
                      onVideoCompleted: (wasFullScreen) =>
                          _onVideoCompleted(
                        index,
                        sequence,
                        wasFullScreen: wasFullScreen,
                      ),
                    );
                  },
                ),
              ),

              // Prev / Next / Complete navigation bar + auto-advance toggle.
              _NavBar(
                canGoPrev: _currentIndex > 0,
                canGoNext: _currentIndex < total - 1,
                // Default to false while the persisted value is loading so
                // the toggle renders deterministically on first frame.
                autoAdvance: ref.watch(autoAdvanceProvider).value ?? false,
                onPrev: () => _goTo(_currentIndex - 1),
                onNext: () => _goTo(_currentIndex + 1),
                onComplete: () => Navigator.of(context).pop(),
                onAutoAdvanceChanged: (v) => ref
                    .read(autoAdvanceProvider.notifier)
                    .set(enabled: v),
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
    this.autoFullScreen = false,
  });

  final SequenceItem item;
  final bool autoPlay;
  final bool autoFullScreen;
  final ValueChanged<bool> onVideoCompleted;

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
        autoFullScreen: autoFullScreen,
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
    this.autoFullScreen = false,
  });

  final XBlockContent content;
  final SequenceItem item;
  final bool autoPlay;
  final bool autoFullScreen;
  final ValueChanged<bool> onVideoCompleted;

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
            autoFullScreen: autoFullScreen,
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
                Icon(Icons.info_outline, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${item.pageTitle} — no displayable content',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
