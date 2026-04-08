import 'package:emajtee/features/auth/screens/login_screen.dart';
import 'package:emajtee/features/courses/screens/home_screen.dart';
import 'package:emajtee/features/settings/screens/settings_screen.dart';
import 'package:go_router/go_router.dart';

// Auth state is a simple placeholder until the auth feature is implemented.
// The router redirect will send unauthenticated users to /login.
bool _isAuthenticated = false;

final appRouter = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    final isLoginRoute = state.matchedLocation == '/login';
    if (!_isAuthenticated && !isLoginRoute) return '/login';
    if (_isAuthenticated && isLoginRoute) return '/home';
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      redirect: (context, state) => _isAuthenticated ? '/home' : '/login',
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
  ],
);
