import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';

class LogoutCommand extends Command<void> {
  @override
  String get name => 'logout';

  @override
  String get description => 'Delete saved session cookies.';

  @override
  Future<void> run() async {
    await clearSession();
    stdout.writeln('Session deleted.');
  }
}
