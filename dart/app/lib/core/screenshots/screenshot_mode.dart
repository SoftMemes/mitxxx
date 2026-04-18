// Screenshot-mode flag + credentials, populated from --dart-define at
// compile time. Off (and empty) in every normal build; the integration
// test entrypoint enables it by passing SCREENSHOT_MODE=true.
class ScreenshotMode {
  static const bool enabled =
      bool.fromEnvironment('SCREENSHOT_MODE');

  static const String email =
      String.fromEnvironment('SCREENSHOT_EMAIL');

  static const String password =
      String.fromEnvironment('SCREENSHOT_PASSWORD');
}
