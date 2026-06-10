package dev.prism.mobile

import com.ryanheise.audioservice.AudioServiceActivity

// We extend AudioServiceActivity (a drop-in FlutterActivity subclass
// from the `audio_service` plugin) so that MediaBrowser clients —
// the Android lockscreen, Bluetooth carkits, Wear OS — can bind back
// into our foreground service when the Flutter engine is tearing down
// or not yet attached. The plain FlutterActivity swap would work for
// the happy path but drops those bindings.
class MainActivity : AudioServiceActivity()
