import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/sequence_provider.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/courses/screens/fullscreen_video_screen.dart';
import 'package:emajtee/features/courses/utils/xblock_parser.dart';
import 'package:emajtee/features/courses/widgets/html_block.dart';
import 'package:emajtee/features/courses/widgets/video_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ContentScreen extends ConsumerStatefulWidget {
  const ContentScreen({
    super.key,
    required this.courseId,
    required this.sequenceId,
  });

  final String courseId;
  final String sequenceId;

  @override
  ConsumerState<ContentScreen> createState() => _ContentScreenState();
}

class _ContentScreenState extends ConsumerState<ContentScreen> {
  late final PageController _pageController;
  int _currentIndex = 0;

  // Keyed by '$verticalIndex:$videoIndex' — used to scroll to a video
  // block after returning from full-screen playback.
  final Map<String, GlobalKey> _videoKeys = {};

  // If non-null, scroll to this key after the next frame renders.
  GlobalKey? _pendingScrollKey;

  GlobalKey _videoKey(int verticalIdx, int videoIdx) {
    final k = '$verticalIdx:$videoIdx';
    return _videoKeys.putIfAbsent(k, GlobalKey.new);
  }

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

  Future<void> _openFullscreen(
    SequenceDetail sequence,
    int verticalIndex,
    int videoIndex,
  ) async {
    final result = await Navigator.of(context).push<FullscreenResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FullscreenVideoScreen(
          sequence: sequence,
          initialVerticalIndex: verticalIndex,
          initialVideoIndex: videoIndex,
        ),
      ),
    );

    if (!mounted || result == null) return;

    // Navigate to the vertical the user ended up on.
    if (result.verticalIndex != _currentIndex) {
      setState(() => _currentIndex = result.verticalIndex);
      _pageController.jumpToPage(result.verticalIndex);
    }

    // If the user closed the player early, scroll to that video block.
    if (result.closedEarly && result.videoIndex != null) {
      final key = _videoKey(result.verticalIndex, result.videoIndex!);
      setState(() => _pendingScrollKey = key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sequenceAsync =
        ref.watch(sequenceDetailProvider(blockId: widget.sequenceId));

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
                  onPageChanged: (index) =>
                      setState(() => _currentIndex = index),
                  itemBuilder: (context, index) {
                    final item = sequence.items[index];
                    return _VerticalPage(
                      item: item,
                      verticalIndex: index,
                      videoKeyBuilder: _videoKey,
                      pendingScrollKey:
                          index == _currentIndex ? _pendingScrollKey : null,
                      onPendingScrollDone: () =>
                          setState(() => _pendingScrollKey = null),
                      onFullscreen: (videoIndex) =>
                          _openFullscreen(sequence, index, videoIndex),
                    );
                  },
                ),
              ),

              // Prev / Next navigation bar.
              _NavBar(
                canGoPrev: _currentIndex > 0,
                canGoNext: _currentIndex < total - 1,
                onPrev: () => _goTo(_currentIndex - 1),
                onNext: () => _goTo(_currentIndex + 1),
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
    required this.onPrev,
    required this.onNext,
  });

  final bool canGoPrev;
  final bool canGoNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
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
              child: FilledButton(
                onPressed: canGoNext ? onNext : null,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Next'),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _VerticalPage extends ConsumerStatefulWidget {
  const _VerticalPage({
    required this.item,
    required this.verticalIndex,
    required this.videoKeyBuilder,
    required this.pendingScrollKey,
    required this.onPendingScrollDone,
    required this.onFullscreen,
  });

  final SequenceItem item;
  final int verticalIndex;
  final GlobalKey Function(int verticalIdx, int videoIdx) videoKeyBuilder;
  final GlobalKey? pendingScrollKey;
  final VoidCallback onPendingScrollDone;
  final void Function(int videoIndex) onFullscreen;

  @override
  ConsumerState<_VerticalPage> createState() => _VerticalPageState();
}

class _VerticalPageState extends ConsumerState<_VerticalPage> {
  @override
  void didUpdateWidget(_VerticalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingScrollKey != null &&
        widget.pendingScrollKey != oldWidget.pendingScrollKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = widget.pendingScrollKey?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
        widget.onPendingScrollDone();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final xblockAsync =
        ref.watch(xblockContentProvider(blockId: widget.item.id));

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
                'Could not load: ${widget.item.pageTitle}',
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
        item: widget.item,
        verticalIndex: widget.verticalIndex,
        videoKeyBuilder: widget.videoKeyBuilder,
        onFullscreen: widget.onFullscreen,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PageContent extends StatelessWidget {
  const _PageContent({
    required this.content,
    required this.item,
    required this.verticalIndex,
    required this.videoKeyBuilder,
    required this.onFullscreen,
  });

  final XBlockContent content;
  final SequenceItem item;
  final int verticalIndex;
  final GlobalKey Function(int verticalIdx, int videoIdx) videoKeyBuilder;
  final void Function(int videoIndex) onFullscreen;

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    // Native video players — rendered first, one per extracted video block.
    for (var i = 0; i < content.videos.length; i++) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: VideoBlock(
            key: videoKeyBuilder(verticalIndex, i),
            video: content.videos[i],
            onFullscreen: () => onFullscreen(i),
          ),
        ),
      );
    }

    // HTML content — strip video xblock containers so we don't double-render
    // them, then show the remaining HTML (text, images, problems, etc.).
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
