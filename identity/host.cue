// The identity host: sign-in through the identity broker beside the passkey,
// on mecha's own auth service. The operator runs one broker (broker/main.ts)
// in front of the social providers, registered once; an application gets it
// with no client, secret or console of its own.
//
// mecha's auth service signs in through any OpenID issuer a deployment puts in
// a provider's place (mecha's services/auth/README.md#provider-sign-in), so the
// application side is configuration alone: the program names the providers
// (pronto's capabilities.auth.providers), the terminal draws their way in, and
// the program's settings for each (capabilities.auth.provider) tell the auth
// service the broker stands in its place, as defaults a deployment overrides
// with its own broker. No code of this plugin runs in the application.
//
// Each application is its own tenant: its client id is its origin, its one
// redirect per provider that origin's /auth/oidc/<provider>/callback, and the
// subject the broker vouches for is pairwise, so no two applications share a
// user.
package identity

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"
)

#Url: string & =~"^https?://[A-Za-z0-9.-]+(:[0-9]+)?$"

#Host: H={
	// The app's CUE package, which identity_signin.cue joins.
	package!: string & =~"^[a-z][a-z0-9_]*$"
	// The port of the broker a local launch runs, which is its issuer's: one
	// per app, hashed from its package as bayt hashes a launch's other ports
	// (below 32768, out of the ephemeral range), so one app's launch never
	// holds another's. Fixed rather than moved by a variable, since the
	// issuer is a literal to mecha's auth service; Hydra's own ports move.
	localPort: *(10000 + mod(strconv.ParseInt(strings.SliceRunes(hex.Encode(sha256.Sum256("pronto-identity/\(H.package)")), 0, 8), 16, 64), 22768)) | int & >=1024 & <65536
	// The broker as readers reach it, which is also its issuer: the
	// local one by default, so an application names nothing.
	broker: *"http://localhost:\(H.localPort)" | #Url
	// The broker as the cluster reaches it: the local broker's service (the
	// targets below) by its name in compose, which the host projection reads as loopback. The
	// slash ends the port where bayt's rewrite looks for an end (the auth
	// service drops it): inside a `${VAR:-…}` default, `}` would follow.
	brokerInternal: *[if H._local {"http://identity:\(H.localPort)/"}, H.broker][0] | #Url | =~"^https?://[A-Za-z0-9.-]+(:[0-9]+)?/$"
	// The broker's release: the front's image, the operator's own, pinned by
	// digest as publish.sh prints it, which a docker launch runs and from which
	// a local launch takes the files it runs on the host (hydra/local.sh); its
	// version is the runtime. It has no default: an app whose broker a local
	// launch runs names it (bin/pronto-identity frontImage=…), and one that
	// signs in through a broker elsewhere needs none. Then Hydra's.
	frontImage: string & =~"^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$"
	runtime:    regexp.FindSubmatch(":([0-9]+\\.[0-9]+\\.[0-9]+)@", frontImage)[1]
	// Where a local launch keeps the image's files: by its version and its digest, so another
	// image of the same version (another registry's, or republished) is taken afresh.
	cacheKey: "\(runtime)-\(regexp.FindSubmatch("@sha256:([0-9a-f]{16})", frontImage)[1])"
	hydraImage: "oryd/hydra:v26.2.0@sha256:ff67c7fb5f95074fa53374d41151713554960504b340cd3f95b09e65deaea2a9"
	// What the app asks the broker for, each provider alike: a subject
	// (openid), the person's name and picture (profile) and their verified
	// e-mail (email); only what it asks for arrives.
	scope: *"openid profile" | string & =~"^openid( (profile|email))*$"
	// The providers the app offers, each one the broker offers.
	providers: *["google"] | [string & =~"^[a-z][a-z0-9]*$", ...string & =~"^[a-z][a-z0-9]*$"]

	// The local broker's targets, when the app signs in through the broker a
	// local launch runs (the default broker): an operator's broker elsewhere
	// is that operator's to run.
	_local: H.broker == "http://localhost:\(H.localPort)"
	// On the host, each of the two takes the image's /app once per release
	// into the user's cache (crane), then runs
	// hydra/local.sh from there. Quoted for the generated file's strings.
	_crane: "mise x github:google/go-containerregistry[bin=crane]@v0.20.2 --"
	_fromImage: {
		let q = "\\\""
		for mode in ["hydra", "front"] {(mode): "d=\(q)${XDG_CACHE_HOME:-$HOME/.cache}/pronto-identity/\(H.cacheKey)\(q); [ -f \(q)$d/hydra/local.sh\(q) ] || { t=$(mktemp -d) && crane export --platform linux/amd64 \(H.frontImage) - | tar -xf - -C \(q)$t\(q) app && mkdir -p \(q)${d%/*}\(q) && { [ -f \(q)$d/hydra/local.sh\(q) ] || mv \(q)$t/app\(q) \(q)$d\(q); }; }; exec sh \(q)$d/hydra/local.sh\(q) \(mode)"}
	}
	_localTargets: [if H._local {"""
		// The broker itself, for a local test: Hydra and the front as two of
		// the cluster's own services, from pronto-identity's image. On the
		// host (launch@local) each runs hydra/local.sh from its files, which signs in through
		// Google with the operator's ~/.config/pronto-identity/broker.env and
		// through a stand-in that signs in test people without it; in docker
		// (launch) each runs its image, the stand-in unless GOOGLE_CLIENT_ID
		// and GOOGLE_CLIENT_SECRET are set. A release names the operator's
		// broker instead.
		cluster: surface: targets: {
			// A docker launch brings up what its aggregate waits on, which is
			// mecha's plane alone: the broker joins it.
			launch: compose: depends_on: identity: {condition: "service_healthy", restart: true}
			"identity-hydra": bayt.healthcheck.http & {
				cmd: builtin: null
				activate: ""
				healthcheck: url: "http://127.0.0.1:28453/health/ready"
				// Per app on the host, each moved by its variable, as every
				// other port of a launch: the front names them as its peer's.
				expose: {public: {port: 28453, env: "SERVE_PUBLIC_PORT"}, admin: {port: 28455, env: "SERVE_ADMIN_PORT"}}
				"process-compose": activate: "\(H._crane)"
				entrypoint: {
					do:    "\(H._fromImage["hydra"])"
					shell: "sh"
					dockerfile: {do: "hydra serve all --dev", shell: "exec"}
					env: compose.environment
				}
				dockerfile: from: name: "\(H.hydraImage)"
				compose: environment: {
					DSN:            "memory"
					SECRETS_SYSTEM: "pronto-identity-local-launch-hydra-0000"
					LOG_LEVEL:      "warn"
					URLS_SELF_ISSUER: "\(H.broker)"
					URLS_LOGIN:       "\(H.broker)/login"
					URLS_CONSENT:     "\(H.broker)/consent"
					OAUTH2_PKCE_ENFORCED_FOR_PUBLIC_CLIENTS: "true"
					TTL_ID_TOKEN: "5m"
				}
			}
			identity: bayt.healthcheck.http & {
				cmd: builtin: null
				activate: ""
				healthcheck: url: "http://127.0.0.1:\(H.localPort)/health"
				// The broker's issuer, which the browser and Google's redirect name.
				expose: http: port: \(H.localPort)
				"process-compose": activate: "\(H._crane)"
				entrypoint: {
					do:    "\(H._fromImage["front"])"
					shell: "sh"
					dockerfile: {do: "deno run --no-config --allow-net --allow-env /app/hydra/front.ts", shell: "exec"}
					env:   compose.environment
					after: "identity-hydra": "healthy"
				}
				dockerfile: from: name: "\(H.frontImage)"
				compose: {
					ports: ["\(H.localPort):\(H.localPort)"]
					environment: {
						BROKER_ISSUER:        "\(H.broker)"
						BROKER_SECRET:        "${BROKER_SECRET:-pronto-identity-local-launch-secret-0000}"
						BROKER_FAKE_GOOGLE:   "1"
						GOOGLE_CLIENT_ID:     "${GOOGLE_CLIENT_ID:-}"
						GOOGLE_CLIENT_SECRET: "${GOOGLE_CLIENT_SECRET:-}"
						HYDRA_PUBLIC:         "http://identity-hydra:28453"
						HYDRA_ADMIN:          "http://identity-hydra:28455"
						PORT:                 "\(H.localPort)"
					}
				}
			}
		}
		"""}, ""][0]

	_header: "// generated by pronto-identity from identity/host.cue — do not edit\n"

	files: {
		// Not identity.cue: sayt vets a file against the directory of its name.
		"identity_signin.cue": {
			seed: false
			text: H._header + """
				package \(H.package)

				\([if H._local {"import bayt \"github.com/bonisoft3/bayt/core:bayt\"\n"}, ""][0])

				// Sign-in through the broker is the auth plane's own: there is none
				// without it. Each provider's settings put the broker in its place.
				_identityNeedsAuth: code.capabilities.auth.service & "/auth"
				code: capabilities: auth: providers: [\(strings.Join([for p in H.providers {"\"\(p)\""}], ", "))]
				\(strings.Join([for p in H.providers {"code: capabilities: auth: provider: \(p): {issuer: \"\(H.broker)\", internal: \"\(H.brokerInternal)\", client: \"origin\", scope: \"\(H.scope)\", params: \"provider=\(p)\"}"}], "\n"))

				\(H._localTargets)
				"""
		}
	}

	// What this host once wrote: mecha's auth service wrapped, its image and
	// its hatch, then the broker's address as mise's environment, which a
	// compose nested in a container never saw. The writer takes each away
	// while its first line carries removeMark, so a file the app made its own
	// stays.
	remove: ["identity_hatch.cue", "identity/auth/main.ts", "identity/auth/identity_core.ts", "identity/auth/identity_page.ts", "identity/auth/oidc.ts", "identity/broker.env", "pronto/identity.cue"]
	removeMark: "generated by pronto-identity"
}
