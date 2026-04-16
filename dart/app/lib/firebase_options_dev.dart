// Firebase options for the dev flavor (app.omnilect.dev).
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

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBunL_ryTPpMSb7Wx8BjE8kf8XO1muth6M',
    appId: '1:478154015759:android:5ad0b644fb794f05d54f7a',
    messagingSenderId: '478154015759',
    projectId: 'mitxxx-f8b17',
    storageBucket: 'mitxxx-f8b17.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDOwXcBvJ8hKte5HddlTJmumUlHnuOhMFU',
    appId: '1:478154015759:ios:b283065f575890d5d54f7a',
    messagingSenderId: '478154015759',
    projectId: 'mitxxx-f8b17',
    storageBucket: 'mitxxx-f8b17.firebasestorage.app',
    iosBundleId: 'app.omnilect.dev',
  );
}
