// The host battery: what every native host's engine must do, as data (docs/native-terminal.md, "The host kit").
// native/battery.js reads it and runs each case on an engine a host gives it (`define` a bridge, `eval` a script);
// a host adds no case of its own here, a case that is not platform-neutral is that host's. The first host to run it is
// the plugins' unit suite (tests/unit/native.cue) on Deno with the SES the phones load; each host runs the same
// cases on its own engine (QuickJS on Android, JavaScriptCore on iOS).
//
// A `script` case evaluates `script` on the engine after SES locked it down, in the realm the host's bridges are in, and
// compares its result (a script ends in JSON.stringify) with `want`. A `compartment` is how a program's handler runs:
// the case's script is evaluated in one, with no endowments, so what it finds is what a handler finds.
package native

#Case: {
	id:  =~"^[a-z][a-z0-9-]*$"
	why: string
} & ({
	kind:   "script"
	script: string
	want:   _
} | {
	kind:   "compartment"
	script: string
	want:   _
} | {
	// The passkey bridge's two forms (WebAuthn options out, the response back in), a buffer as a list of bytes.
	kind: "passkey"
	options: {...}
	wantOptions: {...}
	response: {...}
	wantCredential: {...}
})

battery: [...#Case]
battery: [
	{
		id:     "ses-locks-down", kind: "script"
		why:    "SES's lockdown froze the intrinsics: a program cannot change what another one reads"
		script: #"JSON.stringify([Object.isFrozen(Object.prototype), Object.isFrozen(Array.prototype), Object.isFrozen(Function.prototype)])"#
		want: [true, true, true]
	},
	{
		id:     "handler-clock-throws", kind: "compartment"
		why:    "a handler has no clock: Date.now throws, and so does a new Date() without an argument"
		script: #"JSON.stringify([(() => { try { Date.now(); return "ran"; } catch { return "threw"; } })(), (() => { try { new Date(); return "ran"; } catch { return "threw"; } })()])"#
		want: ["threw", "threw"]
	},
	{
		id:     "handler-randomness-throws", kind: "compartment"
		why:    "a handler has no randomness: Math.random throws"
		script: #"JSON.stringify((() => { try { Math.random(); return "ran"; } catch { return "threw"; } })())"#
		want:   "threw"
	},
	{
		id:     "handler-sees-no-bridge", kind: "compartment"
		why:    "a handler is caged: no bridge, no host global, no ambient authority"
		script: #"JSON.stringify([typeof __native_kv_get, typeof __native_fetch, typeof Deno, typeof process, typeof globalThis.fetch])"#
		want: ["undefined", "undefined", "undefined", "undefined", "undefined"]
	},
	{
		id:  "one-event-list-one-tree-list", kind: "compartment"
		why: "the same events fold to the same trees, twice: a handler's output is a function of its inputs"
		script: #"""
			const fold = (events) => { let n = 0; return events.map((e) => { n += 1; return { n, tree: `<p>${e}</p>` }; }); };
			const events = ["open", "tap", "tap"];
			const once = fold(events), twice = fold(events);
			JSON.stringify([once.length, once.map((t) => t.tree), JSON.stringify(once) === JSON.stringify(twice)])
			"""#
		want: [3, ["<p>open</p>", "<p>tap</p>", "<p>tap</p>"], true]
	},
	{
		id:  "storage-round-trip", kind: "script"
		why: "a value kept under a namespace and a key is read back, listed, forgotten, and a namespace is its own"
		script: #"""
			const set = globalThis.__native_kv_set, get = globalThis.__native_kv_get, del = globalThis.__native_kv_del, keys = globalThis.__native_kv_keys, clear = globalThis.__native_kv_clear;
			set("a", "k", "v1"); set("a", "j", "v2"); set("b", "k", "other");
			const read = [get("a", "k"), get("a", "j"), get("a", "none"), get("b", "k")];
			const listed = JSON.parse(keys("a")).sort();
			del("a", "k");
			const afterDel = [get("a", "k"), get("a", "j")];
			clear("a");
			JSON.stringify({ read, listed, afterDel, cleared: JSON.parse(keys("a")), kept: get("b", "k") })
			"""#
		want: {read: ["v1", "v2", null, "other"], listed: ["j", "k"], afterDel: [null, "v2"], cleared: [], kept: "other"}
	},
	{
		id:  "storage-values-are-text", kind: "script"
		why: "the store keeps text exactly as given: an empty value is not a missing one, and JSON text is not parsed"
		script: #"""
			globalThis.__native_kv_set("t", "empty", ""); globalThis.__native_kv_set("t", "json", "{\"a\":1}");
			JSON.stringify([globalThis.__native_kv_get("t", "empty"), globalThis.__native_kv_get("t", "json"), globalThis.__native_kv_get("t", "missing")])
			"""#
		want: ["", "{\"a\":1}", null]
	},
	{
		id:  "passkey-bridge-shape", kind: "passkey"
		why: "WebAuthn options cross the bridge with every buffer a base64url string, and the response comes back as buffers, null where WebAuthn has none"
		options: {challenge: [1, 2, 3], rp: {id: "example.com"}, user: {id: [4, 5], name: "a"}, allowCredentials: [{id: [9], type: "public-key"}]}
		wantOptions: {challenge: "AQID", rp: {id: "example.com"}, user: {id: "BAU", name: "a"}, allowCredentials: [{id: "CQ", type: "public-key"}]}
		response: {id: "CQ", rawId: "CQ", type: "public-key", response: {clientDataJSON: "AQID", authenticatorData: "BAU", signature: "CQ", userHandle: null}}
		wantCredential: {id: "CQ", rawId: [9], type: "public-key", response: {clientDataJSON: [1, 2, 3], authenticatorData: [4, 5], signature: [9], userHandle: null}}
	},
]
