import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val orbitTestEdition = System.getenv("ORBIT_TEST_EDITION") == "true"
val orbitAdsTestApk = System.getenv("ORBIT_ADS_TEST_APK") == "true"
val playGamesProjectId = providers.gradleProperty("orbitPlayGamesProjectId")
    .getOrElse("791498391332")
require(playGamesProjectId.isEmpty() || playGamesProjectId.all { it in '0'..'9' }) {
    "orbitPlayGamesProjectId must be the numeric Play Games Services project ID"
}
val uploadPropertiesFile = rootProject.file("key.properties")
val uploadProperties = Properties().apply {
    if (uploadPropertiesFile.isFile) {
        uploadPropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "dev.orbitarrow.orbit_arrow_overdrive"
    buildFeatures { resValues = true }
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        val gamesId = if (orbitTestEdition || orbitAdsTestApk) "" else playGamesProjectId
        resValue("string", "game_services_project_id", gamesId)
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (orbitTestEdition) {
            "dev.orbitarrow.orbit_arrow_overdrive.test"
        } else {
            "dev.orbitarrow.orbit_arrow_overdrive"
        }
        if (orbitAdsTestApk) applicationIdSuffix = ".adstest"
        manifestPlaceholders["orbitAppLabel"] = when {
            orbitAdsTestApk -> "Orbit Arrow Ads Test"
            orbitTestEdition -> "Orbit Arrow Test"
            else -> "Orbit Arrow"
        }
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
        if (!orbitTestEdition && uploadPropertiesFile.isFile) {
            create("upload") {
                storeFile = rootProject.file(uploadProperties.getProperty("storeFile"))
                storePassword = uploadProperties.getProperty("storePassword")
                keyAlias = uploadProperties.getProperty("keyAlias")
                keyPassword = uploadProperties.getProperty("keyPassword")
            }
        }
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
            proguardFiles("proguard-rules.pro")
            if (!orbitTestEdition && uploadPropertiesFile.isFile) {
                signingConfig = signingConfigs.getByName("upload")
            } else if (orbitTestKeystore != null) {
                signingConfig = signingConfigs.getByName("orbitTest")
            }
        }
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-games-v2:22.1.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

