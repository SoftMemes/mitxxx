#!/usr/bin/env dart
/// MITx unofficial Dart CLI — UNOFFICIAL, not affiliated with MIT.
///
/// Usage: dart run bin/mitx_client.dart <command> [options]
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';
import 'package:mitx_client_cli/src/commands/enrollments_command.dart';
import 'package:mitx_client_cli/src/commands/login_command.dart';
import 'package:mitx_client_cli/src/commands/logout_command.dart';
import 'package:mitx_client_cli/src/commands/outline_command.dart';
import 'package:mitx_client_cli/src/commands/sequence_command.dart';
import 'package:mitx_client_cli/src/commands/whoami_command.dart';
import 'package:mitx_client_cli/src/commands/xblock_command.dart';

Future<void> main(List<String> args) async {
  // Enable verbose logging when MITX_VERBOSE=1 is set.
  if (Platform.environment['MITX_VERBOSE'] == '1') {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) {
      stderr.writeln('[${r.loggerName}] ${r.level.name}: ${r.message}');
    });
  }

  final runner = CommandRunner<void>(
    'mitx_client',
    'MITx unofficial CLI — UNOFFICIAL, not affiliated with MIT.',
  )
    ..addCommand(LoginCommand())
    ..addCommand(LogoutCommand())
    ..addCommand(WhoamiCommand())
    ..addCommand(EnrollmentsCommand())
    ..addCommand(OutlineCommand())
    ..addCommand(SequenceCommand())
    ..addCommand(XblockCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(e.usage);
    exit(64);
  }
}
