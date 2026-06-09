pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/google/maven2/") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/maven-central/") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/gradle-plugin/") }
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
}

include(":app")
