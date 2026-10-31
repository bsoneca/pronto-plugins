package android

import "strings"

_t: #Host & {app: "emit"}

// Every rule answers @android alone, so the web verbs never run it.
platforms: [for verb in ["setup", "build", "test", "launch"] for _, r in _t.surface.rules[verb] if r.platform == "android" {verb}] & ["setup", "build", "test", "launch"]
launchInstalls: strings.Contains(_t.surface.rules.launch.android.cmds[1].do, "adb install -r android/app/build/outputs/apk/debug/app-debug.apk") & true
buildsWithMiseGradle: strings.Contains(_t.surface.rules.build.android.cmds[0].do, "run-mise exec -- gradle ") & true
launchStarts: strings.Contains(_t.surface.rules.launch.android.cmds[2].do, "am start -S -n dev.pronto.emit/.MainActivity") & true
misePins: strings.Contains(_t.files[".config/mise/conf.d/android.toml"].text, "gradle = \"9.6.0\"") & true
sayJsonRules: strings.Contains(_t.files[".say.json"].text, "\"platform\": \"android\"") & true

// The Kotlin sources land under the id's package path, filled with it.
_engine: _t.files["android/app/src/main/kotlin/dev/pronto/emit/HostEngine.kt"]
enginePackage: strings.HasPrefix(_engine.text, "package dev.pronto.emit\n") & true
appId: strings.Contains(_t.files["android/app/build.gradle.kts"].text, "applicationId = \"dev.pronto.emit\"") & true
noTokenLeft: [for p, f in _t.files if strings.Contains(f.text, "__APP") || strings.Contains(f.text, "__LABEL__") {p}] & []

// The screen and the autofill contract are the app's once written; everything
// else is regenerated.
seeded: [for p, f in _t.files if f.seed {p}] & ["android/app/src/main/assets/screen.js", "android/app/src/main/assets/autofill.json"]

// Tests land in the id's package beside the sources they test.
testPackage: strings.HasPrefix(_t.files["android/app/src/test/kotlin/dev/pronto/emit/FillTest.kt"].text, "package dev.pronto.emit\n") & true

// The autofill service is bound only by the system, and the vault never backs up.
_manifest: _t.files["android/app/src/main/AndroidManifest.xml"].text
fillBound: strings.Contains(_manifest, "android:permission=\"android.permission.BIND_AUTOFILL_SERVICE\"") & true
noBackup: strings.Contains(_manifest, "android:allowBackup=\"false\"") & true
labelled: strings.Contains((#Host & {app: "myvault", label: "MyVault"}).files["android/app/src/main/AndroidManifest.xml"].text, "android:label=\"MyVault\"") & true

// Android refuses a hyphen in an application id, and an app's name admits one.
idFromHyphen: (#Host & {app: "pass-vault"}).applicationId & "dev.pronto.pass_vault"
