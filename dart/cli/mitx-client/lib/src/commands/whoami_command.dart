import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';

class WhoamiCommand extends Command<void> {
  @override
  String get name => 'whoami';

  @override
  String get description => 'Show current authenticated user.';

  @override
  Future<void> run() async {
    final client = await buildClient();
    final authenticated = await client.isAuthenticated();
    if (!authenticated) {
      stderr.writeln('No active session. Run: dart run bin/mitx_client.dart login');
      exit(1);
    }
    final user = await client.currentUser();
    stdout.writeln(JsonEncoder.withIndent('  ').convert(user));
  }
}
