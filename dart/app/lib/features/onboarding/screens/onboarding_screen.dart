import 'package:omnilect/core/analytics/analytics_preferences.dart';
import 'package:omnilect/features/onboarding/disclosure_content.dart';
import 'package:omnilect/features/onboarding/providers/onboarding_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Full-screen onboarding disclaimer shown to every user once, before login.
///
/// Back navigation is suppressed — the only way forward is tapping
/// "I understand".
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _busy = false;
  bool _analyticsOptIn = true;

  Future<void> _acknowledge() async {
    if (_busy) return;
    setState(() => _busy = true);
    if (!_analyticsOptIn) {
      await ref.read(analyticsPreferencesProvider.notifier).setOptedIn(false);
    }
    await ref.read(onboardingAcknowledgedProvider.notifier).acknowledge();
    // Router redirect picks up the state change and navigates to /login.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Scrollable content ──────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // App icon + name
                      Center(
                        child: Column(
                          children: [
                            Image.asset(
                              'assets/icons/app_icon.png',
                              width: 96,
                              height: 96,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'MITxxx',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 40),
                      Text(
                        'About this app',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Disclosure items
                      ...kDisclosureItems.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.circle,
                                  size: 7,
                                  color: cs.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.body,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Sticky bottom ────────────────────────────────────────────
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: cs.outlineVariant),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Analytics opt-out checkbox (default ticked)
                    GestureDetector(
                      onTap: _busy ? null : () => setState(() => _analyticsOptIn = !_analyticsOptIn),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _analyticsOptIn,
                            onChanged: _busy ? null : (v) => setState(() => _analyticsOptIn = v ?? true),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Share anonymous usage analytics to help improve MITxxx. '
                              'No course content, names, or emails are ever sent.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy ? null : _acknowledge,
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('I understand'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
