import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:path/path.dart' as p;

final _sessionDir = p.join(
  Platform.environment['HOME'] ?? '.',
  '.mitx-dart-client',
  '.cookies',
);

/// Creates a [MitxApiClient] backed by a [PersistCookieJar] stored in
/// [~/.mitx-dart-client/.cookies/]. All commands share this factory so
/// cookies persist between CLI invocations.
Future<MitxApiClient> buildClient() async {
  final jar = PersistCookieJar(storage: FileStorage(_sessionDir));
  await jar.forceInit();
  final dioClient = DioClient(cookieJar: jar);
  return MitxApiClient(dioClient);
}

/// Deletes all persisted cookies (logout).
Future<void> clearSession() async {
  final jar = PersistCookieJar(storage: FileStorage(_sessionDir));
  await jar.forceInit();
  await jar.deleteAll();
}
