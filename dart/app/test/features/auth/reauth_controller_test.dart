import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('initial state is idle', () {
    final c = makeContainer();
    final state = c.read(reauthControllerProvider);
    expect(state.showPrompt, isFalse);
    expect(state.isLoggingIn, isFalse);
  });

  test('request() surfaces the prompt', () {
    final c = makeContainer();
    c.read(reauthControllerProvider.notifier).request();
    final state = c.read(reauthControllerProvider);
    expect(state.showPrompt, isTrue);
    expect(state.isLoggingIn, isFalse);
  });

  test('request() coalesces — second call while prompt is up is a no-op', () {
    final c = makeContainer();
    final notifier = c.read(reauthControllerProvider.notifier)..request();
    final first = c.read(reauthControllerProvider);
    notifier.request();
    final second = c.read(reauthControllerProvider);
    expect(identical(first.showPrompt, second.showPrompt), isTrue);
    expect(first.isLoggingIn, second.isLoggingIn);
  });

  test('dismiss() emits false on outcomes + returns to idle', () async {
    final c = makeContainer();
    final notifier = c.read(reauthControllerProvider.notifier)..request();
    final outcomeFuture = notifier.outcomes.first;
    notifier.dismiss();
    expect(await outcomeFuture, isFalse);
    expect(c.read(reauthControllerProvider).showPrompt, isFalse);
  });

  test('beginLogin() hides prompt, sets isLoggingIn', () {
    final c = makeContainer();
    c.read(reauthControllerProvider.notifier)
      ..request()
      ..beginLogin();
    final state = c.read(reauthControllerProvider);
    expect(state.showPrompt, isFalse);
    expect(state.isLoggingIn, isTrue);
  });

  test('onLoginSucceeded() emits true, returns to idle', () async {
    final c = makeContainer();
    final notifier = c.read(reauthControllerProvider.notifier)
      ..request()
      ..beginLogin();
    final outcomeFuture = notifier.outcomes.first;
    notifier.onLoginSucceeded();
    expect(await outcomeFuture, isTrue);
    final state = c.read(reauthControllerProvider);
    expect(state.showPrompt, isFalse);
    expect(state.isLoggingIn, isFalse);
  });

  test('onLoginAbandoned() re-surfaces prompt without emitting outcome', () async {
    final c = makeContainer();
    final notifier = c.read(reauthControllerProvider.notifier)
      ..request()
      ..beginLogin();

    // Track outcomes: none should fire from abandon alone.
    final emitted = <bool>[];
    final sub = notifier.outcomes.listen(emitted.add);

    notifier.onLoginAbandoned();
    // Give the stream a chance.
    await Future<void>.delayed(Duration.zero);

    final state = c.read(reauthControllerProvider);
    expect(state.showPrompt, isTrue);
    expect(state.isLoggingIn, isFalse);
    expect(emitted, isEmpty);
    await sub.cancel();
  });
}
