// The broker's phone (identity/broker/phone.ts): a person signs in with a number Identity Platform
// texts a code to, behind the same code flow as Google. The tenant learns a pairwise subject and
// nothing else (never the number); only tenants the operator lists may offer it (each sign-in is
// an SMS the operator pays for); Firebase's token is checked as Google's is (its key, its project,
// a phone sign-in made during this visit, a Brazilian mobile); the emulator's unsigned token only
// on a localhost broker.
package unit

cases: {
	"a phone sign-in gives the tenant a pairwise subject and never the number": {suite: "identity", steps: [
		{call: "identity.phoneBrokered"}, {keep: "out"},
		{get: "approved", expect: 200},
		{use: "out"}, {get: "provider", expect: "phone"},
		{use: "out"}, {get: "firebaseSub", expect: false, why: "the subject is the broker's pairwise one, not Firebase's user id"},
		{use: "out"}, {get: "hasNumber", expect: false, why: "no claim carries the number"},
		{use: "out"}, {get: "claims", expect: ["aud", "azp", "exp", "iat", "idp", "iss", "nonce", "sub"], why: "nothing beyond the protocol's own, though the tenant asked for profile"},
		{use: "out"}, {get: "aud", expect: "https://app.example.com"},
		{use: "out"}, {get: "says", matches: "You'll continue with your phone\\."},
	]}
	"the same phone signs in as the same subject, and as another one in another tenant": {suite: "identity", steps: [
		{call: "identity.phoneBrokered"}, {get: "sub"}, {keep: "first"},
		{call: "identity.phoneBrokered"}, {get: "sub"}, {keep: "again"},
		{call: "identity.phoneBrokered", args: [{tenant: "https://localhost:8443"}]}, {get: "sub"}, {keep: "other"},
		{call: "probe.distinct", args: [["$first", "$again", "$other"]], expect: 2, why: "first and again are one subject; the other tenant's is its own"},
	]}
	"a tenant the operator did not list is refused before any page": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{tenant: "https://other.example.com"}], expect: {refused: "unauthorized_client"}},
	]}
	"the local broker on Hydra rejects the login of a tenant not listed": {suite: "identity", steps: [
		{call: "identity.hydraPhoneLogin", args: ["https://other.example.com"], expect: {status: 302, rejected: "unauthorized_client"}},
	]}
	"the phone page asks for the number in the reader's language, and names the gate it asks first": {suite: "identity", steps: [
		{call: "identity.phoneBrokered"}, {keep: "out"},
		{get: "lang", expect: "pt-BR"},
		{use: "out"}, {get: "title", expect: "Entrar com celular"},
		{use: "out"}, {get: "asks", expect: true},
		{use: "out"}, {get: "admit", expect: "https://app.example.com/rental/phone/admit"},
		{use: "out"}, {get: "csp", matches: "connect-src 'self' https://app\\.example\\.com https://identitytoolkit\\.googleapis\\.com"},
		{use: "out"}, {get: "csp", matches: "frame-ancestors 'none'"},
		{use: "out"}, {get: "emulator", expect: null},
		{use: "out"}, {get: "referrer", expect: "strict-origin", why: "the API key admits the broker's origin as a referrer, which no-referrer would withhold"},
		{call: "identity.phoneBrokered", args: [{lang: "en-US,en;q=0.8"}]}, {get: "title", expect: "Sign in with your phone"},
		{call: "identity.phoneBrokered", args: [{lang: "fr"}]}, {get: "lang", expect: "en", why: "English for a language the page does not speak"},
	]}
	"a token for another project is refused": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{project: "someone-else"}], holds: {approved: 400, error: "refused"}},
	]}
	"a token from another sign-in method is refused": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{over: {firebase: {sign_in_provider: "password"}}}], holds: {approved: 400, error: "refused"}},
	]}
	"a token signed in before the page was opened is refused": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{over: {auth_time: 1700000000}}], holds: {approved: 400, error: "refused"}, why: "a token kept from an earlier sign-in"},
	]}
	"a number that is not a Brazilian mobile is refused, and the page is told why": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{over: {phone_number: "+14155550100"}}], holds: {approved: 400, error: "region"}},
	]}
	"an unsigned token is refused by a broker that is not on the emulator": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{unsigned: true}], holds: {approved: 400, error: "refused"}},
	]}
	"a localhost broker on the emulator takes the emulator's unsigned token": {suite: "identity", steps: [
		{call: "identity.phoneBrokered", args: [{unsigned: true, issuer: "http://localhost:19000", project: "demo-ume-rental", env: {PHONE_EMULATOR: "127.0.0.1:9099", PHONE_PROJECT: "demo-ume-rental", PHONE_API_KEY: null, PHONE_APP_ID: null}}]}, {keep: "out"},
		{get: "approved", expect: 200},
		{use: "out"}, {get: "emulator", expect: "http://127.0.0.1:9099"},
		{use: "out"}, {get: "csp", matches: "http://127\\.0\\.0\\.1:9099"},
	]}
	"the emulator is refused on a broker anyone else reaches": {suite: "identity", steps: [
		{call: "identity.phoneSettings", args: [{PHONE_EMULATOR: "127.0.0.1:9099"}], throws: "PHONE_EMULATOR is for a localhost broker"},
	]}
	"a broker offers no phone unless its project is named, and then needs the gate and the tenants": {suite: "identity", steps: [
		{call: "identity.phoneSettings", args: [{PHONE_PROJECT: null}], expect: null},
		{call: "identity.phoneSettings", args: [{PHONE_ADMIT: null}], throws: "PHONE_ADMIT is required"},
		{call: "identity.phoneSettings", args: [{PHONE_TENANTS: null}], throws: "PHONE_TENANTS is required"},
		{call: "identity.phoneSettings", args: [{PHONE_API_KEY: null}], throws: "PHONE_API_KEY is required"},
		{call: "identity.phoneSettings", holds: {resendSeconds: 60, sdk: "13.1.0", authDomain: "brawl-chess.firebaseapp.com", pattern: "^\\+55[1-9][1-9]9[0-9]{8}$"}},
	]}
	"the tenants list matches an origin exactly, a star standing for a port": {suite: "identity", steps: [
		{call: "phone.tenantAdmitted", args: [["https://ume.bsoneca.com", "https://localhost:*"], "https://ume.bsoneca.com"], expect: true},
		{call: "phone.tenantAdmitted", args: [["https://ume.bsoneca.com", "https://localhost:*"], "https://localhost:8443"], expect: true},
		{call: "phone.tenantAdmitted", args: [["https://ume.bsoneca.com"], "https://ume.bsoneca.com.evil.example"], expect: false},
		{call: "phone.tenantAdmitted", args: [["https://localhost:*"], "https://localhost:x"], expect: false},
	]}
	"the page's language is the first of its own the reader asks for": {suite: "identity", steps: [
		{call: "phone.langOf", args: ["pt-BR,pt;q=0.9,en;q=0.8"], expect: "pt-BR"},
		{call: "phone.langOf", args: ["en-GB,pt;q=0.5"], expect: "en"},
		{call: "phone.langOf", args: [null], expect: "en"},
	]}
	"the broker starts as a program with the phone configured, and offers it beside Google": {suite: "identity", steps: [
		{call: "identity.started", expect: ["google", "phone"], why: "phone.ts once imported main.ts, which loads it with a top-level await: the cycle never resolved and Cloud Run's revision exited"},
		{call: "identity.started", args: [false], expect: ["google"]},
	]}
	"a send that fails is logged with Firebase's code and message, and tried once more against the emulator alone": {suite: "identity", steps: [
		{call: "identity.sendTries", args: [true, 1], expect: {sent: true, tries: 2, lines: ["phone: no code sent (try 1): request dropped"]}, why: "a loaded machine's emulator dropped a send with no code: bsoneca/ume's gates failed phone-signin on it (2026-11-02)"},
		{call: "identity.sendTries", args: [true, 2], expect: {sent: false, tries: 2, lines: ["phone: no code sent (try 1): request dropped", "phone: no code sent (try 2): request dropped"]}, why: "once more, never a loop"},
		{call: "identity.sendTries", args: [false, 1, "auth/network-request-failed"], expect: {sent: false, tries: 1, lines: ["phone: no code sent (try 1): auth/network-request-failed request dropped"]}, why: "against Firebase a tap sends one SMS at most, so the operator's SMS limits count every one"},
		{call: "identity.sendTries", args: [false, 0], expect: {sent: true, tries: 1, lines: []}},
	]}
	"the phone page sends through sendCode, its source served with the page": {suite: "identity", steps: [
		{call: "identity.pageSends", holds: {defines: true, sendsThrough: true, sendsOtherwise: 1}, why: "the retry runs in the browser; a send past it would not be retried or logged"},
	]}
	"a tap before Firebase's SDK has loaded waits for it, and is never sent to an SDK not there": {suite: "identity", steps: [
		{call: "identity.pageSends", holds: {startedOnce: true, sendWaits: true}, why: "bsoneca/ume's phone-signin under load: 'Cannot read properties of undefined (reading RecaptchaVerifier)', twice, the retry included (2026-11-02)"},
	]}
	"the local broker's Hydra keeps its rows in a file whose writers wait, so two sign-ins at once both go through": {suite: "identity", steps: [
		{call: "identity.hydraLocalStore", expect: {memory: false, file: true, waits: true, migratedFirst: true}, why: "Hydra in memory answered a sign-in 500, 'Unable to serialize access due to a concurrent update', when another wrote at once (bsoneca/ume's phone-signin, 2026-11-02); pronto-verify's Hydra met the same (bsoneca/ume#20)"},
	]}

	// PHONE_OTP=broker (identity/broker/otp.ts): the broker issues and checks the codes, a sender texts them, a gate admits each SMS.
	"broker mode takes the sender and the gate, not Firebase's project, and Firebase mode stays the default": {suite: "identity", steps: [
		{call: "identity.otpSettings", holds: {otp: "broker", sms: "standin", project: "", hasSender: true, resendSeconds: 60}},
		{call: "identity.phoneSettings", holds: {otp: "firebase", sms: null, smsGate: null, project: "brawl-chess"}, why: "no PHONE_OTP: today's behaviour, unchanged"},
		{call: "identity.otpSettings", args: [{PHONE_SMS: null}], throws: "PHONE_SMS is required with PHONE_OTP=broker"},
		{call: "identity.otpSettings", args: [{PHONE_SMS_GATE: null}], throws: "PHONE_SMS_GATE is required"},
		{call: "identity.otpSettings", args: [{PHONE_SMS_GATE: "ftp://x"}], throws: "PHONE_SMS_GATE is an http\\(s\\) URL"},
		{call: "identity.otpSettings", args: [{PHONE_ADMIT: null}], throws: "PHONE_ADMIT is required"},
		{call: "identity.otpSettings", args: [{PHONE_TENANTS: null}], throws: "PHONE_TENANTS is required"},
		{call: "identity.otpSettings", args: [{PHONE_SMS: "zenvia"}], throws: "PHONE_SMS=zenvia is not a sender"},
		{call: "identity.otpSettings", args: [{PHONE_OTP: "sms"}], throws: "PHONE_OTP is firebase or broker"},
		{call: "identity.otpSettings", args: [{PHONE_PROJECT: "brawl-chess"}], throws: "PHONE_PROJECT is for PHONE_OTP=firebase"},
		{call: "identity.otpSettings", args: [{PHONE_API_KEY: "k"}], throws: "PHONE_API_KEY is for PHONE_OTP=firebase"},
		{call: "identity.phoneSettings", args: [{PHONE_SMS: "standin"}], throws: "PHONE_SMS is for PHONE_OTP=broker"},
		{call: "identity.phoneSettings", args: [{PHONE_SMS_GATE: "https://x.example"}], throws: "PHONE_SMS_GATE is for PHONE_OTP=broker"},
		{call: "identity.otpSettings", args: [{PHONE_RESEND_SECONDS: "30"}], holds: {resendSeconds: 30}},
		{call: "identity.otpSettings", args: [{PHONE_RESEND_SECONDS: "0"}], throws: "PHONE_RESEND_SECONDS"},
	]}
	"the stand-in sender is refused on a broker anyone else reaches": {suite: "identity", steps: [
		{call: "identity.otpSettings", args: [{}, "https://id.example.com"], throws: "PHONE_SMS=standin is for a localhost broker"},
	]}
	"the code asked for is the code that signs in, and the gate was asked first, signed by the key the broker publishes": {suite: "identity", steps: [
		{call: "identity.otpFlow", holds: {log: [{op: "send", status: 200}, {op: "approve", status: 200}], gateCalls: 1}}, {keep: "out"},
		{use: "out"}, {get: "gateJwt", holds: {signed: true, aud: "https://app.example.com/rental/phone/sms-gate", iss: "http://localhost:19000", event: "sms", phone: "+5511912345678", ttl: 60, type: "application/jwt", claims: ["aud", "event", "exp", "iat", "iss", "jti", "phone_number"]}},
		{use: "out"}, {get: "sub", matches: "^[A-Za-z0-9_-]{43}$", why: "the tenant's pairwise subject over the number's HMAC"},
	]}
	"the provider's subject for a number is an HMAC under a key from the broker's secret": {suite: "identity", steps: [
		{call: "otp.phoneSubject", args: ["a-secret-of-thirty-two-characters!", "+5511912345678"], expect: "Pnl8Lv7vTGoWM0aOoybSPsWFwoXkUjUZjxdjFmaA8mg", why: "a vector computed outside this code: HKDF-SHA-256 (empty salt, info 'pronto-identity phone subject v1'), then HMAC-SHA-256 of the number, base64url"},
		{call: "otp.phoneSubject", args: ["another-secret-of-thirty-two-chars!!", "+5511912345678"]}, {keep: "other"},
		{call: "probe.distinct", args: [["Pnl8Lv7vTGoWM0aOoybSPsWFwoXkUjUZjxdjFmaA8mg", "$other"]], expect: 2, why: "another secret, another subject"},
	]}
	"one number is one subject across sign-ins and restarts, another number another, in one tenant": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{phone: "+5511912345678"}]}, {get: "sub"}, {keep: "a"},
		{call: "identity.otpFlow", args: [{phone: "+5511912345678"}]}, {get: "sub"}, {keep: "again"},
		{call: "identity.otpFlow", args: [{phone: "+5511912345679"}]}, {get: "sub"}, {keep: "other"},
		{call: "probe.distinct", args: [["$a", "$again", "$other"]], expect: 2},
	]}
}

