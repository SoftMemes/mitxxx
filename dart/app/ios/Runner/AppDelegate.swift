import Flutter
import GoogleCast
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Initialise Google Cast with the Default Media Receiver.
    let options = GCKCastOptions(
      discoveryCriteria: GCKDiscoveryCriteria(
        applicationID: kGCKDefaultMediaReceiverApplicationID
      )
    )
    GCKCastContext.setSharedInstanceWith(options)

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
