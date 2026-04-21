import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connectivity_provider.g.dart';

/// Streams the online state of the device.
/// Defaults to true (online) until the first connectivity event arrives.
@Riverpod(keepAlive: true)
Stream<bool> isOnline(Ref ref) async* {
  final initial = await Connectivity().checkConnectivity();
  yield initial.any((r) => r != ConnectivityResult.none);

  await for (final results in Connectivity().onConnectivityChanged) {
    yield results.any((r) => r != ConnectivityResult.none);
  }
}
