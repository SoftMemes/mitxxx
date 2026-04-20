/// Abstract interface for raw cookie persistence.
///
/// Cookies are stored as host → {name → value} maps. No dart:io Cookie parsing
/// is used anywhere — values are kept as raw strings, which allows JWT tokens
/// and other special-character values that dart:io rejects.
abstract class CookieStore {
  /// Returns all persisted cookies as host → {name → value}.
  Future<Map<String, Map<String, String>>> loadAll();

  /// Replaces the entire persisted cookie map.
  Future<void> saveAll(Map<String, Map<String, String>> cookies);

  /// Deletes all persisted cookies.
  Future<void> deleteAll();
}
