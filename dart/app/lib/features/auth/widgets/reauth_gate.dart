import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/router/app_router.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';

/// Listens to [reauthControllerProvider] and surfaces a dismissible "session
/// expired" modal whenever the sync layer flags a stale session. The modal
/// is hidden while the user is mid-login (so the LoginScreen has the
/// foreground) and re-opens automatically if they back out.
class ReauthGate extends ConsumerStatefulWidget {
  const ReauthGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ReauthGate> createState() => _ReauthGateState();
}

enum _ReauthAction { dismiss, login }

class _ReauthGateState extends ConsumerState<ReauthGate> {
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<ReauthRequest?>(reauthControllerProvider, (prev, next) {
      final shouldPrompt = next != null && !next.isLoggingIn;
      if (shouldPrompt && !_dialogOpen) _showPrompt();
    });
    return widget.child;
  }

  Future<void> _showPrompt() async {
    _dialogOpen = true;
    // ReauthGate is installed in MaterialApp.router's `builder`, which means
    // its `context` is an ANCESTOR of the router's Navigator AND of the
    // GoRouter InheritedWidget. `showDialog(context: context)` and
    // `GoRouter.of(context)` both fail here. Use the shared root-navigator
    // key (set on GoRouter in app_router.dart) — its currentContext is a
    // descendant of the Navigator.
    final navCtx = rootNavigatorKey.currentContext;
    if (navCtx == null) {
      _dialogOpen = false;
      return;
    }
    final action = await showDialog<_ReauthAction>(
      context: navCtx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Session expired'),
        content: const Text(
          'Your MIT sign-in has expired. Log back in to sync new course '
          'content — downloaded content is still available offline.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ReauthAction.dismiss),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(_ReauthAction.login),
            icon: const Icon(Icons.login),
            label: const Text('Log in'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted) return;

    final notifier = ref.read(reauthControllerProvider.notifier);
    switch (action) {
      case _ReauthAction.login:
        notifier.beginLogin();
        // Same context trap as above — go through the router's navigator
        // context, which IS a descendant of the GoRouter InheritedWidget.
        final routeCtx = rootNavigatorKey.currentContext;
        if (routeCtx != null) {
          // routeCtx is freshly obtained from the root navigator key after
          // the dialog closed — it is NOT a stored pre-await context.
          // ignore: use_build_context_synchronously
          unawaited(GoRouter.of(routeCtx).push('/login'));
        }
      case _ReauthAction.dismiss:
      case null:
        notifier.dismiss();
    }
  }
}
