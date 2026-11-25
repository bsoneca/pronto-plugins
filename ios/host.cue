// The iOS host, the native terminal's second plugin (docs/native-terminal.md): what an app that targets iOS
// needs beside the web terminal. Step 2 of the iOS host (PRONTO-1442) is the toolchain, a Swift project
// generated from this spec by XcodeGen (never a hand-written .pbxproj), and the verbs on the simulator.
// Step 3 (PRONTO-1443) is the JS engine, JavaScriptCore under SES, with the globals owed before lockdown() and the shared host
// battery on it; the sealed storage and screens come after. Unmodified pronto writes .say.yaml and owns no
// .say.json, and sayt merges every .say.* file, so the host's rules reach an app through a .say.json it generates.
@extern(embed)

package ios

import (
	"encoding/json"
	"encoding/yaml"
	"strings"

	"github.com/bsoneca/pronto-plugins/native"
)

_template: {
	"Sources/HostApp.swift":        _ @embed(file="template/Sources/HostApp.swift", type=text)
	"Tests/HostTests.swift":        _ @embed(file="template/Tests/HostTests.swift", type=text)
	"Tests/EngineTests.swift":      _ @embed(file="template/Tests/EngineTests.swift", type=text)
	"Sources/TerminalEngine.swift": _ @embed(file="template/Sources/TerminalEngine.swift", type=text)
	"Sources/Kv.swift":             _ @embed(file="template/Sources/Kv.swift", type=text)
	"Sources/Resources/prelude.js": _ @embed(file="template/Sources/Resources/prelude.js", type=text)
	".gitignore":                   _ @embed(file="template/gitignore", type=text)
	".swiftlint.yml":               _ @embed(file="template/swiftlint.yml", type=text)
	"toolchain.nu":                 _ @embed(file="template/toolchain.nu", type=text)
}

// Xcode is the Mac's own, so its version, the simulator runtime and the device the verbs use are stated once,
// here, and setup@ios fails with the exact version to install when the Mac differs. The two tools mise pins
// (xcodegen, swiftlint) are pinned the same in this repository's .mise.toml and in the app's .config/mise/conf.d/ios.toml.
_xcode:        "27.2"
_runtime:      "iOS 27.2"
_simulator:    "iPhone 17"
_developerDir: "/Applications/Xcode.app/Contents/Developer"
// Swift 6 is the language mode, and iOS 18 the oldest the host supports.
_swift:      "6.0"
_deployment: "18.0"
// What an xcodebuild keeps busy while it works, in tests/slot.ts's weight: cores, measured on this Mac: the hello host's xcodebuild used 17.8 s of CPU in 11 s of work, about 1.5 cores, so 2. Raise it when the terminal's sources arrive.
_weight: 2

