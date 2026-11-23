// The bridge contracts of a native terminal host (docs/native-terminal.md, "The host kit"): the functions
// a host defines on the engine's global before the terminal bundle runs, each by name, argument types and
// result, and the functions the bundle defines for the host to call back. The bundle (browser.js, display.js,
// main.js) is one JS artifact for every platform, so these names and shapes are what a host implements.
// Android's are Kotlin's `qjs.function` calls (TerminalEngine.kt); tests/unit/native.cue holds the set of names to
// them, and the battery (native/battery.cue) holds the behaviour of the storage bridges. Argument types are the contract's
// alone for now: nothing checks a host's arity against them.
package native

// A value on the bridge: text, an integer, a boolean, text that holds JSON, or nothing.
#Type: "string" | "int" | "bool" | "json" | "void"

#Group: "app" | "display" | "storage" | "network" | "crypto" | "passkeys" | "time" | "locale" | "assets" | "log"

#Bridge: {
	group: #Group
	// The arguments, in order; `nullable` lists the positions that may be null.
	args: *[] | [...#Type]
	nullable: *[] | [...int & >=0 & <len(args)]
	result: #Type | *"void"
	// Whether the result may be null (a key with no value).
	resultNullable: *false | bool
	// The global the bundle defines, which the host calls later with the answer.
	answers?: #Callback
	why:      string
}

#Callback: {
	name: =~"^__on[A-Z]"
	args: [...#Type]
}

// The functions the host defines.
bridges: [Name=string]: #Bridge
bridges: {
	"__native_log": {group: "log", args: ["string", "string"], why: "a console line, its level then its text"}
	"__native_emit": {group: "display", args: ["json"], why: "the screen as a DivKit card, whenever it changed"}
	"__native_base": {group: "app", result: "string", why: "where the app's cluster is: the page's origin"}
	"__native_start": {group: "app", result: "string", why: "the address the terminal opens first, as a path or a URL"}
	"__native_reload": {group: "app", result: "void", why: "the page asked to reload: the host restarts the engine"}
	"__native_exit": {group: "app", result: "void", why: "the page went back past its first entry: the host leaves"}
	"__native_open": {group: "app", args: ["string"], why: "an address the page left for: the system opens it"}
	"__native_asset": {group: "assets", args: ["string"], result: "string", why: "a file the app ships, by its path"}
	"__native_uuid": {group: "crypto", result: "string", why: "a random UUID, as crypto.randomUUID"}
	"__native_random": {group: "crypto", args: ["int"], result: "json", why: "n random bytes as a JSON list of integers, as crypto.getRandomValues"}
	"__native_locale": {group: "locale", result: "string", why: "the device's language tag"}
	"__native_zone": {group: "locale", result: "string", why: "the device's time zone id"}
	"__native_intl": {group: "locale", args: ["string", "string", "json", "string"], result: "string", why: "Intl's work, by kind, locale, options and value"}
	"__native_timer": {
		group: "time", args: ["int", "int"]
		answers: {name: "__onTimer", args: ["int"]}
		why: "wake the page after a delay (id, ms): one wake, one JS turn"
	}
	"__native_clear": {group: "time", args: ["int"], why: "cancel a timer by id"}
	"__native_kv_get": {group: "storage", args: ["string", "string"], result: "string", resultNullable: true, why: "a value of a namespace, null when there is none"}
	"__native_kv_set": {group: "storage", args: ["string", "string", "string"], why: "keep a value under a namespace and a key"}
	"__native_kv_del": {group: "storage", args: ["string", "string"], why: "forget one key of a namespace"}
	"__native_kv_clear": {group: "storage", args: ["string"], why: "forget a namespace"}
	"__native_kv_keys": {group: "storage", args: ["string"], result: "json", why: "a namespace's keys as a JSON list of text"}
	"__native_fetch": {
		group: "network", args: ["int", "string", "string", "json", "string"], nullable: [4]
		answers: {name: "__onFetch", args: ["int", "int", "json", "string"]}
		why: "a request (id, url, method, headers, body or null): answered by __onFetch, or by __onFetchFailed(id, message)"
	}
	"__native_fetch_abort": {group: "network", args: ["int"], why: "stop a request by id; no answer follows"}
	"__native_passkeys": {group: "passkeys", result: "bool", why: "whether the host has an authenticator at all"}
	"__native_passkey": {
		group: "passkeys", args: ["string", "json", "int"]
		answers: {name: "__onPasskey", args: ["int", "bool", "json"]}
		why: "a ceremony (create or get, WebAuthn options with base64url buffers, id): answered by the response as WebAuthn JSON, or the error's name and message"
	}
	"__native_answer": {group: "app", args: ["int", "bool", "string"], why: "the host's own question to the page, answered: its value, or why it was rejected"}
}

// The functions the bundle defines, which the host calls: what the person did, and the later answers.
callbacks: [Name=string]: {args: [...#Type], why: string}
callbacks: {
	"__onTap": {args: ["string", "string"], why: "a tap or a long press on a view (tap or contextmenu, its id)"}
	"__onInput": {args: ["string", "string"], why: "a field's text changed (its id, its text)"}
	"__onResize": {args: ["int", "int"], why: "the display's width and height in density-independent pixels"}
	"__onLink": {args: ["string"], why: "the system opened the app at an address"}
	"__goBack": {args: [], why: "the system's back"}
	"__onTimer": {args: ["int"], why: "a timer fired"}
	"__onFetch": {args: ["int", "int", "json", "string"], why: "a response (id, status, headers, body)"}
	"__onFetchFailed": {args: ["int", "string"], why: "a request failed (id, message)"}
	"__onPasskey": {args: ["int", "bool", "json"], why: "a ceremony ended (id, whether it worked, the response or the error)"}
}

// A bridge's answer is a callback the bundle defines, with the same arguments: the two lists never drift apart.
for _, b in bridges if b.answers != _|_ {
	callbacks: (b.answers.name): args: b.answers.args
}
