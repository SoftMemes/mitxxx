import 'dart:convert';

/// Generic read-through cache helper.
///
/// 1. Read from cache. If data exists, return it immediately.
/// 2. Fetch fresh data from the API and update cache.
/// 3. On network error: return cached data if available, otherwise rethrow.
Future<T> cachedFetch<T>({
  required Future<({String data, DateTime cachedAt})?> Function() readCache,
  required Future<void> Function(String json) writeCache,
  required Future<dynamic> Function() fetchFromApi,
  required T Function(Map<String, dynamic> json) fromJson,
  required Map<String, dynamic> Function(T value) toJson,
}) async {
  final cached = await readCache();

  if (cached != null) {
    // Return cached data immediately.
    final value = fromJson(jsonDecode(cached.data) as Map<String, dynamic>);

    // Fetch fresh in background — fire and forget (errors are swallowed).
    _refreshInBackground(
      fetchFromApi: fetchFromApi,
      writeCache: writeCache,
      toJson: toJson,
    );

    return value;
  }

  // No cache — must fetch. Let any error propagate.
  final response = await fetchFromApi();
  final jsonMap = response is Map<String, dynamic>
      ? response
      : response as Map<String, dynamic>;
  final value = fromJson(jsonMap);
  await writeCache(jsonEncode(toJson(value)));
  return value;
}

Future<void> _refreshInBackground<T>({
  required Future<dynamic> Function() fetchFromApi,
  required Future<void> Function(String json) writeCache,
  required Map<String, dynamic> Function(T value) toJson,
}) async {
  try {
    final response = await fetchFromApi();
    await writeCache(jsonEncode(response));
  } catch (_) {
    // Background refresh failure is silent — cached data remains.
  }
}
