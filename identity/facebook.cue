package identity

import "strings"

// Facebook sign-in's facts, written once (PRONTO-449): the Graph version, Meta's three endpoints, the permission asked, the paths the broker
// serves and what the owner types into Meta's console. `cue export ./identity -e facebook --out json` writes identity/broker/facebook_spec.json,
// which the broker reads (broker/facebook.ts); ci fails when the committed file differs from the export. Behaviour (the redirect, the exchange,
// the Graph call) stays code.
//
//   cue export ./identity -e facebook --out json > identity/broker/facebook_spec.json
facebook: #Facebook & {
	label: "Facebook"
	// The Graph API version every URL below names: Meta retires each after about two years, so a bump is this one line.
	graph: "v24.0"
	// The flag a tenant turns Facebook sign-in on with (pronto-flags): asked when a sign-in begins, and a flag that cannot be read refuses it.
	flag: "facebook_signin"
	dialog: "https://www.facebook.com/\(graph)/dialog/oauth"
	token:  "https://graph.facebook.com/\(graph)/oauth/access_token"
	me:     "https://graph.facebook.com/\(graph)/me"
	// Only the public profile: Meta never says an address is verified, so e-mail is not asked, and public_profile needs no App Review.
	permissions: ["public_profile"]
	// What /me is asked for: the app-scoped id, and, when the tenant asked for a profile, the name and a picture.
	fields: {base: ["id"], profile: ["name", "picture.width(256).height(256)"]}
	// A plain redirect with PKCE: the verifier waits in the store under the leg, for the exchange.
	pkce: true
	// The in-app browsers of Facebook and Instagram open the dialog as any browser does: no "open in your browser" detour.
	refusesWebviews: false
	paths: {callback: "/callback/facebook"}
	limits: {
		// How long a PKCE verifier waits for its callback, in seconds.
		verifier_s: 600
		// The timeouts of the two calls the broker makes to Meta, in milliseconds.
		exchange_ms: 8000
		me_ms:       8000
	}
	// What the owner types into Meta's developer console, for the broker at `domain` and the site at `site` (the steps: README.md, "Facebook").
	console: {
		domain: *"id.example.com" | string
		site:   *"https://example.com" | string
		redirect_uris: ["https://\(domain)\(paths.callback)"]
		app_domains: [domain, strings.TrimPrefix(site, "https://")]
		privacy: "\(site)/privacy"
		terms:   "\(site)/terms"
	}
}

#Facebook: {
	label: string
	graph: =~"^v[0-9]+\\.[0-9]+$"
	flag:  =~"^[a-z][a-z0-9_]*$"
	dialog: =~"^https://www\\.facebook\\.com/v[0-9]+\\.[0-9]+/dialog/oauth$"
	token:  =~"^https://graph\\.facebook\\.com/v[0-9]+\\.[0-9]+/oauth/access_token$"
	me:     =~"^https://graph\\.facebook\\.com/v[0-9]+\\.[0-9]+/me$"
	permissions: [...string] & [string, ...string]
	fields: {base: [...string], profile: [...string]}
	pkce:            bool
	refusesWebviews: bool
	paths: callback: =~"^/callback/[a-z]+$"
	limits: {verifier_s: int & >0, exchange_ms: int & >0, me_ms: int & >0}
	console: {...}
}
