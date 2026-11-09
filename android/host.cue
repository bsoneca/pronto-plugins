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
	"list"
	"strings"

	"github.com/bsoneca/pronto-plugins/assetlinks"
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
	"sign-release.sh":                     _ @embed(file="template/sign-release.sh", type=text)
}

// Written once and then the app's: pronto does not compile its screens for
// Android yet, so the phone's screen is authored, and which handler answers a
// fill and from which columns is the program's to say.
_seeded: ["app/src/main/assets/screen.js", "app/src/main/assets/autofill.json"]

// The terminal mode's project: omnishell's own interpreter running the app's
// screens, nothing seeded because nothing is the app's to write. Its sources sit
// in android/terminal, bundled by build@android at the app's omnishell pin.
_terminal: {
	"settings.gradle.kts":                 _template["settings.gradle.kts"]
	"build.gradle.kts":                    _template["build.gradle.kts"]
	"gradle.properties":                   _template["gradle.properties"]
	".gitignore":                          _template[".gitignore"]
	"sign-release.sh":                     _template["sign-release.sh"]
	"app/build.gradle.kts":                _ @embed(file="template/terminal/app/build.gradle.kts", type=text)
	"app/src/main/AndroidManifest.xml":    _ @embed(file="template/terminal/app/src/main/AndroidManifest.xml", type=text)
	"app/src/debug/AndroidManifest.xml":   _ @embed(file="template/terminal/app/src/debug/AndroidManifest.xml", type=text)
	"app/src/main/kotlin/MainActivity.kt": _ @embed(file="template/terminal/app/src/main/kotlin/MainActivity.kt", type=text)
	"app/src/main/kotlin/TerminalEngine.kt": _ @embed(file="template/terminal/app/src/main/kotlin/TerminalEngine.kt", type=text)
	"app/src/main/kotlin/SceneView.kt":      _ @embed(file="template/terminal/app/src/main/kotlin/SceneView.kt", type=text)
	"app/src/main/kotlin/SealedStore.kt":    _ @embed(file="template/terminal/app/src/main/kotlin/SealedStore.kt", type=text)
	"app/src/test/kotlin/SealTest.kt":       _ @embed(file="template/terminal/app/src/test/kotlin/SealTest.kt", type=text)
	"app/src/main/kotlin/Unlock.kt":         _ @embed(file="template/terminal/app/src/main/kotlin/Unlock.kt", type=text)
	"app/src/test/kotlin/UnlockTest.kt":     _ @embed(file="template/terminal/app/src/test/kotlin/UnlockTest.kt", type=text)
	"app/src/debug/kotlin/Driver.kt":      _ @embed(file="template/terminal/app/src/debug/kotlin/Driver.kt", type=text)
	"app/src/release/kotlin/Driver.kt":    _ @embed(file="template/terminal/app/src/release/kotlin/Driver.kt", type=text)
	"app/src/debug/kotlin/Passkeys.kt":    _ @embed(file="template/terminal/app/src/debug/kotlin/Passkeys.kt", type=text)
	"app/src/release/kotlin/Passkeys.kt":  _ @embed(file="template/terminal/app/src/release/kotlin/Passkeys.kt", type=text)
	"app/src/main/assets/prelude.js":      _ @embed(file="template/terminal/app/src/main/assets/prelude.js", type=text)
	"terminal/bound.js":                   _ @embed(file="template/terminal/bound.js", type=text)
	"terminal/browser.js":                 _ @embed(file="template/terminal/browser.js", type=text)
	"terminal/bundle.ts":                  _ @embed(file="template/terminal/bundle.ts", type=text)
	"terminal/compile.js":                 _ @embed(file="template/terminal/compile.js", type=text)
	"terminal/css.js":                     _ @embed(file="template/terminal/css.js", type=text)
	"terminal/display.js":                 _ @embed(file="template/terminal/display.js", type=text)
	"terminal/main.js":                    _ @embed(file="template/terminal/main.js", type=text)
	"terminal/passkeys.js":                _ @embed(file="template/terminal/passkeys.js", type=text)
	"terminal/scenarios.ts":               _ @embed(file="template/terminal/scenarios.ts", type=text)
	"terminal/trust.ts":                   _ @embed(file="template/terminal/trust.ts", type=text)
}

// Kotlin sources, main and test, land under the application id's package path.
_kotlin: ["app/src/main/kotlin/", "app/src/test/kotlin/", "app/src/debug/kotlin/", "app/src/release/kotlin/"]

