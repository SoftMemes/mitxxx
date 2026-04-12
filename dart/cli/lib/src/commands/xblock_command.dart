import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../client_factory.dart';
import '../video_parser.dart';

class XblockCommand extends Command<void> {
  XblockCommand() {
    argParser
      ..addFlag('json', negatable: false, help: 'Output video metadata as JSON.')
      ..addFlag('show-html', negatable: false, help: 'Print raw xblock HTML.');
  }

  @override
  String get name => 'xblock';

  @override
  String get description => 'Get xblock content and extract video metadata.\n'
      'BLOCK_ID: e.g. block-v1:MITxT+...+type@vertical+block@...';

  @override
  String get invocation => '${runner?.executableName} xblock <block_id> [options]';

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
    final showHtml = argResults?['show-html'] as bool? ?? false;

    final client = await buildClient(lms: true);
    final authenticated = await client.isAuthenticated();
    if (!authenticated) {
      stderr.writeln('No active session. Run: dart run bin/mitx_client.dart login');
      exit(1);
    }

    final html = await client.xblockHtml(blockId);
    if (showHtml) {
      stdout.writeln(html);
      return;
    }

    final videos = extractVideoMetadata(html);
    if (videos.isEmpty) {
      stdout.writeln('No video blocks found in this xblock.');
      return;
    }
    if (asJson) {
      stdout.writeln(JsonEncoder.withIndent('  ').convert(videos));
      return;
    }
    stdout.writeln('');
    stdout.writeln('${videos.length} video block(s) found:');
    stdout.writeln('');
    for (var i = 0; i < videos.length; i++) {
      final v = videos[i];
      stdout.writeln('  Video ${i + 1}:');
      stdout.writeln('    duration : ${v['duration'] ?? '?'}s');
      stdout.writeln('    sources  :');
      final sources = (v['sources'] as List<dynamic>?) ?? [];
      for (final src in sources) {
        stdout.writeln('      $src');
      }
      final langs = (v['transcriptLanguages'] as Map<String, dynamic>?) ?? {};
      if (langs.isNotEmpty) {
        stdout.writeln('    transcripts: ${langs.keys.join(', ')}');
      }
    }
  }
}
