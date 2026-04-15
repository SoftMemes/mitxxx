import 'dart:io';

import 'package:omnilect/features/cast/providers/cast_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';

/// Cast button for the video player overlay.
///
/// On iOS: renders an [AirPlayRoutePickerView] which shows both AirPlay and
/// Chromecast devices in the system route picker (Google Cast SDK registers
/// itself as a media output device on iOS).
///
/// On Android: renders an [IconButton] that opens a device-picker dialog using
/// [GoogleCastDiscoveryManager].
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

    if (Platform.isIOS) {
      return SizedBox(
        width: iconSize + 8,
        height: iconSize + 8,
        child: AirPlayRoutePickerView(
          tintColor: isConnected ? Colors.blue : Colors.white,
          activeTintColor: Colors.blue,
          backgroundColor: Colors.transparent,
        ),
      );
    }

    // Android: custom icon that opens a device-picker dialog.
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
// Android device picker dialog
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
            if (devices.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Looking for cast devices…'),
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
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
