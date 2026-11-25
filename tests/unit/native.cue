// The native host contract every platform shares (native/*.cue, docs/native-terminal.md): its bridges and callbacks, the
// host battery run on the headless engine, the Android host held to the contract, and Android's generated files held to a golden
// (android/golden/*.json: regenerate with GOLDEN_UPDATE=1 when a template change is meant).
package unit

import "encoding/json"

_fp: "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"

cases: {
	"the contract names the bridges the terminal bundle calls": {suite: "native", steps: [
		{call: "native.exportOf", args: ["./native", "[for n, b in bridges if b.group == \"storage\" {n}]"], expect: ["__native_kv_get", "__native_kv_set", "__native_kv_del", "__native_kv_clear", "__native_kv_keys"], why: "storage is five bridges over a namespace and a key"},
		{call: "native.exportOf", args: ["./native", "bridges.\"__native_fetch\".answers"], expect: {name: "__onFetch", args: ["int", "int", "json", "string"]}, why: "a request is answered later, by a callback of the shape the callbacks list gives"},
		{call: "native.exportOf", args: ["./native", "bridges.\"__native_kv_get\""]},
		{pick: ["result", "resultNullable"], expect: ["string", true], why: "a key with no value reads as null, never as an empty text"},
	]}

	"Android defines exactly the bridges the contract names": {suite: "native", steps: [
		{call: "native.androidBridges", expect: {missing: [], extra: []}, why: "a bridge Android lacks leaves the bundle calling nothing, and one it adds is outside the contract another host must meet"},
	]}

	"Android's bundle defines exactly the callbacks the contract names": {suite: "native", steps: [
		{call: "native.androidCallbacks", expect: {missing: [], extra: []}, why: "the host calls these by name, on every platform"},
	]}

	"the host battery passes on the headless engine, every case": {suite: "native", steps: [
		{call: "native.battery", expect: {failed: []}, why: "every case of the contract runs on the headless engine, and one that fails is a host that breaks it"},
	]}

	"Android's generated files are what they were before the shared core": {suite: "native", steps: [
		{call: "native.golden", args: ["terminal", ["app=emit"]], expect: [], why: "the terminal mode, by default"},
		{call: "native.golden", args: ["vault", ["app=emit", "mode=vault", "label=MyVault"]], expect: [], why: "the vault mode"},
		{call: "native.golden", args: ["full", ["app=pass-vault", "label=Keep", "base=https://keep.example", "package=demo", "config=" + json.Marshal({scenarios: ["a.cue"], signing: [_fp], unlock: "biometric", autofill: true, release: {file: "secrets.enc.yaml", secret: "k"}})]], expect: [], why: "signed, unlocked, filling, released from a SOPS file, in a hyphenated app"},
		{call: "native.golden", args: ["project", ["app=emit", "config=" + json.Marshal({scenarios: [], release: {project: "demo-proj"}})]], expect: [], why: "released from a Secret Manager project"},
	]}

	"the iOS host's project is what the CUE says": {suite: "native", steps: [
		{call: "native.exportOf", args: ["./ios", "[bundleId, testsId, versions, label]"], expect: ["dev.pronto.emit", "dev.pronto.emit.tests", ["0.1.0", 1], "Emit"], why: "the generated project.yml is read back: its bundle ids, versions and label are the spec's"},
		{call: "native.exportOf", args: ["./ios", "[tunedVersions, tunedEntitlements, tunedFaceId]"], expect: [["2.3.4", 7], ["webcredentials:emit.example"], "Unlock emit"], why: "the app's config sets the versions and the entitlements, and a biometric unlock asks for Face ID by name"},
	]}

	"the iOS host's verbs, toolchain and tests hold the spec": {suite: "native", steps: [
		{call: "native.exportOf", args: ["./ios", "[platforms, xcodeNamed, developerDir, slotted, misePinCount, testsHoldTheId, testsHoldTheVersions, seeded, noTokenLeft]"], expect: [["setup", "build", "lint", "test", "launch"], true, true, true, 2, true, true, ["ios/ios.json"], []], why: "every rule answers @ios alone, Xcode is named once and found by DEVELOPER_DIR, a build claims the slot, mise pins the tools, only the config is seeded and no placeholder is left"},
	]}

	"the iOS host's tools are pinned as this repository pins them": {suite: "native", steps: [
		{call: "native.iosPinsDrift", expect: [], why: "xcodegen and swiftlint are in this repository's .mise.toml and in the drop-in the host writes, and the two lines must be equal or one of them is stale"},
	]}

	"the iOS host refuses entitlements that are not a property list's scalars and lists": {suite: "native", steps: [
		{call: "native.exportFails", args: ["./ios/export", "files", ["app=emit", "config=" + json.Marshal({entitlements: {nested: {a: 1}}})]], expect: true, why: "an entitlement is a text, a flag, a number or a list of texts; a nested object would be written to the plist as something else"},
		{call: "native.exportFails", args: ["./ios/export", "files", ["app=emit", "config=" + json.Marshal({entitlements: {"com.apple.developer.associated-domains": ["webcredentials:a.example"]}})]], expect: false, why: "and a list of texts is accepted"},
	]}

	"the iOS host refuses a label Xcode would expand": {suite: "native", steps: [
		{call: "native.exportFails", args: ["./ios/export", "files", ["app=emit", "label=Emit $(PRODUCT_NAME)"]], expect: true, why: "Xcode expands $(...) in an Info.plist value, so the home screen would not show the label"},
		{call: "native.exportFails", args: ["./ios/export", "files", ["app=emit", "label=Emit (beta)"]], expect: false, why: "and parentheses alone are a label"},
	]}

	"iOS's generated files are the golden's": {suite: "native", steps: [
		{call: "native.golden", args: ["terminal", ["app=emit"], "ios"], expect: [], why: "the default host"},
		{call: "native.golden", args: ["full", ["app=pass_vault", "label=Keep", "base=https://keep.example", "package=demo", "config=" + json.Marshal({scenarios: ["a.cue"], unlock: "biometric", marketingVersion: "1.2.0", buildNumber: 5, entitlements: {"com.apple.developer.associated-domains": ["webcredentials:keep.example"]}})], "ios"], expect: [], why: "unlocked, versioned, entitled, in an app whose name has an underscore"},
	]}
}
