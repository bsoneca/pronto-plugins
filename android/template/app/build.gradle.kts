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
    }

    // The program's terminal files are the app's assets: the phone runs the
    // handler pronto checks and starts from the seed pronto emits.
    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets", "../../shell")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
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
    implementation("androidx.biometric:biometric:1.1.0")
    testImplementation("junit:junit:4.13.2")
    // The real org.json: the platform's is a stub in a JVM test (AskTest reads and writes JSON).
    testImplementation("org.json:json:20250517")
}
