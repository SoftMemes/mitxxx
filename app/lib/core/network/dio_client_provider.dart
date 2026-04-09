// ignore_for_file: uri_has_not_been_generated
import 'package:emajtee/core/network/dio_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'dio_client_provider.g.dart';

@Riverpod(keepAlive: true)
DioClient dioClient(DioClientRef ref) {
  final client = DioClient();

  client.addAuthInterceptor(
    onAuthFailed: () {
      // Invalidate auth state on unrecoverable 401 — router will redirect to login.
      // We do this via a post-frame callback to avoid calling notifiers during a request.
      Future<void>.delayed(Duration.zero, () {
        // Auth provider is invalidated to reset to unauthenticated state.
        // The router's refreshListenable will pick up the change.
        ref.invalidateSelf();
      });
    },
  );

  return client;
}
