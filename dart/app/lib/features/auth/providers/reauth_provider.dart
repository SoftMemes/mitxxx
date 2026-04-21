import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reauth_provider.g.dart';

/// State held by [ReauthController].
///
/// - [showPrompt] drives the "session expired" modal in `ReauthGate`.
/// - [isLoggingIn] hides the modal while the login sheet is on-screen and
///   re-opens it automatically when the sheet is dismissed without success
///   (via [ReauthController.onLoginAbandoned]).
class ReauthState {
  const ReauthState({required this.showPrompt, required this.isLoggingIn});

  const ReauthState.idle()
      : showPrompt = false,
        isLoggingIn = false;

  final bool showPrompt;
  final bool isLoggingIn;

  ReauthState copyWith({bool? showPrompt, bool? isLoggingIn}) => ReauthState(
        showPrompt: showPrompt ?? this.showPrompt,
        isLoggingIn: isLoggingIn ?? this.isLoggingIn,
      );
}

/// Coordinates the "session expired" flow. Callers (the sync layer's
/// `SessionRefreshManager` for `SessionKind.mitxonline`) invoke [request] to
/// surface the dialog and await the next value on [outcomes] to learn whether
/// the user completed a login (`true`) or dismissed the prompt (`false`).
///
/// The user's cached content is left untouched; only Settings → Sign Out
/// wipes the local database.
@Riverpod(keepAlive: true)
class ReauthController extends _$ReauthController {
  final _outcomes = StreamController<bool>.broadcast();

  @override
  ReauthState build() {
    ref.onDispose(_outcomes.close);
    return const ReauthState.idle();
  }

  /// Broadcast of terminal outcomes: `true` on successful login, `false` when
  /// the user dismisses the prompt. Re-opening the prompt after
  /// [onLoginAbandoned] does not emit — it waits for a terminal action.
  Stream<bool> get outcomes => _outcomes.stream;

  /// Surface the prompt. Coalesces: a second `request()` while a prompt is
  /// already showing is a no-op.
  void request() {
    if (state.showPrompt || state.isLoggingIn) return;
    state = const ReauthState(showPrompt: true, isLoggingIn: false);
  }

  /// User tapped "Dismiss" — drop the pending prompt. Emits `false` so any
  /// awaiting `SessionRefreshManager` can report the failure back to the
  /// sync isolate.
  void dismiss() {
    if (!state.showPrompt && !state.isLoggingIn) return;
    state = const ReauthState.idle();
    _outcomes.add(false);
  }

  /// User tapped "Log in" — hide the dialog so the router/bottom sheet can
  /// present the login UI.
  void beginLogin() {
    if (!state.showPrompt || state.isLoggingIn) return;
    state = state.copyWith(showPrompt: false, isLoggingIn: true);
  }

  /// Login completed successfully. Emits `true`.
  void onLoginSucceeded() {
    if (!state.isLoggingIn && !state.showPrompt) return;
    state = const ReauthState.idle();
    _outcomes.add(true);
  }

  /// Login sheet was torn down without success — re-surface the prompt so
  /// the user can choose again instead of being silently stranded. Does not
  /// emit a terminal outcome.
  void onLoginAbandoned() {
    if (!state.isLoggingIn) return;
    state = const ReauthState(showPrompt: true, isLoggingIn: false);
  }
}
