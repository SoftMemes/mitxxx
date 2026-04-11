// ignore_for_file: uri_has_not_been_generated
import 'package:emajtee/core/network/dio_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'dio_client_provider.g.dart';

@Riverpod(keepAlive: true)
DioClient dioClient(Ref ref) {
  // The auth interceptor callback is set by auth_provider after construction
  // to avoid a circular dependency. The client starts without an interceptor;
  // auth_provider calls client.addAuthInterceptor() during its build().
  return DioClient();
}
