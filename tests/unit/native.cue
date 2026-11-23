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
		{call: "native.battery", expect: {missing: [], failed: []}, why: "a case in the contract that did not run is a hole in the battery, and a failing one is a host that breaks it"},
	]}

	"Android's generated files are what they were before the shared core": {suite: "native", steps: [
		{call: "native.golden", args: ["terminal", ["app=emit"]], expect: [], why: "the terminal mode, by default"},
		{call: "native.golden", args: ["vault", ["app=emit", "mode=vault", "label=MyVault"]], expect: [], why: "the vault mode"},
		{call: "native.golden", args: ["full", ["app=pass-vault", "label=Keep", "base=https://keep.example", "package=demo", "config=" + json.Marshal({scenarios: ["a.cue"], signing: [_fp], unlock: "biometric", autofill: true, release: {file: "secrets.enc.yaml", secret: "k"}})]], expect: [], why: "signed, unlocked, filling, released from a SOPS file, in a hyphenated app"},
		{call: "native.golden", args: ["project", ["app=emit", "config=" + json.Marshal({scenarios: [], release: {project: "demo-proj"}})]], expect: [], why: "released from a Secret Manager project"},
	]}
}
