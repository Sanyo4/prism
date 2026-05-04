plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.prism.mobile"
    compileSdk = flutter.compileSdkVersion
    // Pinned to the NDK used to compile the 16 KB-page-aligned vec0.so prebuilts
    // (slice-10b). NDK r27+ is required for lld's -Wl,-z,max-page-size=16384
    // support; r28 is used here so the toolchain matches the committed binaries.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.prism.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // Android 15+ with 16 KB page kernels (Pixel 9 series, Tensor G4+)
            // requires native libs to be uncompressed in the APK/AAB so the OS
            // can mmap them directly. Compressed libs cannot be page-aligned at
            // load time, causing dlopen failures even on correctly-aligned .so
            // files. This setting has no effect on older devices.
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Slice-9 needed: ffmpeg_kit_flutter_new's AAR ships no
            // consumer-proguard-rules; Flutter's default R8 pass strips
            // its JNI-bound methods (e.g. AbiDetect.getNativeCpuAbi),
            // making JNI_OnLoad's RegisterNatives fail at app launch
            // and crashing the process before Flutter starts. The keep
            // rules in proguard-rules.pro fence off com.antonkarpenko.*
            // so R8 leaves the JNI-visible surface alone.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