#Host: H={
	// What every native host says: the app, its label, its base, its CUE package, the unlock, the scenarios (native/host.cue).
	native.#Core

	// The bundle id the verbs install and start. A bundle id admits hyphens and no underscore, and an app's name admits both.
	bundleId: *"dev.pronto.\(strings.Replace(H.app, "_", "-", -1))" | string
	bundleId: =~"^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$"
	// Xcode expands $(...) in an Info.plist value, so a label holding one would not be the label.
	label: !~"\\$\\("
	// The versions xcodebuild takes as build settings (MARKETING_VERSION=, CURRENT_PROJECT_VERSION=), so a refresh of the host never reverts them.
	marketingVersion: *"0.1.0" | =~"^[0-9]+(\\.[0-9]+){1,2}$"
	buildNumber:      *1 | (int & >=1)
	// The entitlements of the app (ios/ios.json's `entitlements`), a property list as data: none by default.
	entitlements: *close({}) | {[string]: string | bool | number | [...string]}

	_infoProperties: {
		CFBundleDisplayName:        H.label
		CFBundleShortVersionString: "$(MARKETING_VERSION)"
		CFBundleVersion:            "$(CURRENT_PROJECT_VERSION)"
		UILaunchScreen: {}
		UIApplicationSceneManifest: UIApplicationSupportsMultipleScenes: false
		// Face ID is asked for only by an app that unlocks behind a biometric.
		if H.unlock == "biometric" {
			NSFaceIDUsageDescription: "Unlock \(H.label)"
		}
	}

	// The project xcodegen turns into ios/Host.xcodeproj.
	project: {
		name: "Host"
		options: {
			bundleIdPrefix: "dev.pronto"
			deploymentTarget: iOS: _deployment
			createIntermediateGroups: true
		}
		settings: base: {
			SWIFT_VERSION:           _swift
			MARKETING_VERSION:       H.marketingVersion
			CURRENT_PROJECT_VERSION: H.buildNumber
		}
		targets: {
			Host: {
				type:     "application"
				platform: "iOS"
				sources: ["Sources"]
				info: {path: "Info.plist", properties: H._infoProperties}
				entitlements: {path: "Host.entitlements", properties: H.entitlements}
				settings: base: PRODUCT_BUNDLE_IDENTIFIER: H.bundleId
			}
			HostTests: {
				type:     "bundle.unit-test"
				platform: "iOS"
				sources: ["Tests"]
				dependencies: [{target: "Host"}]
				settings: base: {
					PRODUCT_BUNDLE_IDENTIFIER: "\(H.bundleId).tests"
					GENERATE_INFOPLIST_FILE:   "YES"
				}
			}
		}
		schemes: Host: {
			build: targets: Host: "all"
			run: config: "Debug"
			test: {config: "Debug", targets: ["HostTests"]}
		}
	}

	surface: {
		// Merged by mise beside the app's own config. Both are Mac tools: xcodebuild is Xcode's, which mise cannot install.
		// These two versions are also pinned in this repository's .mise.toml and mise.lock (for its own use); the unit case
		// "the iOS host's tools are pinned as this repository pins them" holds the two to each other.
		miseConf: """
			[tools]
			"aqua:yonaskolb/XcodeGen" = { version = "2.48.0", os = ["macos"] }
			"aqua:realm/SwiftLint" = { version = "0.65.1", os = ["macos"] }

			"""
		// sayt's loop lowers a platform only on release, so these are the rules themselves, each answering @ios alone.
		// The work is ios/toolchain.nu's. A build and a test claim tests/slot.ts's budget (_weight); a launch
		// builds, then boots the simulator, installs the app and starts it.
		rules: {
			setup: ios: {platform: "ios", cmds: [{do: "use tools.nu [run-mise]; source ios/toolchain.nu; check"}]}
			build: ios: {platform: "ios", cmds: [{do: "use tools.nu [run-mise]; source ios/toolchain.nu; build"}]}
			lint: ios: {platform: "ios", cmds: [{do: "use tools.nu [run-mise]; source ios/toolchain.nu; lint"}]}
			test: ios: {platform: "ios", cmds: [{do: "use tools.nu [run-mise]; source ios/toolchain.nu; test"}]}
			launch: ios: {platform: "ios", cmds: [{do: "use tools.nu [run-mise]; source ios/toolchain.nu; launch"}]}
		}
	}

	// What an app holds, by path from its root: sayt merges the say file with pronto's .say.yaml, mise the drop-in with
	// the app's own config. Only the config is seeded: the project is the host's until the terminal's screens arrive.
	files: {
		".say.json": {
			seed:  false
			merge: true
			text: json.Indent(json.Marshal({say: {for verb, rs in H.surface.rules {(verb): rulemap: rs}}}), "", "  ") + "\n"
		}
		".config/mise/conf.d/ios.toml": {seed: false, text: H.surface.miseConf}
		// The scenario files integrate@ios will run (a later step) and the app's entitlements, unlock and versions; the app's to fill.
		"ios/ios.json": {seed: true, text: H.configSeed}
		"ios/project.yml": {seed: false, text: "# generated by pronto-ios from ios/host.cue — do not edit\n" + yaml.Marshal(H.project)}
		// What both hosts run, one source (native/sources.cue): SES, and the battery with the cases the host's tests run it on.
		"ios/Sources/Resources/ses.umd.min.js": {seed: false, text: native.sources.ses}
		"ios/Tests/Resources/passkeys.js": {seed: false, text: native.sources.passkeys}
		"ios/Tests/Resources/battery.js": {seed: false, text: native.sources.battery}
		"ios/Tests/Resources/battery.json": {seed: false, text: json.Marshal(native.battery)}
		for path, tmpl in _template {
			let filled = strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(strings.Replace(tmpl,
			"__DEVELOPER_DIR__", _developerDir, -1),
			"__XCODE__", _xcode, -1),
			"__RUNTIME__", _runtime, -1),
			"__SIMULATOR__", _simulator, -1),
			"__WEIGHT__", "\(_weight)", -1),
			"__BUNDLE_ID__", H.bundleId, -1),
			"__MARKETING_VERSION__", H.marketingVersion, -1),
			"__BUILD_NUMBER__", "\(H.buildNumber)", -1)
			"ios/\(path)": {seed: false, text: filled}
		}
	}
}
