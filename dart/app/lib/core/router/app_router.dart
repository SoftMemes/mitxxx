// ignore_for_file: uri_has_not_been_generated
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/screens/login_screen.dart';
import 'package:omnilect/features/courses/providers/selected_lists_provider.dart';
import 'package:omnilect/features/courses/screens/course_outline_screen.dart';
import 'package:omnilect/features/courses/screens/home_screen.dart';
import 'package:omnilect/features/courses/screens/lecture_screen.dart';
import 'package:omnilect/features/courses/screens/ocw_lecture_screen.dart';
import 'package:omnilect/features/onboarding/providers/onboarding_provider.dart';
import 'package:omnilect/features/onboarding/screens/list_selection_screen.dart';
import 'package:omnilect/features/onboarding/screens/onboarding_screen.dart';
import 'package:omnilect/features/settings/screens/about_screen.dart';
import 'package:omnilect/features/settings/screens/courses_screen.dart';
import 'package:omnilect/features/settings/screens/data_usage_screen.dart';
import 'package:omnilect/features/settings/screens/preferences_screen.dart';
import 'package:omnilect/features/settings/screens/settings_screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  // Notifies GoRouter whenever auth, onboarding, or reauth state changes so
  // redirects are re-evaluated.
  final notifier = ValueNotifier<int>(0);
  ref
    ..listen<AsyncValue<dynamic>>(authProvider, (_, _) => notifier.value++)
    ..listen<bool>(onboardingAcknowledgedProvider, (_, _) => notifier.value++)
    ..listen<AsyncValue<bool>>(
      hasSelectedListsProvider,
      (_, _) => notifier.value++,
    )
    ..listen<ReauthRequest?>(
      reauthControllerProvider,
      (_, _) => notifier.value++,
    )
    ..onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    observers: [ref.read(analyticsServiceProvider).observer],
    redirect: (context, state) {
      final isAcknowledged = ref.read(onboardingAcknowledgedProvider);
      final location = state.matchedLocation;
      final isOnboardingRoute = location == '/onboarding';
      final isListSelectionRoute = location == '/onboarding/list-selection';

      // Onboarding must be acknowledged before anything else is accessible.
      if (!isAcknowledged && !isOnboardingRoute) return '/onboarding';
      if (!isAcknowledged && isOnboardingRoute) return null;
      // Acknowledged and still on /onboarding — move them forward.
      if (isAcknowledged && isOnboardingRoute) return '/home';

      final authState = ref.read(authProvider);
      final isLoading = authState.isLoading;
      final isAuthenticated = authState.value != null;
      final isLoginRoute = location == '/login';

      // While checking auth on startup, stay put.
      if (isLoading) return null;

      // Authenticated users who haven't picked any sync lists yet must go
      // through the list-selection step before reaching the home screen.
      // Wait for the selection stream's first emission so we don't briefly
      // flash the wizard on existing users while the legacy migration runs.
      final hasSelectionAsync = ref.read(hasSelectedListsProvider);
      if (isAuthenticated && hasSelectionAsync.isLoading) return null;
      final hasSelection = hasSelectionAsync.asData?.value ?? false;
      if (isAuthenticated && !hasSelection && !isListSelectionRoute) {
        return '/onboarding/list-selection';
      }
      if (isAuthenticated && hasSelection && isListSelectionRoute) {
        return '/home';
      }
      // Unauthenticated users can't use the list-selection step.
      if (!isAuthenticated && isListSelectionRoute) return '/login';

      // Logged-out users can browse /home, /settings, /onboarding, /login.
      // Course content routes require auth (they need cached data from a sync).
      final requiresAuth = location.startsWith('/course/');
      if (!isAuthenticated && requiresAuth) return '/login';
      // Authenticated users normally can't re-enter /login, but when reauth
      // is active (stale session) we explicitly want to allow it so the user
      // can refresh their cookies without being wiped.
      final reauthActive = ref.read(reauthControllerProvider) != null;
      if (isAuthenticated && isLoginRoute && !reauthActive) return '/home';
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
        routes: [
          GoRoute(
            path: 'list-selection',
            builder: (context, state) => const ListSelectionScreen(),
          ),
        ],
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
          GoRoute(
            path: 'courses',
            builder: (context, state) => const CoursesScreen(),
          ),
          GoRoute(
            path: 'preferences',
            builder: (context, state) => const PreferencesScreen(),
          ),
          GoRoute(
            path: 'data-usage',
            builder: (context, state) => const DataUsageScreen(),
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
      GoRoute(
        path: '/course/:courseId/ocw-lecture/:lectureSlug',
        builder: (context, state) => OcwLectureScreen(
          courseId: state.pathParameters['courseId']!,
          lectureSlug: state.pathParameters['lectureSlug']!,
        ),
      ),
    ],
  );
}
