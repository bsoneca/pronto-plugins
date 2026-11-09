import java.net.URI

plugins {
    id("com.android.application")
}

android {
    namespace = "__APPLICATION_ID__"
    compileSdk = 36

    defaultConfig {
        applicationId = "__APPLICATION_ID__"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        val base = (project.findProperty("prontoBase") as String?) ?: "__BASE__"
        resValue("string", "pronto_base", base)
        // The app's links open it: an App Link of its own origin, verified by the Digital Asset
        // Links its door serves (assetlinks.json) for the certificate that signs the release.
        manifestPlaceholders["prontoHost"] = URI(base).host
    }

    buildFeatures { resValues = true }

    // The program's terminal files are the app's assets, beside the terminal
    // build@android bundled from the app's own omnishell.
    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets", "../../shell", "build/generated/terminal")
        }
        getByName("debug") {
            res.srcDirs("build/generated/debug-res")
        }
    }

    // A release is signed only where its key is at hand: PRONTO_ANDROID_KEYSTORE (a path),
    // PRONTO_ANDROID_KEYSTORE_PASSWORD and PRONTO_ANDROID_KEY_ALIAS (android/sign-release.sh sets them
    // from Secret Manager). Without them it stays unsigned, so ci and the gates need no secret.
    val keystorePath = System.getenv("PRONTO_ANDROID_KEYSTORE")
    val keystorePassword = System.getenv("PRONTO_ANDROID_KEYSTORE_PASSWORD")
    val releaseAlias = System.getenv("PRONTO_ANDROID_KEY_ALIAS")
    val signed = !keystorePath.isNullOrEmpty() && !keystorePassword.isNullOrEmpty() && !releaseAlias.isNullOrEmpty()
    if (signed) {
        signingConfigs {
            create("release") {
                storeFile = file(keystorePath!!)
                storePassword = keystorePassword
                keyAlias = releaseAlias
                keyPassword = keystorePassword
            }
        }
    }
    buildTypes {
        getByName("release") {
            if (signed) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("io.github.dokar3:quickjs-kt-android:1.0.14")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("com.yandex.div:div:33.6.0")
    implementation("com.yandex.div:div-core:33.6.0")
    implementation("com.yandex.div:glide:33.6.0")
    // A release build's passkeys (src/release/Passkeys.kt); before Android 14, through Play services.
    releaseImplementation("androidx.credentials:credentials:1.5.0")
    releaseImplementation("androidx.credentials:credentials-play-services-auth:1.5.0")
}
