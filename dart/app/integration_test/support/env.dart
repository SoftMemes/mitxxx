/// Typed accessors for the `INTEGRATION_*` `--dart-define` values consumed
/// by the integration_test harness.
///
/// The run script (`scripts/integration.sh`) loads `dart/app/.integration.env`
/// and forwards each variable as `--dart-define`. Each accessor throws at
/// first read if the value is blank — catching "forgot to set it" cases
/// exactly at the step that needs the value.
library;

class IntegrationEnv {
  const IntegrationEnv._();

  /// Keycloak email for the dedicated test account.
  static String get email => _require(_email, 'INTEGRATION_EMAIL');

  /// Keycloak password for the dedicated test account.
  static String get password => _require(_password, 'INTEGRATION_PASSWORD');

  /// MIT Learn list names to tick at the initial list-selection step.
  static List<String> get listNames =>
      _requireList(_listNames, 'INTEGRATION_LIST_NAMES');

  /// Alternate list names used by the swap-selection step. Must produce a
  /// different set of course tiles from [listNames].
  static List<String> get listNamesAlt =>
      _requireList(_listNamesAlt, 'INTEGRATION_LIST_NAMES_ALT');

  /// Display title of the course tile to open on the home screen.
  static String get courseTitle =>
      _require(_courseTitle, 'INTEGRATION_COURSE_TITLE');

  /// Display title of the lecture tile to open inside the course outline.
  static String get lectureTitle =>
      _require(_lectureTitle, 'INTEGRATION_LECTURE_TITLE');

  /// `true` iff at least one of the list-selection names is configured.
  /// The screenshots harness uses this to fall back to "tick the first
  /// checkbox" when the operator just wants store PNGs.
  static bool get hasListNames => _listNames.trim().isNotEmpty;

  static const _email = String.fromEnvironment('INTEGRATION_EMAIL');
  static const _password = String.fromEnvironment('INTEGRATION_PASSWORD');
  static const _listNames = String.fromEnvironment('INTEGRATION_LIST_NAMES');
  static const _listNamesAlt =
      String.fromEnvironment('INTEGRATION_LIST_NAMES_ALT');
  static const _courseTitle =
      String.fromEnvironment('INTEGRATION_COURSE_TITLE');
  static const _lectureTitle =
      String.fromEnvironment('INTEGRATION_LECTURE_TITLE');

  static String _require(String value, String name) {
    if (value.trim().isEmpty) {
      throw StateError(
        '$name is not set. '
        'Copy .integration.env.example to .integration.env, fill it in, '
        'and re-run via scripts/integration.sh.',
      );
    }
    return value;
  }

  static List<String> _requireList(String value, String name) {
    final parts = value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      throw StateError(
        '$name is not set or empty. Provide a comma-separated list of '
        'MIT Learn list display names.',
      );
    }
    return parts;
  }
}
