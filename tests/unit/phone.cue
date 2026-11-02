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
}
