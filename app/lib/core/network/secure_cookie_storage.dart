import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A [Storage] implementation for [PersistCookieJar] that persists cookie data
/// in [FlutterSecureStorage] (Keychain on iOS, EncryptedSharedPreferences on
/// Android) rather than plain files on disk.
///
/// [PersistCookieJar] serialises each domain's cookies to an opaque string and
/// passes it back via [write]. We just store those strings under namespaced
/// keys so they don't collide with other secure-storage entries.
class SecureCookieStorage implements Storage {
  SecureCookieStorage()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  static const _prefix = 'cookiejar::';
  final FlutterSecureStorage _storage;

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {
    // No setup needed — FlutterSecureStorage is ready on construction.
  }

  @override
  Future<String?> read(String key) => _storage.read(key: '$_prefix$key');

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: '$_prefix$key', value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: '$_prefix$key');

  @override
  Future<void> deleteAll(List<String> keys) async {
    await Future.wait(keys.map((k) => _storage.delete(key: '$_prefix$k')));
  }
}
