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

// Holds the session/handler bridge for the process lifetime. Assigned once
// from `bootstrap()` and deliberately never read again — its purpose is to
// keep the stream subscriptions in `AudioSessionController` reachable.
// ignore: unused_element
late final AudioSessionController _audioSessionController;

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
          preloadArtwork: true,
          fastForwardInterval: LectureAudioHandler.fastForwardInterval,
          // Keep the foreground service alive across transient pauses
          // (buffering underruns, segment boundaries). With the default
          // (true), each false→true flip tries to restartForegroundService
          // from the background, which Android 12+ rejects with
          // ForegroundServiceStartNotAllowedException — killing playback
          // a few seconds after backgrounding. A foreground-service
          // notification is inherently ongoing, so we drop
          // androidNotificationOngoing (audio_service's assertion
          // requires those to match up anyway).
          androidStopForegroundOnPause: false,
        ),
      );
      final audioSession = await AudioSession.instance;
      await audioSession.configure(const AudioSessionConfiguration.speech());
      // Retain the session/handler bridge for the process lifetime; the
      // underlying stream subscriptions are kept alive by this reference.
      _audioSessionController = AudioSessionController.forSession(
        session: audioSession,
        handler: lectureAudioHandler,
      );

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

class OmnilectApp extends ConsumerStatefulWidget {
  const OmnilectApp({super.key});

  @override
  ConsumerState<OmnilectApp> createState() => _OmnilectAppState();
}

class _OmnilectAppState extends ConsumerState<OmnilectApp> {
  AppLifecycleListener? _lifecycleListener;

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

    // Log lifecycle transitions so background-playback issues can be
    // correlated against state changes (e.g. paused → audio cuts).
    final log = Logger('app.lifecycle');
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) => log.info('state → $state'),
      onPause: () => log.info('onPause'),
      onResume: () => log.info('onResume'),
      onHide: () => log.info('onHide'),
      onShow: () => log.info('onShow'),
      onInactive: () => log.info('onInactive'),
      onRestart: () => log.info('onRestart'),
      onDetach: () => log.info('onDetach'),
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
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
