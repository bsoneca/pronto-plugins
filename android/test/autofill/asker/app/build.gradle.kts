// A native app with one login form: what the autofill scenario fills from another app. It is
// debug-signed (assembleDebug), so its signing certificate is the debug key's.
plugins {
    id("com.android.application")
}

android {
    namespace = "dev.pronto.autofill.asker"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.pronto.autofill.asker"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
