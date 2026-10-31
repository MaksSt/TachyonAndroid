plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Device test runners remove their package after completion. Keep them isolated.
val diagnosticTarget = providers.gradleProperty("target").orNull.orEmpty().replace('\\', '/')
val diagnosticsBuild = providers.gradleProperty("tachyonDiagnostics").orNull == "true" ||
    diagnosticTarget.contains("flutter_test_listener") || diagnosticTarget.contains("integration_test/")
val supportedAbis = mapOf("android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
val requestedAbis = providers.gradleProperty("target-platform").orNull
    ?.split(',')?.mapNotNull { supportedAbis[it] } ?: supportedAbis.values.toList()
require(requestedAbis.isNotEmpty()) { "Only ARM64 and x86_64 Android targets are supported." }

android {
    namespace = "dev.tachyon.tachyon_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (diagnosticsBuild) "dev.tachyon.tachyon_client.checks" else "dev.tachyon.tachyon_client"
        manifestPlaceholders["appLabel"] = if (diagnosticsBuild) "Tachyon Checks" else "Tachyon Client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters += requestedAbis
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Только официальное ядро и пакетный мост должны остаться побайтово неизменными.
            keepDebugSymbols += listOf("**/libtachyon.so", "**/libhev-socks5-tunnel.so")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    implementation(files("../../.local/hev-socks5-tunnel.aar"))
}