#Host: H={
	app: string
	// The application id the verbs install and start: Android refuses a hyphen
	// in one, and an app's name admits it.
	applicationId: *"dev.pronto.\(strings.Replace(app, "-", "_", -1))" | string
	applicationId: =~"^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
	activity:      *".MainActivity" | string
	// What the launcher, the autofill picker and the unlock prompt call it.
	label: *app | string
	// terminal: omnishell's interpreter draws the program's screens, for any app.
	// vault: the app's own screen.js over sealed device tables and autofill.
	mode: *"terminal" | "vault"
	// Where a release build finds the app's cluster; a debug build is told at start.
	base: *"https://\(app).invalid" | string
	// The app's CUE package (program.cue's), which android_surface.cue joins.
	package: *"" | string
	// The SHA-256 fingerprints of the certificates that sign the release (android/android.json's
	// `signing`): the door admits its passkeys and its links open it. None: a release has no passkeys.
	signing: [...assetlinks.#Fingerprint] & list.UniqueItems()
	// Where the release key lives (android/android.json's `release`): the Secret Manager project and
	// secret holding its keystore. Named, android/sign-release.sh is written; none: there is no such script.
	// Whether the terminal's sealed storage opens only after one strong-biometric prompt
	// (android/android.json's `unlock`, Unlock.kt). none: its key needs no person, nobody is prompted.
	unlock: *"none" | "biometric"
	release: *null | {
		project: =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
		secret:  *"android-release-signing" | =~"^[A-Za-z0-9_-]{1,255}$"
	}

	_header: "generated by pronto-android from android/host.cue — do not edit"
	_signed: len(H.signing) > 0
	// The app's declaration of its Android build: its release certificates reach the door's auth
	// (capabilities.auth.android, the auth service's WEBAUTHN_ANDROID_ORIGINS) and its Digital Asset
	// Links, beside any other host's (assetlinks), so Android lets it use the door's passkeys.
	_surface: strings.Join(list.Concat([[
		"// \(H._header)",
		"package \(H.package)",
	], [if H._signed {"""

		import (
		\(strings.Join([for i in assetlinks.#Imports {"\t\"\(i)\""}], "\n"))
		)

		// The certificates that sign the app's Android release (android/android.json's signing).
		code: capabilities: auth: android: \(json.Marshal(H.signing))

		// Android lets the app use the door's passkeys, and open its links.
		\((assetlinks.#Statement & {package: H.applicationId, relation: [assetlinks.#Credentials, assetlinks.#Links], fingerprints: H.signing}).text)
		\(assetlinks.#Declaration)
		"""}]]), "\n") + "\n"

	_gradle: "cd android; use tools.nu [run-mise]; run-mise exec -- gradle --console=plain"
	_adb:    "use tools.nu [run-mise]; run-mise exec -- sh -c"
	_apk:    "android/app/build/outputs/apk/debug/app-debug.apk"
	// The terminal is bundled at the omnishell the app itself pins.
	_bundle: [
		if H.mode == "terminal" {{do: "use tools.nu [run-mise]; run-mise exec -- deno run -A --no-lock android/terminal/bundle.ts (run-mise where github:bonisoft3/omnishell | str trim)"}},
	]
	// PRONTO_BASE names a local stack; the emulator reaches the host at 10.0.2.2.
	_startExtras: [if H.mode == "terminal" {"${PRONTO_BASE:+ --es base $PRONTO_BASE}"}, ""][0]

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
				cmds: list.Concat([H._bundle, [{do: "\(H._gradle) :app:assembleDebug"}]])
			}
			test: android: {
				platform: "android"
				cmds: [{do: "\(H._gradle) :app:testDebugUnitTest"}]
			}
			launch: android: {
				platform: "android"
				cmds: list.Concat([H._bundle, [
					{do: "\(H._gradle) :app:assembleDebug"},
					{do: "\(H._adb) \"$ANDROID_HOME/platform-tools/adb install -r \(H._apk)\""},
					{do: "\(H._adb) \"$ANDROID_HOME/platform-tools/adb shell am start -S -n \(H.applicationId)/\(H.activity)\(H._startExtras)\""},
				]])
			}
			// The phone's acceptance: the app's CUE scenarios (named in android/android.json) run on the
			// emulator through real touches (android/terminal/scenarios.ts). Against PRONTO_BASE when it
			// names a stack that is up, else against one it brings up on a slot (tests/slot.ts launch,
			// weight 1) and takes down after. No scenarios named is a failure, never a pass.
			if H.mode == "terminal" {
				integrate: android: {
					platform: "android"
					cmds: list.Concat([H._bundle, [
						{do: "\(H._gradle) :app:assembleDebug"},
						{do: "use tools.nu [run-mise]; let scenarios = (open android/android.json | get scenarios); let base = ($env.PRONTO_BASE? | default \"stack\"); run-mise exec -- deno run -A --no-lock android/terminal/scenarios.ts \(H.applicationId) \(H._apk) $base ...$scenarios"},
					]])
				}
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
		// The scenario files integrate@android runs, by path from the app's root; the app's to fill.
		if H.mode == "terminal" {
			"android/android.json": {seed: true, text: json.Indent(json.Marshal({scenarios: []}), "", "  ") + "\n"}
		}
		if H.mode == "terminal" && H.package != "" {
			"android_surface.cue": {seed: false, text: H._surface}
		}
		for path, source in [if H.mode == "terminal" {_terminal}, _template][0] if path != "sign-release.sh" || H.release != null {
			let filled = strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(source, "__RELEASE_PROJECT__", [if H.release != null {H.release.project}, ""][0], -1), "__RELEASE_SECRET__", [if H.release != null {H.release.secret}, ""][0], -1), "__APPLICATION_ID__", H.applicationId, -1), "__APP__", H.app, -1), "__LABEL__", H.label, -1), "__BASE__", H.base, -1), "__UNLOCK__", H.unlock, -1)
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
