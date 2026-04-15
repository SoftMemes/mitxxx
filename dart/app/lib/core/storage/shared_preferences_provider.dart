import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provides the app-wide [SharedPreferences] instance.
///
/// Must be overridden in `main()` before `runApp`:
/// ```dart
/// final prefs = await SharedPreferences.getInstance();
/// runApp(ProviderScope(
///   overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
///   child: const EmajteeApp(),
/// ));
/// ```
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider must be overridden in main()'),
  name: 'sharedPreferences',
);
