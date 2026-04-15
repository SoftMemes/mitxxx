import 'dart:async';

import 'package:emajtee/core/analytics/advertising_id_provider.dart';
import 'package:emajtee/core/analytics/analytics_preferences.dart';
import 'package:emajtee/core/analytics/analytics_service.dart';
import 'package:emajtee/core/logging.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/router/app_router.dart';
import 'package:emajtee/core/theme/app_theme.dart';
import 'package:emajtee/firebase_options.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  unawaited(runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      initLogging();

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      // Only report crashes from release builds; debug crashes go to console.
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(!kDebugMode);
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      final dioClient = await buildDioClient();
      runApp(
        ProviderScope(
          overrides: [dioClientProvider.overrideWithValue(dioClient)],
          child: const EmajteeApp(),
        ),
      );
    },
    (error, stack) => FirebaseCrashlytics.instance.recordError(
      error,
      stack,
      fatal: true,
    ),
  ));
}

class EmajteeApp extends ConsumerStatefulWidget {
  const EmajteeApp({super.key});

  @override
  ConsumerState<EmajteeApp> createState() => _EmajteeAppState();
}

class _EmajteeAppState extends ConsumerState<EmajteeApp> {
  @override
  void initState() {
    super.initState();
    _initAnalytics();
  }

  Future<void> _initAnalytics() async {
    // Set user ID from device advertising ID (IDFA/GAID).
    // Runs in background; analytics events that fire before this resolves
    // will be attributed to Firebase's own anonymous instance ID.
    final adId = await ref.read(advertisingIdProvider.future);
    if (adId != null) {
      await FirebaseAnalytics.instance.setUserId(id: adId);
    }

    if (!mounted) return;
    final isFirstOpen = await AnalyticsPreferences.consumeFirstOpen();
    if (!mounted) return;
    await ref.read(analyticsServiceProvider).logAppOpen(isFirstOpen: isFirstOpen);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'MITxxx',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
