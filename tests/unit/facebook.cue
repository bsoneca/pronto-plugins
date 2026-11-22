// The broker's Facebook sign-in (identity/broker/facebook.ts, PRONTO-449): a person is sent to Meta by a plain redirect with PKCE, the broker
// exchanges the code, asks Graph who they are and forgets the token; the tenant learns a pairwise subject and, when it asked, a name and a
// picture, never an e-mail; a tenant the operator did not list, or whose flag is off or unreadable, sends no one to Meta. Meta here is a
// stand-in that checks the secret, the verifier and the app-secret proof as Meta does (facebook.js).
package unit

import idspec "github.com/bsoneca/pronto-plugins/identity:identity"

cases: {
	"a Facebook sign-in gives the tenant a pairwise subject, a name and a picture it asked for, and never an e-mail or Facebook's id": {suite: "identity", steps: [
		{call: "fb.brokered"}, {keep: "out"},
		{get: "provider", expect: "facebook"},
		{use: "out"}, {get: "hasEmail", expect: false, why: "Graph answered with an address here; the broker neither asks for it nor passes it on"},
		{use: "out"}, {get: "hasFacebookId", expect: false, why: "the subject is the broker's pairwise one, not Facebook's app-scoped id"},
		{use: "out"}, {get: "name", expect: "Ana Souza"},
		{use: "out"}, {get: "picture", expect: "https://scontent.example/p.jpg"},
		{use: "out"}, {get: "aud", expect: "https://app.example.com"},
	]}
	"a tenant that asked for no profile learns neither a name nor a picture": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{scope: "openid"}]}, {keep: "out"},
		{get: "name", expect: null},
		{use: "out"}, {get: "picture", expect: null},
		{use: "out"}, {get: "me", expect: {fields: "id", proofOk: true, tokenOk: true, tokenInUrl: false}, why: "Graph is asked for the id alone, with the app-secret proof"},
	]}
	"the same person signs in as the same subject, and as another one in another tenant": {suite: "identity", steps: [
		{call: "fb.brokered"}, {get: "sub"}, {keep: "first"},
		{call: "fb.brokered"}, {get: "sub"}, {keep: "again"},
		{call: "fb.brokered", args: [{tenant: "https://other.example.com"}]}, {get: "sub"}, {keep: "other"},
		{call: "probe.distinct", args: [["$first", "$again", "$other"]], expect: 2, why: "first and again are one subject; the other tenant's is its own"},
	]}
	"the dialog is a plain redirect with a PKCE challenge, the public profile alone, and none of an OpenID provider's nonce or account chooser": {suite: "identity", steps: [
		{call: "fb.brokered"}, {get: "dialog", expect: {
			host:         "www.facebook.example"
			scope:        "public_profile"
			method:       "S256"
			challenge:    true
			nonce:        false
			prompt:       false
			verifier:     false
			redirect:     "https://id.example.com/callback/facebook"
			client:       "1234567890123"
			responseType: "code"
		}, why: "the verifier waits in the store: it is never in the URL the person's browser carries"},
	]}
	"Meta is asked to exchange the code with the secret and the verifier of this very leg": {suite: "identity", steps: [
		{call: "fb.brokered"}, {get: "exchange", expect: {id: "1234567890123", secretOk: true, codeOk: true, verifierOk: true, redirect: "https://id.example.com/callback/facebook"}},
	]}
	"a tenant the operator did not list is refused before the flag is asked or Meta is reached": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{tenant: "https://unlisted.example.com"}], expect: {refused: "unauthorized_client", flagAsked: [], metaCalls: 0}},
	]}
	"a tenant whose flag is off is refused, and nothing reaches Meta": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{flag: "off"}], holds: {refused: "unauthorized_client", metaCalls: 0}},
		{call: "fb.brokered", args: [{flag: "off"}], holds: {flagAsked: ["https://app.example.com/ofrep/v1/evaluate/flags/facebook_signin"]}, why: "the flag is the spec's: facebook_signin, asked at the tenant's own door"},
	]}
	"a flag that cannot be read or is not there refuses the sign-in with a page, never a redirect to Meta (it fails closed)": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{flag: "down"}], expect: {status: 503, flagAsked: ["https://app.example.com/ofrep/v1/evaluate/flags/facebook_signin"], metaCalls: 0}},
		{call: "fb.brokered", args: [{flag: "missing"}], expect: {status: 503, flagAsked: ["https://app.example.com/ofrep/v1/evaluate/flags/facebook_signin"], metaCalls: 0}},
	]}
	"the in-app browsers of Instagram and Facebook are sent to the dialog, not to their own browser": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Instagram 300.0.0.0.0"}], holds: {provider: "facebook"}},
		{call: "fb.brokered", args: [{ua: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/450.0.0.0.0;]"}], holds: {provider: "facebook"}},
	]}
	"a state that was changed on the way back is refused with a page, and Meta is never asked": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{tamper: true}], holds: {status: 400, metaCalls: 0}},
	]}
	"a person who declines, a Meta that fails or one that answers no id each end as access_denied for the tenant": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{meta: "denied"}], holds: {error: "access_denied", metaCalls: 0}},
		{call: "fb.brokered", args: [{meta: "exchange500"}], holds: {error: "access_denied"}},
		{call: "fb.brokered", args: [{meta: "noToken"}], holds: {error: "access_denied"}},
		{call: "fb.brokered", args: [{meta: "me403"}], holds: {error: "access_denied"}},
		{call: "fb.brokered", args: [{meta: "noId"}], holds: {error: "access_denied"}},
	]}
	"Graph failing at the network level is a refusal, and the person's token never reaches an error": {suite: "identity", steps: [
		{call: "fb.meUnreachable", expect: {refused: "Refused", leaked: false}},
		{call: "fb.brokered", holds: {me: {tokenOk: true, tokenInUrl: false, proofOk: true}}, why: "the token goes in an Authorization header, never in the URL"},
	]}
	"a callback made twice is refused the second time: the verifier is used once": {suite: "identity", steps: [
		{call: "fb.brokered", args: [{replay: true}], holds: {replayed: "access_denied"}},
	]}
	"Facebook's settings: none is no provider; an app id without its secret or tenants, or a secret that is not one, is an error that stops the broker": {suite: "identity", steps: [
		{call: "fb.unset", expect: {none: true}},
		{call: "fb.settings", holds: {appId: "1234567890123", tenants: ["https://app.example.com"]}},
		{call: "fb.settings", args: [{FACEBOOK_APP_SECRET: ""}], expect: {refused: "FACEBOOK_APP_ID needs FACEBOOK_APP_SECRET: the broker keeps the secret, the airlock does not hold it"}},
		{call: "fb.settings", args: [{FACEBOOK_TENANTS: ""}], holds: {refused: "FACEBOOK_APP_ID needs FACEBOOK_TENANTS: Meta's consent dialog shows one app name, so the operator lists the tenants that may offer it"}},
		{call: "fb.settings", args: [{FACEBOOK_APP_SECRET: "short"}], holds: {refused: "FACEBOOK_APP_SECRET is not an app secret (32 hex characters)"}},
		{call: "fb.settings", args: [{FACEBOOK_TOKEN_URL: "http://staging.example/token", FACEBOOK_TEST_ENDPOINTS: ""}], holds: {refused: "FACEBOOK_TOKEN_URL is not https: the app secret and people's tokens would go in the clear"}},
		{call: "fb.settings", args: [{FACEBOOK_APP_ID: "abc"}], holds: {refused: "FACEBOOK_APP_ID is Meta's app id, digits only (the public one)"}},
	]}
	"the app-secret proof is a hex HMAC of the token, different for another token": {suite: "identity", steps: [
		{call: "fb.proof", expect: {length: 64, hex: true, differs: true}},
	]}
	"facebook_spec.json is `cue export ./identity -e facebook`, and its endpoints name the pinned Graph version": {suite: "identity", steps: [
		{call: "fb.specFile", expect: idspec.facebook, why: "a change to one without the other fails here (and in ci)"},
		{call: "fb.specFile", holds: {graph: "v24.0", flag: "facebook_signin", pkce: true, refusesWebviews: false, permissions: ["public_profile"]}, why: "what the spec says today"},
	]}
	"a signed request is believed only when its HMAC verifies under the app secret, it names HMAC-SHA256 and a plain id, and it is not oversized": {suite: "identity", steps: [
		{call: "fb.signed", args: ["good"], expect: "1000000000001"},
		{call: "fb.signed", args: ["otherSecret"], expect: null, why: "another app's secret signs another app's requests"},
		{call: "fb.signed", args: ["algorithm"], expect: null},
		{call: "fb.signed", args: ["stale"], expect: null, why: "a request older than a week is no key to a deletion"},
		{call: "fb.signed", args: ["future"], expect: null},
		{call: "fb.signed", args: ["noIssued"], expect: null},
		{call: "fb.signed", args: ["noId"], expect: null},
		{call: "fb.signed", args: ["badId"], expect: null},
		{call: "fb.signed", args: ["oversized"], expect: null},
		{call: "fb.signed", args: ["noDot"], expect: null},
		{call: "fb.signed", args: ["twoDots"], expect: null},
		{call: "fb.signed", args: ["none"], expect: null},
		{call: "fb.signed", args: ["notBase64"], expect: null},
	]}
	"Meta's deauthorize callback answers 200 to a signed request, keeps nothing of the person, and refuses an unsigned one": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["deauthorize"], expect: {status: 200, body: {}, stored: null}},
		{call: "fb.callbacks", args: ["deauthorizeBad"], expect: {status: 400, body: {error: "not a signed request of this app"}}},
	]}
	"Meta's data-deletion callback records the pairwise subject of each listed tenant, never Facebook's id, and answers with a status page that shows no one's data": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["deletion"], holds: {status: 200, shape: ["confirmation_code", "url"], urlOk: true, codeLen: 22}},
		{call: "fb.callbacks", args: ["deletion"], holds: {at: 1795305600000, subjectsOk: true, wildcardSkipped: true}, why: "the entry with a port pattern has no subject to name"},
		{call: "fb.callbacks", args: ["deletion"], holds: {holdsFacebookId: false, pageHasId: false, loggedId: false}, why: "the record, the page and the log name no Facebook id"},
		{call: "fb.callbacks", args: ["deletion"], holds: {page: 200, pageHasDate: true, csp: "default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"}},
	]}
	"a deletion request for the same person twice in a minute is answered 429 the second time, and an unsigned one writes nothing": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["twice"], expect: {first: 200, second: 429}},
		{call: "fb.callbacks", args: ["deletionBad"], expect: {status: 400, body: {error: "not a signed request of this app"}}},
	]}
	"the deletion status page of a code that is not there, or not a code, is a 404; any other path is not Meta's": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["unknown"], expect: {status: 404}},
		{call: "fb.callbacks", args: ["badCode"], expect: {status: 404}},
		{call: "fb.callbacks", args: ["other"], expect: {routed: true}},
	]}
	"the same signed request again, after the rate window, is answered with the same code and adds no record; a deauthorize request is refused at the deletion callback": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["replay"], expect: {status: 200, sameCode: true, records: 1}},
		{call: "fb.callbacks", args: ["swap"], expect: {deauth: 200, deletion: 400, error: "this request was made for another callback"}},
	]}
	"a body past the limit is refused with a 413 before it is read whole": {suite: "identity", steps: [
		{call: "fb.callbacks", args: ["huge"], expect: {status: 413}},
	]}
}
