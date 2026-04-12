import 'dart:io';

import 'package:mitx_api/mitx_api.dart';
import 'package:path/path.dart' as p;

import 'file_cookie_store.dart';

final _sessionDir = p.join(
  Platform.environment['HOME'] ?? '.',
  '.mitx-dart-client',
);

/// Creates a [MitxApiClient] backed by a [FileCookieStore] stored in
/// [~/.mitx-dart-client/cookies.json]. All commands share this factory so
/// cookies persist between CLI invocations.
///
/// If [lms] is true, also re-establishes the LMS session via the OAuth
/// redirect chain. LMS JWT cookies are short-lived; commands that hit
/// courses.learn.mit.edu should pass [lms: true].
Future<MitxApiClient> buildClient({bool lms = false}) async {
  final store = FileCookieStore(_sessionDir);
  final dioClient = await DioClient.create(store);
  final client = MitxApiClient(dioClient);
  if (lms) {
    await client.ensureLmsSession();
  }
  return client;
}

/// Deletes all persisted cookies (logout).
Future<void> clearSession() async {
  final store = FileCookieStore(_sessionDir);
  await store.deleteAll();
}
