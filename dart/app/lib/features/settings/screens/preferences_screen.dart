import 'package:omnilect/core/analytics/analytics_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.bar_chart_outlined),
            title: const Text('Share usage analytics'),
            subtitle: const Text(
              'Help improve MITxxx by sharing anonymous usage data. '
              'No course content, names, or emails are ever sent.',
            ),
            value: ref.watch(analyticsPreferencesProvider).value ?? true,
            onChanged: (value) =>
                ref.read(analyticsPreferencesProvider.notifier).setOptedIn(value),
          ),
        ],
      ),
    );
  }
}
