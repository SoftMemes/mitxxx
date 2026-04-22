import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/advertising_id_provider.dart';
import 'package:omnilect/core/analytics/analytics_preferences.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/router/app_router.dart';
import 'package:omnilect/core/storage/shared_preferences_provider.dart';
import 'package:omnilect/core/theme/app_theme.dart';
import 'package:omnilect/features/auth/widgets/reauth_gate.dart';
import 'package:omnilect/features/courses/providers/legacy_selection_migration.dart';
import 'package:omnilect/features/player/background/audio_service_provider.dart';
import 'package:omnilect/features/player/background/audio_session_controller.dart';
import 'package:omnilect/features/player/background/lecture_audio_handler.dart';
import 'package:omnilect/features/sync/manager/sync_lifecycle_observer.dart';
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
      // Integration tests override these from inside the test body
      // (see integration_test/support/steps.dart::suppressFrameworkErrors)
      // so they run last and win over these production defaults.
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      final dioClient = await buildDioClient();
      final prefs = await SharedPreferences.getInstance();

      // Initialise background audio plumbing. `AudioService.init` must be
      // called exactly once before `runApp`. The returned handler is later
      // attached to a live `LecturePlaybackController` by `LecturePlayer`
      // whenever a lecture is opened — see `lecture_player_provider.dart`.
      final lectureAudioHandler = await AudioService.init(
        builder: LectureAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.omnilect.lecture_audio',
          androidNotificationChannelName: 'Lecture playback',
          androidNotificationOngoing: true,
          preloadArtwork: true,
          fastForwardInterval: LectureAudioHandler.fastForwardInterval,
        ),
      );
      final audioSession = await AudioSession.instance;
      await audioSession.configure(const AudioSessionConfiguration.speech());
      // Retain the session/handler bridge for the process lifetime.
      AudioSessionController.forSession(
        session: audioSession,
        handler: lectureAudioHandler,
      );

      // TEMP diagnostic: log every Flutter lifecycle transition so we can
      // correlate pause() calls in the player logs with iOS background events.
      final lifecycleLog = Logger('app.lifecycle');
      WidgetsBinding.instance.addObserver(_LifecycleLogger(lifecycleLog));

      runApp(
        ProviderScope(
          overrides: [
            dioClientProvider.overrideWithValue(dioClient),
            sharedPreferencesProvider.overrideWithValue(prefs),
            lectureAudioHandlerProvider
                .overrideWithValue(lectureAudioHandler),
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

class _LifecycleLogger with WidgetsBindingObserver {
  _LifecycleLogger(this._log);
  final Logger _log;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log.info('state=$state');
  }
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
    // Run the legacy-user selection migration eagerly so the router sees
    // a populated selected_lists on first redirect evaluation. Also hold
    // the sync manager open across the app's lifetime: it auto-spawns the
    // isolate when auth becomes non-null and tears it down on sign-out.
    ref
      ..read(legacySelectionMigrationProvider)
      ..read(syncLifecycleObserverProvider);
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
      builder: (context, child) =>
          ReauthGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
