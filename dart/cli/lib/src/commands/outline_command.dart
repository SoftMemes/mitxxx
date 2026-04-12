import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';

class OutlineCommand extends Command<void> {
  OutlineCommand() {
    argParser.addFlag('json', negatable: false, help: 'Output raw JSON.');
  }

  @override
  String get name => 'outline';

  @override
  String get description => 'Show course outline (sections and sequences).\n'
      'COURSE_ID: e.g. course-v1:MITxT+24.09x+1T2025';

  @override
  String get invocation => '${runner?.executableName} outline <course_id> [options]';

  @override
  Future<void> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      stderr.writeln('Error: course_id is required.');
      stderr.writeln(usage);
      exit(1);
    }
    final courseId = rest.first;
    final asJson = argResults?['json'] as bool? ?? false;

    final client = await buildClient(lms: true);
    final authenticated = await client.isAuthenticated();
    if (!authenticated) {
      stderr.writeln('No active session. Run: dart run bin/mitx_client.dart login');
      exit(1);
    }

    final data = await client.courseOutline(courseId);
    if (asJson) {
      stdout.writeln(JsonEncoder.withIndent('  ').convert(data));
      return;
    }
    stdout.writeln('');
    stdout.writeln('Course: ${data['title'] ?? courseId}');
    stdout.writeln('Start:  ${data['course_start'] ?? '?'}  End: ${data['course_end'] ?? '?'}');
    stdout.writeln('');
    final outline = (data['outline'] as Map<String, dynamic>?) ?? {};
    final sections = (outline['sections'] as List<dynamic>?) ?? [];
    for (final section in sections) {
      final s = section as Map<String, dynamic>;
      stdout.writeln('  [${s['title'] ?? '?'}]');
      stdout.writeln('    id: ${s['id'] ?? '?'}');
      final seqIds = (s['sequence_ids'] as List<dynamic>?) ?? [];
      for (final seqId in seqIds) {
        stdout.writeln('    seq: $seqId');
      }
      stdout.writeln('');
    }
  }
}
