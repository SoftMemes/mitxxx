import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';

class SequenceCommand extends Command<void> {
  SequenceCommand() {
    argParser.addFlag('json', negatable: false, help: 'Output raw JSON.');
  }

  @override
  String get name => 'sequence';

  @override
  String get description => 'Show items (verticals) in a sequence.\n'
      'BLOCK_ID: e.g. block-v1:MITxT+...+type@sequential+block@...';

  @override
  String get invocation => '${runner?.executableName} sequence <block_id> [options]';

  @override
  Future<void> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      stderr.writeln('Error: block_id is required.');
      stderr.writeln(usage);
      exit(1);
    }
    final blockId = rest.first;
    final asJson = argResults?['json'] as bool? ?? false;

    final client = await buildClient(lms: true);
    final authenticated = await client.isAuthenticated();
    if (!authenticated) {
      stderr.writeln('No active session. Run: dart run bin/mitx_client.dart login');
      exit(1);
    }

    final data = await client.sequence(blockId);
    if (asJson) {
      stdout.writeln(JsonEncoder.withIndent('  ').convert(data));
      return;
    }
    final items = (data['items'] as List<dynamic>?) ?? [];
    stdout.writeln('');
    stdout.writeln('${items.length} items in sequence:');
    stdout.writeln('');
    for (final item in items) {
      final i = item as Map<String, dynamic>;
      final type = (i['type'] as String? ?? '?').padRight(8);
      stdout.writeln('  [$type] ${i['page_title'] ?? '?'}');
      stdout.writeln('           id: ${i['id'] ?? '?'}');
    }
  }
}
