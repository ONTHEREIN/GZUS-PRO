allprojects {
    repositories {
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/google/maven2/") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/maven-central/") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/gradle-plugin/") }
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        maven { url = uri("https://maven.cnb.cool/tencent-tds/shiply-public/-/packages/") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    val proj = this
    proj.afterEvaluate {
        val androidExt = proj.extensions.findByName("android")
        if (androidExt != null) {
            try {
                val m1 = androidExt.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
                m1.invoke(androidExt, 36)
            } catch (_: NoSuchMethodException) {
                try {
                    val m2 = androidExt.javaClass.getMethod("setCompileSdk", Int::class.javaPrimitiveType)
                    m2.invoke(androidExt, 36)
                } catch (_: Exception) { }
            } catch (_: Exception) { }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
