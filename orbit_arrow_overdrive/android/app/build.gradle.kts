plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val orbitTestEdition = System.getenv("ORBIT_TEST_EDITION") == "true"

android {
    namespace = "dev.orbitarrow.orbit_arrow_overdrive"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (orbitTestEdition) {
            "dev.orbitarrow.orbit_arrow_overdrive.test"
        } else {
            "dev.orbitarrow.orbit_arrow_overdrive"
        }
        manifestPlaceholders["orbitAppLabel"] =
            if (orbitTestEdition) "Orbit Arrow Test" else "Orbit Arrow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Optional local test signing. Production builds require your release key.
    val orbitTestKeystore = System.getenv("ORBIT_TEST_KEYSTORE")
    signingConfigs {
        if (orbitTestKeystore != null) {
            create("orbitTest") {
                storeFile = file(orbitTestKeystore)
                storePassword = "android"
                keyAlias = "orbit-test"
                keyPassword = "android"
            }
        }
    }
    if (orbitTestKeystore != null) {
        lint { checkReleaseBuilds = false }
    }
    buildTypes {
        release {
            if (orbitTestKeystore != null) {
                signingConfig = signingConfigs.getByName("orbitTest")
            }
            // TODO: Add your own signing config for the release build.
            // Configure your release keystore here before distribution.
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

