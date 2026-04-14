import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persisted user preference for auto-advancing to the next vertical
/// when a video finishes.
///
/// Backed by [FlutterSecureStorage] (Keychain on iOS,
/// EncryptedSharedPreferences on Android), which the app already uses
/// for the cookie store. We keep the state as an `AsyncValue<bool>` so
/// callers can render loading state during the initial read.
final autoAdvanceProvider =
    AsyncNotifierProvider<AutoAdvanceNotifier, bool>(AutoAdvanceNotifier.new);

class AutoAdvanceNotifier extends AsyncNotifier<bool> {
  static const _kKey = 'auto_advance_enabled';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<bool> build() async {
    final raw = await _storage.read(key: _kKey);
    return raw == 'true';
  }

  Future<void> set({required bool enabled}) async {
    // Optimistically reflect the new value so the toggle UI responds
    // instantly, then persist. If persistence fails the in-memory value
    // still applies for this session.
    state = AsyncData(enabled);
    await _storage.write(key: _kKey, value: enabled.toString());
  }
}
