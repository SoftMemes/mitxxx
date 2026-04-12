import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';

class EnrollmentsCommand extends Command<void> {
  EnrollmentsCommand() {
    argParser.addFlag('json', negatable: false, help: 'Output raw JSON.');
  }

  @override
  String get name => 'enrollments';

  @override
  String get description => 'List enrolled courses.';

  @override
  Future<void> run() async {
    final asJson = argResults?['json'] as bool? ?? false;
    final client = await buildClient();
    final authenticated = await client.isAuthenticated();
    if (!authenticated) {
      stderr.writeln('No active session. Run: dart run bin/mitx_client.dart login');
      exit(1);
    }
    final data = await client.enrollments();
    if (asJson) {
      stdout.writeln(JsonEncoder.withIndent('  ').convert(data));
      return;
    }
    if (data.isEmpty) {
      stdout.writeln('No enrollments found.');
      return;
    }
    for (final enr in data) {
      final run = (enr as Map<String, dynamic>)['run'] as Map<String, dynamic>? ?? {};
      stdout.writeln('');
      stdout.writeln('  ${run['title'] ?? '?'}');
      stdout.writeln('    courseware_id : ${run['courseware_id'] ?? '?'}');
      stdout.writeln('    mode          : ${enr['enrollment_mode'] ?? '?'}');
      stdout.writeln('    start         : ${run['start_date'] ?? '?'}');
      stdout.writeln('    end           : ${run['end_date'] ?? '?'}');
      stdout.writeln('    url           : ${run['courseware_url'] ?? '?'}');
    }
  }
}
