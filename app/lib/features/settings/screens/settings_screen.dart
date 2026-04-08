import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: const [
          ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('About'),
            subtitle: Text(
              'MITxxx is an unofficial app and is not affiliated with MIT.',
            ),
          ),
          // TODO(settings): Add sync preferences, storage info, sign out.
        ],
      ),
    );
  }
}
