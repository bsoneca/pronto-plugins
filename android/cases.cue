package android

// The JVM unit cases of the host's native code (Fill.kt, Ask in Fill.kt, SealedStore.kt's Seal, Unlock.kt), as data:
// the inputs and what each must give, refusals included. Exported to every app as app/src/test/resources/android_cases.json
// (host.cue); each Kotlin test class is a loop that reads it and calls the native code, so a case is added here, never in Kotlin.
// A byte is a hex pair; a SHA-256 of a one-byte certificate is written out.

_sha: {
	"01": "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"
	"02": "dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986"
}

#Field: {
	id:         string
	domain?:    string | null
	scheme?:    string
	hints?: [...string]
	inputType?: int
	htmlType?:  string
	htmlName?:  string
}

_cases: {
	// Signer.tokens(current, past): the current signer first, then each certificate it rotated from.
	signer: [
		{why: "the current signer first, then each it rotated from", current: ["02"], past: ["01"], want: [_sha["02"], _sha["01"]]},
		{why: "several signers join in a fixed order", current: ["01", "02"], past: [], want: ["\(_sha["01"])+\(_sha["02"])"]},
		{why: "several signers join in a fixed order, whatever order the platform lists them", current: ["02", "01"], past: [], want: ["\(_sha["01"])+\(_sha["02"])"]},
		{why: "no certificates, no tokens", current: [], past: [], want: []},
	]

	// Fill.probe(package, field): what is asked about. A non-browser app's WebView domain is not trusted; plain http gets nothing.
	probe: [
		{why: "a domain counts from a browser, lowercased and without its port", package: "com.android.chrome", field: #Field & {id: "p", domain: "Login.Example.com:443", scheme: "https"}, want: {kind: "web", target: "login.example.com"}},
		{why: "a domain from a non-browser app is the app", package: "com.evil.app", field: #Field & {id: "p", domain: "example.com", scheme: "https"}, want: {kind: "app", target: "com.evil.app"}},
		{why: "no domain is the app", package: "com.example.app", field: #Field & {id: "p", scheme: "https"}, want: {kind: "app", target: "com.example.app"}},
		{why: "an empty domain is the app, even in a browser", package: "com.android.chrome", field: #Field & {id: "p", domain: "", scheme: "https"}, want: {kind: "app", target: "com.android.chrome"}},
		{why: "a plain http page gets nothing: anyone on the network could have written its form", package: "com.android.chrome", field: #Field & {id: "p", domain: "bank.com", scheme: "http"}, want: null},
	]

	// Fill.targets(fields): which field takes the username and which the password. inputType 1 is text, 129 text-password.
	targets: [
		{why: "an ad frame on bank.com is not bank.com: its field never takes the username", fields: [
			#Field & {id: "ad", domain: "ads.example.net", hints: ["username"]},
			#Field & {id: "p", domain: "bank.com", htmlType: "password"},
		], want: {username: null, password: "p"}},
		{why: "hints and types name the fields", fields: [
			#Field & {id: "search", inputType: 1},
			#Field & {id: "email", hints: ["emailAddress"]},
			#Field & {id: "pass", inputType: 129},
		], want: {username: "email", password: "pass"}},
		{why: "an html name and type name them too", fields: [
			#Field & {id: "u", htmlName: "login"},
			#Field & {id: "p", htmlType: "password"},
		], want: {username: "u", password: "p"}},
		{why: "an unmarked username is the text field right before the password", fields: [
			#Field & {id: "a"}, #Field & {id: "b"}, #Field & {id: "p", hints: ["password"]}, #Field & {id: "c"},
		], want: {username: "b", password: "p"}},
		{why: "no password, no targets", fields: [#Field & {id: "a"}, #Field & {id: "b"}], want: {username: null, password: null}},
	]

	// The ask over JSON, as both modes make it, against this contract.
	ask: {
		contract: {handler: "match", reads: ["login", "probe", "candidate"], probe: "probe", candidate: "candidate", vault: "login", title: "title", username: "username", secret: "secret", signer: "signer", signers: "signers"}
		// Ask.stated: what the handler is told.
		stated: [
			{why: "the probe is stated with its signers and no candidates", probe: {kind: "app", target: "com.bank"}, signers: ["aa+bb", "cc"], want: {id: "probe", kind: "app", target: "com.bank", signers: "aa+bb,cc", candidates: 0}},
			{why: "a site states no signers", probe: {kind: "web", target: "bank.com"}, signers: [], want: {id: "probe", kind: "web", target: "bank.com", signers: "", candidates: 0}},
		]
		// Ask.picks: the candidates put, in the handler's order; anything else in the reply is not a pick.
		picks: [
			{why: "the candidates put, in the handler's order", reply: {updates: [
				{op: "put", entity: "candidate", id: "b"},
				{op: "put", entity: "login", id: "x"},
				{op: "delete", entity: "candidate", id: "c"},
				{op: "put", entity: "candidate", id: "a"},
			]}, want: ["b", "a"]},
			{why: "a reply with no updates picks nothing", reply: {}, want: []},
		]
		// Ask.pins: only an unpinned app login is pinned, to the current signer.
		pins: [
			{why: "an unpinned app login is pinned to the current signer, a pinned one is left", probe: {kind: "app", target: "com.bank"}, signers: ["now", "before"], rows: [{id: "1"}, {id: "2", signer: "old"}], want: [{op: "patch", id: "1", signer: "now"}]},
			{why: "a site pins nothing", probe: {kind: "web", target: "bank.com"}, signers: ["now"], rows: [{id: "1"}], want: []},
			{why: "an app with no signers pins nothing", probe: {kind: "app", target: "com.bank"}, signers: [], rows: [{id: "1"}], want: []},
		]
	}

	// Seal (SealedStore.kt) over a software key: AES-256/GCM, a fresh nonce, the value's address as associated data. A blob is
	// 12 nonce bytes, the ciphertext and a 16-byte tag. Each case names its check; `plain` is the text sealed at actor/ns/key.
	seal: {
		plain: "ana 41s"
		address: {actor: "guest", ns: "device", key: "best"}
		cases: [
			{check: "opens", why: "a sealed value opens to what was sealed"},
			{check: "shape", why: "the blob is nonce, ciphertext, tag, and hides the value", size: 12 + 7 + 16, absent: "ana"},
			{check: "freshNonce", why: "every seal uses a fresh nonce", nonce: 12},
			{check: "otherAddress", why: "another actor's address is refused", address: {actor: "someone", ns: "device", key: "best"}},
			{check: "otherAddress", why: "another key's address is refused", address: {actor: "guest", ns: "device", key: "other"}},
			{check: "otherAddress", why: "another namespace's address is refused", address: {actor: "guest", ns: "session", key: "best"}},
			{check: "flipped", why: "a flipped byte, anywhere in the blob, is refused"},
			{check: "otherKey", why: "another key refuses it"},
			{check: "truncated", why: "a blob shorter than a nonce and a tag is refused", bytes: 5},
		]
	}

	// Unlock (Unlock.kt): the wrap of the data key under a software key; the data is 32 bytes counting up from 0.
	unlock: {
		bytes: 32
		wrap: [
			{check: "roundtrip", why: "a wrapped key unwraps to the same key, an AES key"},
			{check: "shape", why: "the wrap is nonce, sealed key, tag, and hides the key", size: 12 + 32 + 16},
			{check: "otherKey", why: "another wrapping key is refused"},
			{check: "flipped", why: "a flipped byte, anywhere in the wrap, is refused"},
			{check: "decryptor", why: "27 bytes is too short for a nonce and a tag: no decryptor", bytes: 27, has: false},
			{check: "decryptor", why: "28 bytes is the shortest that has one", bytes: 28, has: true},
		]
		// Unlock.state(rows, wrapped): rows with no wrapped key are lost, never fresh. wrapped is the byte count, or null.
		state: [
			{why: "nothing kept is fresh", rows: false, wrapped: null, want: "FRESH"},
			{why: "rows with no wrapped key are lost, never fresh", rows: true, wrapped: null, want: "LOST"},
			{why: "rows and a wrapped key are sealed", rows: true, wrapped: 60, want: "SEALED"},
			{why: "a wrapped key and no rows are sealed", rows: false, wrapped: 60, want: "SEALED"},
		]
	}
}
