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

// A build whose app names a sealed-storage flag (res/values/sealed_flag.xml, written by the app's generate) holds that flag's value
// in res/raw/flags_snapshot.json (written by the same generate, from the CUE the flags are pushed from): the first launch with no
// answer and no cache reads it (Kv.kt). A build without it does not happen.
val checkFlagsSnapshot = tasks.register("checkFlagsSnapshot") {
    val named = file("src/main/res/values/sealed_flag.xml")
    val snapshot = file("src/main/res/raw/flags_snapshot.json")
    doLast {
        val flag = Regex("<string name=\"pronto_sealed_flag\">([^<]*)</string>").find(named.readText())?.groupValues?.get(1) ?: ""
        if (flag.isNotEmpty() && !Regex("\"" + Regex.escape(flag) + "\"\\s*:\\s*(true|false)").containsMatchIn(snapshot.readText())) {
            throw GradleException("res/raw/flags_snapshot.json has no value for the flag $flag: run ./saytw generate")
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(checkFlagsSnapshot) }
