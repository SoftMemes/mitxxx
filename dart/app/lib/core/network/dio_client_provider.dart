// ignore_for_file: uri_has_not_been_generated
import 'package:emajtee/core/network/secure_cookie_store.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'dio_client_provider.g.dart';

/// Builds a [DioClient] backed by a [SecureCookieStore] that stores session
/// cookies in `FlutterSecureStorage`. Call this once in `main` before
/// `runApp`, then override [dioClientProvider] with the result.
Future<DioClient> buildDioClient() async {
  return DioClient.create(SecureCookieStore());
}

/// Synchronous provider — always overridden at startup by `main` with the
/// value returned from `buildDioClient`. Throws if accessed before override.
@Riverpod(keepAlive: true)
DioClient dioClient(Ref ref) {
  throw StateError(
    'dioClientProvider must be overridden in main() via buildDioClient()',
  );
}