cases: {
	"a wrong code is told so, and the fifth wrong try kills the code, the right one included": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["approve", "000000"], ["approve", "000000"], ["approve", "000000"], ["approve", "000000"], ["approve", "000000"], ["approve", "right"]]}], holds: {log: [
			{op: "send", status: 200},
			{op: "approve", status: 400, error: "wrong_code"}, {op: "approve", status: 400, error: "wrong_code"}, {op: "approve", status: 400, error: "wrong_code"}, {op: "approve", status: 400, error: "wrong_code"},
			{op: "approve", status: 400, error: "too_many"},
			{op: "approve", status: 400, error: "expired"},
		]}, why: "000000 is a guess; it is the code once in a million runs"},
	]}
	"four wrong tries leave the right code good": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["approve", "000000"], ["approve", "000000"], ["approve", "000000"], ["approve", "000000"], ["approve", "right"]]}], holds: {log: [{op: "send"}, {error: "wrong_code"}, {error: "wrong_code"}, {error: "wrong_code"}, {error: "wrong_code"}, {op: "approve", status: 200}]}},
	]}
	"a code is good five minutes and not a second more": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["advance", 299000], ["approve", "right"]]}], holds: {log: [{op: "send"}, {op: "approve", status: 200}]}},
		{call: "identity.otpFlow", args: [{ops: [["send"], ["advance", 300000], ["approve", "right"]]}], holds: {log: [{op: "send"}, {op: "approve", status: 400, error: "expired"}]}},
	]}
	"a code is spent by the sign-in it signed in": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["approve", "right"], ["approve", "right"]]}], holds: {log: [{op: "send"}, {status: 200}, {status: 400}]}},
	]}
	"a number is texted again only after the resend wait, and the wait costs the gate nothing": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["send"], ["advance", 59000], ["send"], ["advance", 1000], ["send"]]}], holds: {log: [
			{op: "send", status: 200}, {op: "send", status: 429, error: "cooldown"}, {op: "send", status: 429, error: "cooldown"}, {op: "send", status: 200},
		], gateCalls: 2}},
		{call: "identity.otpFlow", args: [{env: {PHONE_RESEND_SECONDS: "10"}, ops: [["send"], ["advance", 10000], ["send"]]}], holds: {log: [{status: 200}, {status: 200}]}},
	]}
	"a code asked for again replaces the one before": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["send"], ["advance", 60000], ["send"], ["approve", "right"]]}], holds: {log: [{status: 200}, {status: 200}, {op: "approve", status: 200}]}},
	]}
	"the stand-in's reader route answers the last code for a number, and nothing for another": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: [["codes"], ["send"], ["codes"]]}], holds: {log: [{op: "codes", status: 404}, {op: "send"}, {op: "codes", status: 200, shape: "code"}]}},
	]}
	"the gate's refusal means no SMS, and the page is told too many; no answer, that it is down": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{gate: 403, sender: "capture", ops: [["send"]]}], holds: {log: [{status: 429, error: "too_many"}], gateCalls: 1, texts: []}},
		{call: "identity.otpFlow", args: [{gate: 429, sender: "capture", ops: [["send"]]}], holds: {log: [{status: 429, error: "too_many"}], texts: []}},
		{call: "identity.otpFlow", args: [{gate: 500, sender: "capture", ops: [["send"]]}], holds: {log: [{status: 503, error: "down"}], texts: []}},
		{call: "identity.otpFlow", args: [{gate: 0, sender: "capture", ops: [["send"]]}], holds: {log: [{status: 503, error: "down"}], texts: []}},
		{call: "identity.otpFlow", args: [{gate: 204, sender: "capture", ops: [["send"]]}], holds: {log: [{status: 200}], texts: [{text: "localhost:19000: seu código para entrar é CODE"}]}},
	]}
	"a send the sender fails leaves no wait and no code": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{sender: "fails", ops: [["send"], ["send"], ["approve", "123456"]]}], holds: {log: [{status: 503, error: "down"}, {status: 503, error: "down"}, {op: "approve", error: "expired"}]}},
	]}
	"the SMS is one short message in the page's language, with the code and the broker's name": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{sender: "capture", ops: [["send"]]}], holds: {texts: [{text: "localhost:19000: seu código para entrar é CODE", length: 48}]}},
		{call: "identity.otpFlow", args: [{sender: "capture", lang: "en", ops: [["send"]]}], holds: {texts: [{text: "localhost:19000: your sign-in code is CODE", length: 44}]}, why: "far under 70, one segment even as UCS-2 for the accent"},
	]}
	"the page in broker mode loads nothing of Google's and keeps its look": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{ops: []}], holds: {firebaseInPage: false, hasRecaptchaBox: false, config: ["admit", "id", "mode", "pattern", "resendSeconds", "strings"]}}, {keep: "out"},
		{use: "out"}, {get: "csp", expect: "default-src 'none'; script-src 'self'; connect-src 'self' https://app.example.com; style-src 'unsafe-inline'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"},
		{use: "out"}, {get: "script", holds: {firebase: false, sends: true, approves: true}},
	]}
	"a number outside the pattern is refused before the gate": {suite: "identity", steps: [
		{call: "identity.otpFlow", args: [{phone: "+14155550100", ops: [["send"]]}], holds: {log: [{status: 400, error: "region"}], gateCalls: 0}},
	]}
}
