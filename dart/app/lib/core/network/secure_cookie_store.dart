import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omnilect/core/network/cookie_store.dart';

/// [CookieStore] implementation that persists cookies in [FlutterSecureStorage]
/// (Keychain on iOS, Keystore-backed AES-GCM on Android).
///
/// All cookies are stored as a single JSON blob under the key [_kKey].
/// This avoids the dart:io Cookie class entirely — values are raw strings.
class SecureCookieStore implements CookieStore {
  SecureCookieStore() : _storage = const FlutterSecureStorage();

  static const _kKey = 'mitx_cookies_v2';
  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, Map<String, String>>> loadAll() async {
    final raw = await _storage.read(key: _kKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, String>>{};
      for (final entry in decoded.entries) {
        final host = entry.key as String;
        final cookies = entry.value;
        if (cookies is Map) {
          result[host] = {
            for (final c in cookies.entries)
              c.key as String: c.value as String,
          };
        }
      }
      return result;
    } on Object {
      return {};
    }
  }

  @override
  Future<void> saveAll(Map<String, Map<String, String>> cookies) async {
    await _storage.write(key: _kKey, value: jsonEncode(cookies));
  }

  @override
  Future<void> deleteAll() async {
    await _storage.delete(key: _kKey);
  }
}
