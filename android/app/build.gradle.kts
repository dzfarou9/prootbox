plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.prootbox.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.prootbox.app"

        // API 26+: predictable per-app SELinux domain, adaptive icons, and
        // android.system.Os / posix_openpt available to the PTY helper.
        minSdk = 26
        targetSdk = 34

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The sandbox is ARM64 only. For another ABI, build matching proot
        // binaries with scripts/build-proot.sh and widen this list.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            /*
             * CRITICAL for PRoot on Android 10+.
             *
             * Guest binaries live in the app's private storage, which the
             * kernel refuses to execve() (the W^X rule). PRoot works around
             * that by executing its own syscall loader instead, and that
             * loader must live in ApplicationInfo.nativeLibraryDir — the only
             * directory whose files carry the executable apk_data_file SELinux
             * label. The installer only populates that directory when native
             * libraries are extracted (legacy packaging), hence this flag.
             *
             * Remove it and libproot.so / libproot-loader.so stay compressed
             * inside the APK, so nothing in the sandbox can be executed.
             */
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Signed with the debug key so `flutter run --release` works out of
            // the box. Add a keystore before distributing.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
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
