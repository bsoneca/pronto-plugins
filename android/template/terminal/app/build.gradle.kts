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
        // The Play and sideload builds say their own version: -PprontoVersionCode=<n> -PprontoVersionName=<x.y.z>
        // (a property, never an edit of this file, so a refresh of the host never reverts them).
        versionCode = (project.findProperty("prontoVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("prontoVersionName") as String?) ?: "0.1.0"
        // Whether the build answers the scenario driver and takes the base, actor and path extras (MainActivity.kt):
        // the debug build does by being debuggable, the rehearsal build says so here, a release never.
        resValue("string", "pronto_driver", "off")
        val base = (project.findProperty("prontoBase") as String?) ?: "__BASE__"
        resValue("string", "pronto_base", base)
        // android.json's "unlock": "biometric" opens the sealed storage with one prompt (Unlock.kt).
        resValue("string", "pronto_unlock", "__UNLOCK__")
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
        // A stylesheet that @imports another is shipped with the import inlined (bundle.ts): its copy is an asset of
        // the build type, which outranks main, whose ../../shell holds the original (a duplicate inside main is refused).
        getByName("debug") {
            res.srcDirs("build/generated/debug-res")
            assets.srcDirs("build/generated/terminal-css")
        }
        getByName("release") {
            assets.srcDirs("build/generated/terminal-css")
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
        // The rehearsal build (PRONTO-488): the release build's code, its minification and its other settings, signed with the
        // debug key, with the scenario driver and the base, actor and path extras on. Scenarios run on it, so what they check is the
        // release's code; the build signed with the release key never answers a driver (the driver's session answer carries
        // the session token). It trusts the machine's local roots as the debug build does (src/debug's network config, which
        // bundle.ts writes): without them it could not reach the local stack the scenarios run against.
        create("rehearsal") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
            resValue("string", "pronto_driver", "on")
        }
    }

    // The rehearsal build runs the debug build's driver and local-stack trust (the same files), over the release's code
    // (its sourceSet exists once the build type does).
    sourceSets {
        getByName("rehearsal") {
            kotlin.directories.add("src/debug/kotlin")
            res.srcDirs("build/generated/debug-res")
            assets.srcDirs("build/generated/terminal-css")
            manifest.srcFile("src/debug/AndroidManifest.xml")
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
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.yandex.div:div:33.6.0")
    implementation("com.yandex.div:div-core:33.6.0")
    implementation("com.yandex.div:glide:33.6.0")
    testImplementation("junit:junit:4.13.2")
    // The real org.json: the platform's is a stub in a JVM test (AskTest reads and writes JSON).
    testImplementation("org.json:json:20250517")
    // A release build's passkeys (src/release/Passkeys.kt); before Android 14, through Play services.
    releaseImplementation("androidx.credentials:credentials:1.5.0")
    releaseImplementation("androidx.credentials:credentials-play-services-auth:1.5.0")
}
