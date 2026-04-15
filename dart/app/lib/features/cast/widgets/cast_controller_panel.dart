import 'package:emajtee/features/cast/models/cast_state.dart';
import 'package:emajtee/features/cast/providers/cast_controller.dart';
import 'package:emajtee/features/player/widgets/unified_scrub_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Full-screen cast controller that replaces [LectureVideoPlayer] while a
/// cast session is active.
///
/// Shows: device name, scrub bar spanning the full lecture, play/pause,
/// speed selector, stop-cast button, and a chapter list with the active
/// vertical highlighted.
class CastControllerPanel extends ConsumerStatefulWidget {
  const CastControllerPanel({super.key});

  @override
  ConsumerState<CastControllerPanel> createState() =>
      _CastControllerPanelState();
}

class _CastControllerPanelState extends ConsumerState<CastControllerPanel> {
  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  bool _scrubbing = false;
  double? _pendingSeekTarget;

  Future<void> _pickSpeed(CastState state) async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in _speeds)
              ListTile(
                leading: Icon(s == state.speed ? Icons.check : null),
                title: Text('${s}x'),
                onTap: () => Navigator.of(ctx).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(castControllerProvider.notifier).setSpeed(picked);
    }
  }

  void _onSeek(double secs) {
    setState(() {
      _pendingSeekTarget = secs;
      _scrubbing = true;
    });
    ref.read(castControllerProvider.notifier).seekGlobal(secs);
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castControllerProvider);
    final queue = castState.queue;

    // Resolve display position — pin to pending target while seek is in flight.
    final target = _pendingSeekTarget;
    if (_scrubbing && target != null) {
      if ((castState.globalPosition - target).abs() < 1.0) {
        _scrubbing = false;
        _pendingSeekTarget = null;
      }
    }
    final displayPosition =
        (_scrubbing && target != null) ? target : castState.globalPosition;

    // Segment boundaries for the scrub bar dividers.
    final boundaries = queue
        .map((item) => item.globalStartTime)
        .where((t) => t > 0)
        .toList();

    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            // Header: device name + stop button.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.cast_connected, color: Colors.white70,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Casting to ${castState.deviceName ?? 'device'}',
                      style: const TextStyle(color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(castControllerProvider.notifier).disconnect(),
                    icon: const Icon(Icons.stop_circle_outlined,
                        color: Colors.white70),
                    label: const Text('Stop',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),

            // Aspect-ratio placeholder showing cast icon.
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.cast_connected,
                        color: Colors.white54, size: 64),
                    const SizedBox(height: 12),
                    Text(
                      castState.deviceName ?? 'Cast device',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),

            // Scrub bar.
            ColoredBox(
              color: Colors.black,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 24,
                  end: 12,
                  top: 4,
                  bottom: 4,
                ),
                child: UnifiedScrubBar(
                  position: displayPosition,
                  duration: castState.totalDuration,
                  segmentBoundaries: boundaries,
                  onSeekStart: () => setState(() => _scrubbing = true),
                  onSeekEnd: () {},
                  onSeek: _onSeek,
                ),
              ),
            ),

            // Controls row: speed | play/pause.
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Speed pill.
                  GestureDetector(
                    onTap: () => _pickSpeed(castState),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_formatSpeed(castState.speed)}x',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 32),
                  // Play / Pause.
                  IconButton(
                    icon: Icon(
                      castState.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 44,
                    ),
                    onPressed: castState.isPlaying
                        ? () =>
                            ref.read(castControllerProvider.notifier).pause()
                        : () =>
                            ref.read(castControllerProvider.notifier).play(),
                  ),
                ],
              ),
            ),

            // Chapter list.
            if (queue.isNotEmpty) ...[
              const Divider(color: Colors.white24, height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: queue.length,
                  itemBuilder: (ctx, i) {
                    final item = queue[i];
                    final isActive = i == castState.activeItemIndex;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isActive
                            ? Icons.play_arrow
                            : Icons.radio_button_unchecked,
                        color: isActive ? Colors.blue : Colors.white54,
                        size: 18,
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white70,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      onTap: () =>
                          ref.read(castControllerProvider.notifier)
                              .seekGlobal(item.globalStartTime),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatSpeed(double s) {
    if (s == s.roundToDouble()) return s.toStringAsFixed(0);
    return s.toString();
  }
}
