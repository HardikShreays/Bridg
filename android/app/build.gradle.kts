import com.google.protobuf.gradle.proto
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.protobuf")
}

// Signing: reads android/keystore.properties (gitignored). Absent -> release stays unsigned.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}

android {
    namespace = "com.bridg"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bridg"
        minSdk = 26
        targetSdk = 34
        versionCode = 2
        versionName = "0.2.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keystorePropsFile.exists()) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (keystorePropsFile.exists()) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }

    sourceSets {
        getByName("main") {
            // Build straight from the shared schema. This module used to keep
            // its own copy under src/main/proto, so the two halves of the app
            // could silently drift apart — an edit to proto/bridg.proto reached
            // the Mac and not the phone.
            proto { srcDir("../../proto") }
        }
    }
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.26.1"
    }
    // No separate codegen plugins needed — protoc generates Java lite + Kotlin extension
    // via the builtins below. The "kotlin" option for the java builtin generates
    // Kotlin data-class extensions for each message.
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java") {
                    option("lite")
                }
            }
        }
    }
}

dependencies {
    // Protobuf runtime (lite)
    implementation("com.google.protobuf:protobuf-kotlin-lite:4.26.1")

    // Crypto (lazysodium-android - Kotlin libsodium wrapper, available on Maven Central)
    implementation("com.goterl:lazysodium-android:5.0.2@aar")
    // lazysodium reaches libsodium through JNA. Its POM pulls the plain desktop
    // JAR, which carries no libjnidispatch.so for Android, so every call into
    // libsodium threw UnsatisfiedLinkError and the app died on launch. The @aar
    // build is the one that ships the Android native dispatch libraries.
    implementation("net.java.dev.jna:jna:5.13.0@aar")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // CameraX
    implementation("androidx.camera:camera-core:1.3.3")
    implementation("androidx.camera:camera-camera2:1.3.3")
    implementation("androidx.camera:camera-lifecycle:1.3.3")
    implementation("androidx.camera:camera-view:1.3.3")

    // ML Kit barcode scanning
    implementation("com.google.mlkit:barcode-scanning:17.2.0")

    // QR generation
    implementation("com.github.alexzhirkevich:custom-qr-generator:1.6.2")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-service:2.7.0")

    // Core
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")

    // Encrypted preferences
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
}
