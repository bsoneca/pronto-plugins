// The Android host, the native terminal's first plugin (docs/native-terminal.md):
// a QuickJS+SES engine drawing DivKit, with the storage, Keystore and autofill
// bridges the doc names, the `device` tables sealed behind a biometric unlock.
// what an app that targets android needs beside the web terminal. Unmodified
// pronto writes .say.yaml and owns no .say.json, and sayt merges every .say.*
// file, so the host's rules reach an app through a .say.json it generates.
@extern(embed)

package android

import (
	"encoding/json"
	"strings"
)

_template: {
	"settings.gradle.kts":                 _ @embed(file="template/settings.gradle.kts", type=text)
	"build.gradle.kts":                    _ @embed(file="template/build.gradle.kts", type=text)
	"gradle.properties":                   _ @embed(file="template/gradle.properties", type=text)
	".gitignore":                          _ @embed(file="template/gitignore", type=text)
	"app/build.gradle.kts":                _ @embed(file="template/app/build.gradle.kts", type=text)
	"app/src/main/AndroidManifest.xml":    _ @embed(file="template/app/src/main/AndroidManifest.xml", type=text)
	"app/src/main/kotlin/HostEngine.kt":   _ @embed(file="template/app/src/main/kotlin/HostEngine.kt", type=text)
	"app/src/main/kotlin/MainActivity.kt": _ @embed(file="template/app/src/main/kotlin/MainActivity.kt", type=text)
	"app/src/main/kotlin/Program.kt":      _ @embed(file="template/app/src/main/kotlin/Program.kt", type=text)
	"app/src/main/kotlin/Vault.kt":        _ @embed(file="template/app/src/main/kotlin/Vault.kt", type=text)
	"app/src/main/kotlin/Fill.kt":         _ @embed(file="template/app/src/main/kotlin/Fill.kt", type=text)
	"app/src/main/kotlin/FillService.kt":  _ @embed(file="template/app/src/main/kotlin/FillService.kt", type=text)
	"app/src/main/kotlin/FillActivity.kt": _ @embed(file="template/app/src/main/kotlin/FillActivity.kt", type=text)
	"app/src/main/res/values/themes.xml":  _ @embed(file="template/app/src/main/res/values/themes.xml", type=text)
	"app/src/main/res/xml/autofill_service.xml": _ @embed(file="template/app/src/main/res/xml/autofill_service.xml", type=text)
	"app/src/main/assets/host.js":         _ @embed(file="template/app/src/main/assets/host.js", type=text)
	"app/src/main/assets/ses.umd.min.js":  _ @embed(file="template/app/src/main/assets/ses.umd.min.js", type=text)
	"app/src/main/assets/screen.js":       _ @embed(file="template/app/src/main/assets/screen.js", type=text)
	"app/src/main/assets/autofill.json":   _ @embed(file="template/app/src/main/assets/autofill.json", type=text)
	"app/src/test/kotlin/FillTest.kt":     _ @embed(file="template/app/src/test/kotlin/FillTest.kt", type=text)
}

// Written once and then the app's: pronto does not compile its screens for
// Android yet, so the phone's screen is authored, and which handler answers a
// fill and from which columns is the program's to say.
_seeded: ["app/src/main/assets/screen.js", "app/src/main/assets/autofill.json"]

// Kotlin sources, main and test, land under the application id's package path.
_kotlin: ["app/src/main/kotlin/", "app/src/test/kotlin/"]

#Host: H={
	app: string
	// The application id the verbs install and start: Android refuses a hyphen
	// in one, and an app's name admits it.
	applicationId: *"dev.pronto.\(strings.Replace(app, "-", "_", -1))" | string
	applicationId: =~"^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
	activity:      *".MainActivity" | string
	// What the launcher, the autofill picker and the unlock prompt call it.
	label: *app | string

	_gradle: "cd android; use tools.nu [run-mise]; run-mise exec -- gradle --console=plain"
	_adb:    "use tools.nu [run-mise]; run-mise exec -- sh -c"
	_apk:    "android/app/build/outputs/apk/debug/app-debug.apk"

	surface: {
		// Merged by mise beside the app's own config. mise's android-sdk sets
		// ANDROID_HOME to its install, so nothing the build reads is global;
		// Gradle is mise's too, the version AGP 9.4.1 requires.
		miseConf: """
			[tools]
			java = "temurin-21.0.12+8.0.LTS"
			android-sdk = "23.0"
			gradle = "9.6.0"

			"""
		// sayt's loop lowers a platform only on release, so these are the
		// rules themselves, each answering @android alone. The SDK packages are
		// the ones AGP 9.4.1 builds with; sdkmanager has no version for
		// platform-tools, so adb is the channel's on the day setup runs.
		rules: {
			setup: "android-sdk": {
				platform: "android"
				cmds: [
					{do: "use tools.nu [run-mise]; 1..30 | each { \"y\" } | str join \"\\n\" | run-mise exec -- sdkmanager --licenses | ignore"},
					{do: "use tools.nu [run-mise]; run-mise exec -- sdkmanager --install \"platform-tools\" \"platforms;android-36\" \"build-tools;36.0.0\""},
				]
			}
			build: android: {
				platform: "android"
				cmds: [{do: "\(H._gradle) :app:assembleDebug"}]
			}
			test: android: {
				platform: "android"
				cmds: [{do: "\(H._gradle) :app:testDebugUnitTest"}]
			}
			launch: android: {
				platform: "android"
				cmds: [
					{do: "\(H._gradle) :app:assembleDebug"},
					{do: "\(H._adb) \"$ANDROID_HOME/platform-tools/adb install -r \(H._apk)\""},
					{do: "\(H._adb) \"$ANDROID_HOME/platform-tools/adb shell am start -S -n \(H.applicationId)/\(H.activity)\""},
				]
			}
		}
	}

	// What an app holds, by path from its root: sayt merges the say file with
	// pronto's .say.yaml, mise the drop-in with the app's own config, and the
	// Gradle project under android/ takes the program's shell/ as its assets.
	// A seeded file is written only where none exists.
	files: {
		".say.json": {
			seed:  false
			merge: true
			text:  json.Indent(json.Marshal({say: {for verb, rs in H.surface.rules {(verb): rulemap: rs}}}), "", "  ") + "\n"
		}
		".config/mise/conf.d/android.toml": {seed: false, text: H.surface.miseConf}
		for path, source in _template {
			let filled = strings.Replace(strings.Replace(strings.Replace(source, "__APPLICATION_ID__", H.applicationId, -1), "__APP__", H.app, -1), "__LABEL__", H.label, -1)
			let dest = [
				for k in _kotlin if strings.HasPrefix(path, k) {"\(k)\(strings.Replace(H.applicationId, ".", "/", -1))/\(strings.TrimPrefix(path, k))"},
				path,
			][0]
			"android/\(dest)": {
				seed: [for s in _seeded if s == path {true}, false][0]
				text: filled
			}
		}
	}
}
