plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.jxcode.android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.jxcode.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        // arm64 only. 32-bit does not have the address space for a GGUF
        // runtime in-process, and every device we target is aarch64.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    // Native libs are produced by scripts/build-ndk.sh (NDK clang directly,
    // not externalNativeBuild) and dropped into src/main/jniLibs/arm64-v8a.
    // Legacy packaging keeps them extracted uncompressed, which is what makes
    // a bundled executable (node) runnable from the app's native lib dir.
    packaging {
        jniLibs { useLegacyPackaging = true }
        resources { excludes += setOf("META-INF/*.kotlin_module") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }

    // A release APK that is not signed cannot be installed on any device, and
    // AGP leaves it unsigned when no signingConfig is set. Use a real keystore
    // when one sits next to the project (credentials come from
    // ~/.gradle/gradle.properties, never from here); otherwise sign with the
    // debug key so `./build.sh release` always yields something installable.
    val releaseKeystore = rootProject.file("keystore.jks")
    signingConfigs {
        if (releaseKeystore.exists()) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = (project.findProperty("JXCODE_STORE_PASSWORD") as String?) ?: "jxcode"
                keyAlias = (project.findProperty("JXCODE_KEY_ALIAS") as String?) ?: "jxcode"
                keyPassword = (project.findProperty("JXCODE_KEY_PASSWORD") as String?) ?: "jxcode"
            }
        }
    }

    buildTypes {
        debug { isMinifyEnabled = false }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = if (releaseKeystore.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // The GGUF header reader is pure JVM code — no Android API in it — so it is
    // tested on the host, against fixtures the test writes itself, rather than
    // on a device against a multi-gigabyte model.
    testImplementation("junit:junit:4.13.2")
}
