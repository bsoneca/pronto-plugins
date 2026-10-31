plugins {
    id("com.android.application")
}

android {
    namespace = "dev.pronto.hello_android"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.pronto.hello_android"
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
}
