// ignore_for_file: uri_has_not_been_generated
import 'package:emajtee/core/analytics/analytics_service.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:emajtee/features/auth/screens/login_screen.dart';
import 'package:emajtee/features/courses/screens/course_outline_screen.dart';
import 'package:emajtee/features/courses/screens/home_screen.dart';
import 'package:emajtee/features/courses/screens/lecture_screen.dart';
import 'package:emajtee/features/onboarding/providers/onboarding_provider.dart';
import 'package:emajtee/features/onboarding/screens/onboarding_screen.dart';
import 'package:emajtee/features/settings/screens/about_screen.dart';
import 'package:emajtee/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  // Notifies GoRouter whenever auth or onboarding state changes so redirects
  // are re-evaluated.
  final notifier = ValueNotifier<int>(0);
  ref
    ..listen<AsyncValue<dynamic>>(authProvider, (_, _) => notifier.value++)
    ..listen<bool>(onboardingAcknowledgedProvider, (_, _) => notifier.value++)
    ..onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    observers: [ref.read(analyticsServiceProvider).observer],
    redirect: (context, state) {
      final isAcknowledged = ref.read(onboardingAcknowledgedProvider);
      final isOnboardingRoute = state.matchedLocation == '/onboarding';

      // Onboarding must be acknowledged before anything else is accessible.
      if (!isAcknowledged && !isOnboardingRoute) return '/onboarding';
      // If the user somehow lands on /onboarding but is already acknowledged,
      // fall through to the auth redirect which will send them to /login or /home.
      if (!isAcknowledged && isOnboardingRoute) return null;

      final authState = ref.read(authProvider);
      final isLoading = authState.isLoading;
      final isAuthenticated = authState.value != null;
      final isLoginRoute = state.matchedLocation == '/login';

      // While checking auth on startup, stay put.
      if (isLoading) return null;

      // Logged-out users can browse /home, /settings, /onboarding, /login.
      // Course content routes require auth (they need cached data from a sync).
      final location = state.matchedLocation;
      final requiresAuth = location.startsWith('/course/');
      if (!isAuthenticated && requiresAuth) return '/login';
      if (isAuthenticated && isLoginRoute) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) {
          final isAcknowledged = ref.read(onboardingAcknowledgedProvider);
          if (!isAcknowledged) return '/onboarding';
          return '/home';
        },
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'about',
            builder: (context, state) => const AboutScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/course/:courseId',
        builder: (context, state) => CourseOutlineScreen(
          courseId: state.pathParameters['courseId']!,
        ),
      ),
      GoRoute(
        path: '/course/:courseId/sequence/:sequenceId',
        builder: (context, state) => LectureScreen(
          courseId: state.pathParameters['courseId']!,
          sequenceId: state.pathParameters['sequenceId']!,
        ),
      ),
    ],
  );
}
