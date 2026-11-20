rootProject.name = "hello-android"

pluginManagement {
    repositories {
        google()
        mavenCentral()
        // Google's mirror of Maven Central: on some CI machines Central answered 404 for artifacts it holds
        // (org.jetbrains:annotations:13.0, kotlin-stdlib), failing android-terminal on 2026-11-19; Gradle asks the next
        // repository on a miss, so this one answers then.
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        // Google's mirror of Maven Central: on some CI machines Central answered 404 for artifacts it holds
        // (org.jetbrains:annotations:13.0, kotlin-stdlib), failing android-terminal on 2026-11-19; Gradle asks the next
        // repository on a miss, so this one answers then.
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
    }
}

include(":app")
