// ignore_for_file: uri_has_not_been_generated
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_preferences.g.dart';

const _kOptInKey = 'analytics_opted_in';
const _kFirstOpenKey = 'analytics_first_open_done';

@Riverpod(keepAlive: true)
class AnalyticsPreferences extends _$AnalyticsPreferences {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOptInKey) ?? true;
  }

  Future<void> setOptedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOptInKey, value);
    state = AsyncData(value);
  }

  /// Returns true and sets a persistent flag on the very first call.
  /// Subsequent calls return false, so [kEventAppOpen] only carries
  /// [kParamIsFirstOpen]=true once.
  static Future<bool> consumeFirstOpen() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kFirstOpenKey) ?? false) return false;
    await prefs.setBool(_kFirstOpenKey, true);
    return true;
  }
}
