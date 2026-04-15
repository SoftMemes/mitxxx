// ignore_for_file: uri_has_not_been_generated
import 'package:advertising_id/advertising_id.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'advertising_id_provider.g.dart';

/// Fetches the device advertising ID (IDFA on iOS, GAID on Android) once at
/// app start. Returns null when the user has limited ad tracking or the
/// platform does not support it — callers should handle null gracefully.
@Riverpod(keepAlive: true)
Future<String?> advertisingId(Ref ref) async {
  try {
    final id = await AdvertisingId.id(); // default = do not limit ad tracking
    // Some platforms return an all-zeros UUID when tracking is limited.
    // Treat that as unavailable.
    if (id == null || id == '00000000-0000-0000-0000-000000000000') return null;
    return id;
  } on Object catch (_) {
    return null;
  }
}
