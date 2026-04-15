// Firebase options for the dev flavor (app.omnilect.dev).
//
// PLACEHOLDER — these values will not work until you register the dev apps in Firebase:
//   firebase apps:create ANDROID app.omnilect.dev --project mitxxx-f8b17
//   firebase apps:create IOS app.omnilect.dev --project mitxxx-f8b17
//
// After registration, run `flutterfire configure` or update this file manually.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DevFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web platform is not configured for Firebase.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DevFirebaseOptions are not supported for this platform.',
        );
    }
  }

  // TODO: Replace with real values after running:
  //   firebase apps:create ANDROID app.omnilect.dev --project mitxxx-f8b17
  //   firebase apps:sdkconfig ANDROID <new-app-id>
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: '478154015759',
    projectId: 'mitxxx-f8b17',
    storageBucket: 'mitxxx-f8b17.firebasestorage.app',
  );

  // TODO: Replace with real values after running:
  //   firebase apps:create IOS app.omnilect.dev --project mitxxx-f8b17
  //   firebase apps:sdkconfig IOS <new-app-id>
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: '478154015759',
    projectId: 'mitxxx-f8b17',
    storageBucket: 'mitxxx-f8b17.firebasestorage.app',
    iosBundleId: 'app.omnilect.dev',
  );
}
