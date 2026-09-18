import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties for release signing
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}
val buildingRelease = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}

android {
    namespace = "cn.gzus.pro"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "cn.gzus.pro"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    buildFeatures {
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
            if (buildingRelease) {
                excludes += setOf(
                "lib/x86_64/*.so",
                "**/x86_64/*.so"
                )
            }
        }
    }
}

dependencies {
    // Android 16 的 Live Updates API（请求推广常驻通知）由 Core 1.17 提供兼容实现。
    implementation("androidx.core:core:1.17.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("commons-net:commons-net:3.11.1")
    implementation("com.tencent.shiply:upgrade:2.2.2")
    implementation("com.tencent.shiply:upgrade-ui:2.2.2")
    implementation("com.tencent:mmkv:1.0.22")
    implementation("com.tencent.shiply:rdelivery:1.3.38-RC02")
    implementation("com.tencent.shiply:reshub-sdk:1.8.22-RC04")
    implementation("com.tencent.shiply:reshub-net:1.8.22-RC04")
    implementation("com.tencent.shiply:reshub-report:1.8.22-RC04")
    implementation("com.tencent.shiply:reshub-patch-sdk:1.8.22-RC04")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20180813")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
