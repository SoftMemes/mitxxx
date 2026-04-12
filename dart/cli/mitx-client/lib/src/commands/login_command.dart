import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mitx_api/mitx_api.dart';

import '../client_factory.dart';

class LoginCommand extends Command<void> {
  LoginCommand() {
    argParser
      ..addOption('email', abbr: 'e', help: 'MITx account email')
      ..addOption('password', abbr: 'p', help: 'MITx account password (prompted if omitted)');
  }

  @override
  String get name => 'login';

  @override
  String get description => 'Login to MITx and save session cookies.';

  @override
  Future<void> run() async {
    String? email = argResults?['email'] as String?;
    String? password = argResults?['password'] as String?;

    if (email == null || email.isEmpty) {
      stdout.write('Email: ');
      email = stdin.readLineSync()?.trim() ?? '';
    }
    if (password == null || password.isEmpty) {
      stdout.write('Password: ');
      // Disable echo for password entry
      stdin.echoMode = false;
      password = stdin.readLineSync()?.trim() ?? '';
      stdin.echoMode = true;
      stdout.writeln();
    }

    if (email.isEmpty || password.isEmpty) {
      stderr.writeln('Error: email and password are required.');
      exit(1);
    }

    final client = await buildClient();
    try {
      final user = await client.login(email, password);
      stdout.writeln('Logged in as ${user['username']} (${user['email']})');
      stdout.writeln('Session saved to ~/.mitx-dart-client/.cookies/');
    } on AuthError catch (e) {
      stderr.writeln('Login failed: ${e.message}');
      exit(1);
    } on Object catch (e) {
      stderr.writeln('Login failed: $e');
      exit(1);
    }
  }
}
