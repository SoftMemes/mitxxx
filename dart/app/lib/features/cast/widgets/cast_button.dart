import 'dart:io';

import 'package:omnilect/features/cast/providers/cast_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';

/// Cast button for the video player overlay.
///
/// Renders the same Material cast icon on both platforms. Tapping opens a
/// device picker that lists discovered Chromecast receivers. On iOS, the
/// picker also includes an AirPlay row that opens the native AirPlay picker
/// (via a transparent [AirPlayRoutePickerView] layered over the tile — the
/// plugin does not expose a way to trigger it programmatically).
class CastButton extends ConsumerWidget {
  const CastButton({
    required this.iconSize,
    super.key,
  });

  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final castState = ref.watch(castControllerProvider);
    final isConnected = castState.isConnected || castState.isConnecting;

    return IconButton(
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(
        minWidth: iconSize + 8,
        minHeight: iconSize + 8,
      ),
      icon: Icon(
        isConnected ? Icons.cast_connected : Icons.cast,
        size: iconSize,
        color: isConnected ? Colors.blue : Colors.white,
      ),
      tooltip: isConnected ? 'Casting — tap to disconnect' : 'Cast to device',
      onPressed: () => isConnected
          ? _confirmDisconnect(context, ref)
          : _showDevicePicker(context, ref),
    );
  }

  Future<void> _showDevicePicker(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(castControllerProvider.notifier);

    await showDialog<void>(
      context: context,
      builder: (ctx) => _DevicePickerDialog(
        onDeviceSelected: (device) {
          Navigator.of(ctx).pop();
          notifier.connectToDevice(device);
        },
      ),
    );
  }

  Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop casting?'),
        content: const Text('Stop casting and return to local playback?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep casting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Stop cast'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(castControllerProvider.notifier).disconnect();
    }
  }
}

// ---------------------------------------------------------------------------
// Device picker dialog
// ---------------------------------------------------------------------------

class _DevicePickerDialog extends StatelessWidget {
  const _DevicePickerDialog({required this.onDeviceSelected});

  final void Function(GoogleCastDevice) onDeviceSelected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cast to device'),
      content: SizedBox(
        width: double.maxFinite,
        child: StreamBuilder<List<GoogleCastDevice>>(
          stream: GoogleCastDiscoveryManager.instance.devicesStream,
          builder: (context, snapshot) {
            final devices = snapshot.data ?? [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Looking for cast devices…'),
                      ],
                    ),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (ctx, i) {
                      final device = devices[i];
                      return ListTile(
                        leading: const Icon(Icons.cast),
                        title: Text(device.friendlyName),
                        onTap: () => onDeviceSelected(device),
                      );
                    },
                  ),
                if (Platform.isIOS) const _AirPlayRow(),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// An "AirPlay" row for the iOS device picker.
///
/// A standard [ListTile] with an invisible [AirPlayRoutePickerView] stacked on
/// top — the native route picker intercepts the tap and opens the system
/// AirPlay chooser. Our dialog stays open behind the system modal; the user
/// dismisses it via Cancel afterwards (the plugin exposes no tap callback to
/// auto-dismiss).
class _AirPlayRow extends StatelessWidget {
  const _AirPlayRow();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        ListTile(
          leading: Icon(Icons.airplay),
          title: Text('AirPlay'),
        ),
        Positioned.fill(
          child: AirPlayRoutePickerView(
            tintColor: Colors.transparent,
            activeTintColor: Colors.transparent,
            backgroundColor: Colors.transparent,
          ),
        ),
      ],
    );
  }
}
