import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
    final action = await showDialog<_ReauthAction>(
      context: context,
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
        unawaited(GoRouter.of(context).push('/login'));
      case _ReauthAction.dismiss:
      case null:
        notifier.dismiss();
    }
  }
}
