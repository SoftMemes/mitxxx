// ignore_for_file: uri_has_not_been_generated
import 'package:emajtee/core/analytics/analytics_service.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:emajtee/features/auth/screens/login_screen.dart';
import 'package:emajtee/features/courses/screens/course_outline_screen.dart';
import 'package:emajtee/features/courses/screens/home_screen.dart';
import 'package:emajtee/features/courses/screens/lecture_screen.dart';
import 'package:emajtee/features/settings/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  // A ValueNotifier used as GoRouter's refreshListenable.
  // Notifies GoRouter whenever auth state changes so redirects are re-evaluated.
  final notifier = ValueNotifier<int>(0);
  ref
    ..listen<AsyncValue<dynamic>>(authProvider, (_, _) => notifier.value++)
    ..onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    observers: [ref.read(analyticsServiceProvider).observer],
    redirect: (context, state) {
      final authState = ref.read(authProvider);
      final isLoading = authState.isLoading;
      final isAuthenticated = authState.value != null;
      final isLoginRoute = state.matchedLocation == '/login';

      // While checking auth on startup, stay put.
      if (isLoading) return null;

      if (!isAuthenticated && !isLoginRoute) return '/login';
      if (isAuthenticated && isLoginRoute) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) {
          final isAuthenticated =
              ref.read(authProvider).value != null;
          return isAuthenticated ? '/home' : '/login';
        },
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
