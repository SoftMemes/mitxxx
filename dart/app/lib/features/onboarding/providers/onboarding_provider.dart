// ignore_for_file: uri_has_not_been_generated
import 'package:omnilect/core/storage/shared_preferences_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'onboarding_provider.g.dart';

const _kOnboardingAcknowledgedKey = 'onboarding_acknowledged';

/// Tracks whether the user has acknowledged the onboarding disclaimer.
///
/// Backed by [SharedPreferences] so it persists across launches and
/// is independent of auth state. Once set to true it is never reset
/// (only a full app-data wipe / reinstall clears it).
@Riverpod(keepAlive: true)
class OnboardingAcknowledged extends _$OnboardingAcknowledged {
  @override
  bool build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return prefs.getBool(_kOnboardingAcknowledgedKey) ?? false;
  }

  /// Persists the acknowledgement and updates state.
  Future<void> acknowledge() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_kOnboardingAcknowledgedKey, true);
    state = true;
  }
}
