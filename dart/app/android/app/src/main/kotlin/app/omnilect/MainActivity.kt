package app.omnilect

import com.ryanheise.audioservice.AudioServiceActivity

// `audio_service` requires the host Activity to extend AudioServiceActivity
// so the plugin can bind its MediaSession service to the Flutter engine.
// Using the default FlutterActivity throws "The Activity class declared in
// your AndroidManifest.xml is wrong or has not provided the correct
// FlutterEngine" on AudioService.init().
class MainActivity : AudioServiceActivity()
