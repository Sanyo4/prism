# FFmpegKit (com.antonkarpenko.ffmpegkit) registers its native methods
# via JNI_OnLoad → RegisterNatives at <clinit> time, not from Java call
# sites. R8 / ProGuard cannot see references from native code, so the
# Flutter-default release build (which sets isMinifyEnabled = true)
# strips those Java method declarations from the dex as dead. At
# runtime, RegisterNatives then fails to bind, JNI_OnLoad returns 0,
# ART throws "Bad JNI version returned from JNI_OnLoad: 0", and
# MainActivity.onCreate crashes before Flutter renders a frame.
#
# The maintainer's AAR does not ship consumer-proguard-rules.pro, so we
# keep the surface area at the app level. Slice-9 added prism_cast →
# ffmpeg_kit_flutter_new for 128 kbps AAC transcoding to DLNA targets.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keepclassmembers class com.antonkarpenko.ffmpegkit.** { *; }
