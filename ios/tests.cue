package ios

import (
	"strings"
	"encoding/yaml"
)

_t: #Host & {app: "emit", label: "Emit"}

// Every rule answers @ios alone, so the web verbs never run it.
platforms: [for verb in ["setup", "build", "lint", "test", "launch"] for _, r in _t.surface.rules[verb] if r.platform == "ios" {verb}] & ["setup", "build", "lint", "test", "launch"]
sayJsonRules: strings.Contains(_t.files[".say.json"].text, "\"platform\": \"ios\"") & true

// The generated project's bundle id, versions, label and entitlements are the spec's: what the files hold is read back from them.
_project: yaml.Unmarshal(_t.files["ios/project.yml"].text)
bundleId: _project.targets.Host.settings.base.PRODUCT_BUNDLE_IDENTIFIER & "dev.pronto.emit"
testsId:  _project.targets.HostTests.settings.base.PRODUCT_BUNDLE_IDENTIFIER & "dev.pronto.emit.tests"
versions: [_project.settings.base.MARKETING_VERSION, _project.settings.base.CURRENT_PROJECT_VERSION] & ["0.1.0", 1]
label: _project.targets.Host.info.properties.CFBundleDisplayName & "Emit"
noEntitlements: _project.targets.Host.entitlements.properties & {}
noFaceId: [for k, _ in _project.targets.Host.info.properties if k == "NSFaceIDUsageDescription" {k}] & []
_tuned: yaml.Unmarshal((#Host & {app: "emit", unlock: "biometric", marketingVersion: "2.3.4", buildNumber: 7, entitlements: {"com.apple.developer.associated-domains": ["webcredentials:emit.example"]}}).files["ios/project.yml"].text)
tunedVersions: [_tuned.settings.base.MARKETING_VERSION, _tuned.settings.base.CURRENT_PROJECT_VERSION] & ["2.3.4", 7]
tunedEntitlements: _tuned.targets.Host.entitlements.properties["com.apple.developer.associated-domains"] & ["webcredentials:emit.example"]
tunedFaceId: _tuned.targets.Host.info.properties.NSFaceIDUsageDescription & "Unlock emit"

// The tests that read the bundle back hold the same id and versions as the project.
_tests:               _t.files["ios/Tests/HostTests.swift"].text
testsHoldTheId:       strings.Contains(_tests, "\"dev.pronto.emit\"") & true
testsHoldTheVersions: strings.Contains(_tests, "\"0.1.0\"") & strings.Contains(_tests, "\"1\"") & true

// A bundle id admits a hyphen and no underscore, and an app's name admits both.
idFromUnderscore: (#Host & {app: "pass_vault"}).bundleId & "dev.pronto.pass-vault"

// Xcode is the Mac's: the toolchain names its version, runtime and device, and mise pins the two tools beside it.
_toolchain:        _t.files["ios/toolchain.nu"].text
xcodeNamed:        strings.Contains(_toolchain, "const xcode = \"27.2\"") & true
developerDir:      strings.Contains(_toolchain, "const developer_dir = \"/Applications/Xcode.app/Contents/Developer\"") & true
slotted:           strings.Contains(_toolchain, "tests/slot.ts --weight $weight --what") & true
misePinsXcodegen:  strings.Contains(_t.files[".config/mise/conf.d/ios.toml"].text, "XcodeGen\" = { version = \"2.48.0\"") & true
misePinsSwiftlint: strings.Contains(_t.files[".config/mise/conf.d/ios.toml"].text, "SwiftLint\" = { version = \"0.65.1\"") & true

// Only the config is the app's once written; the project, the sources and the toolchain are regenerated.
seeded: [for p, f in _t.files if f.seed {p}] & ["ios/ios.json"]
noTokenLeft: [for p, f in _t.files if strings.Contains(f.text, "__") {p}] & []
