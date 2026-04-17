import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/analytics/advertising_id_provider.dart';
import 'package:omnilect/core/analytics/analytics_preferences.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/router/app_router.dart';
import 'package:omnilect/core/storage/shared_preferences_provider.dart';
import 'package:omnilect/core/theme/app_theme.dart';
import 'package:omnilect/firebase_options_dev.dart';
import 'package:omnilect/firebase_options_prod.dart';
import 'package:omnilect/flavor_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> bootstrap() async {
  unawaited(runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      initLogging();

      final firebaseOptions = FlavorConfig.isDev
          ? DevFirebaseOptions.currentPlatform
          : ProdFirebaseOptions.currentPlatform;

      await Firebase.initializeApp(options: firebaseOptions);
      // Only report crashes from release builds; debug crashes go to console.
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(!kDebugMode);
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      final dioClient = await buildDioClient();
      final prefs = await SharedPreferences.getInstance();
      runApp(
        ProviderScope(
          overrides: [
            dioClientProvider.overrideWithValue(dioClient),
            sharedPreferencesProvider.overrideWithValue(prefs),
          ],
          child: const OmnilectApp(),
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

class OmnilectApp extends ConsumerStatefulWidget {
  const OmnilectApp({super.key});

  @override
  ConsumerState<OmnilectApp> createState() => _OmnilectAppState();
}

class _OmnilectAppState extends ConsumerState<OmnilectApp> {
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
