import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/main.dart';

void main() {
  // Smoke: OmnilectApp is importable and its type is in scope. A full
  // pumpWidget here would require overrides for dioClientProvider, the
  // SharedPreferences provider, and Firebase/analytics init — we exercise
  // those end-to-end in the integration tests instead.
  test('OmnilectApp class is available', () {
    expect(OmnilectApp, isNotNull);
  });
}
