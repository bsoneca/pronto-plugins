// Errors: what an app's pages throw, reported to the operator's GlitchTip (a Sentry-protocol
// server, errors/metal.nu). The page's own small reporter (errors.js) sends each uncaught error,
// unhandled rejection and failed load to the app's door, which routes it to GlitchTip's ingest, so
// the page's policy (connect-src 'self') holds.
//
// This file is written into the app's own package (errors_plugin.cue), so every name here is
// prefixed: it sits beside the program's.
package errors

import "strings"

// What the app says of its project at GlitchTip. `project` and `key` are the ones `bin/pronto-errors
// metal` prints for the app's project; the key is public by design (every page sends it), so it
// is written here, not kept secret. Until both are written the reporter does nothing.
#Errors: E={
	// GlitchTip's id of the project, which the operator makes with `metal --projects`. 0: none yet.
	project: *0 | int & >=0
	// The project's public key: 32 hex digits. Empty: none yet.
	key: *"" | =~"^[0-9a-f]{32}$"
	// Where the door sends the reports in production; a host launch sends them to a stand-in. With a
	// `server`, its console's address.
	upstream: *"https://errors.invalid" | =~"^https://[a-z0-9.-]+(:[0-9]+)?$"

	// The GlitchTip the app's project lives on, when the app's operator runs it on a node of pronto's
	// envs.Metal (errors/metal.nu): `bin/pronto-errors metal <app-dir>` installs it there and makes the
	// app's project (`slug`), and the reports and the source maps' token come from it. Absent: GlitchTip
	// runs elsewhere, and `upstream` and `sourcemaps.token` are written by hand.
	server?: {
		// The node, as the app's envs.Metal names it: user@host.
		ssh!: =~"^[a-z0-9_.-]+@[a-z0-9.-]+$"
		// The cluster's kubeconfig on the node.
		kubeconfig!: string & !=""
		// GlitchTip's console, a proxied CNAME onto the node's tunnel.
		domain!:   =~"^[a-z0-9.-]+$"
		namespace: *"errors" | =~"^[a-z0-9-]+$"
	}
	if server != _|_ {
		upstream: "https://\(server.domain)"
		_serverToken: "ssh -o BatchMode=yes \(server.ssh) 'KUBECONFIG=\(server.kubeconfig) kubectl get secret upload -n \(server.namespace) -o jsonpath={.data.token} | base64 -d'"
		// What `bin/pronto-errors metal <app-dir>` reads.
		metal: {ssh: server.ssh, kubeconfig: server.kubeconfig, domain: server.domain, namespace: server.namespace, projects: [if slug != "" {slug}]}
	}
	_serverToken: *"" | string
	// The address the door takes the reports at on the page's own origin; GlitchTip's own paths
	// (`/api/<project>/envelope/`) follow it.
	prefix: *"/e" | =~"^/[a-z0-9_-]+$"
	// The pronto-flags flag (flags_spec.cue) that turns the reporter on.
	flag: *"error_tracking" | =~"^[a-z][a-z0-9_-]{0,63}$"

	// GlitchTip's organization and the project's slug, which a release's source maps are sent to.
	org:  *"pronto" | =~"^[a-z0-9_-]+$"
	slug: *"" | =~"^[a-z0-9_-]+$"
	// The source maps of the bundles the pages load, sent to GlitchTip after each release
	// (errors/sourcemaps.ts upload), so an error shows its original file, function and line. The maps
	// are never served: GlitchTip finds each by the debug ID its bundle carries (the build's
	// `errors/sourcemaps.ts inject`). Without files or a slug nothing is sent.
	sourcemaps: {
		// The bundles, from the app's root, as committed: what the release serves.
		files: [...string]
		// The command, run in the app's folder, that builds them again with their maps (`.js.map` beside
		// each) into the folder ERRORS_MAPS_OUT names, each at its path from the app's root there, and
		// unchanged otherwise.
		build: *"" | string
		// The command that prints the uploader's token (GlitchTip's `upload` Secret, which metal.nu
		// makes); its output is never shown. ERRORS_UPLOAD_TOKEN, when set, is used instead.
		token: *E._serverToken | string
	}

	// The acceptance the plugin's scenarios hold (tests/scenarios/errors_plugin.cue, written once the
	// project and the key are): on a host launch, a thrown error reaches the stand-in through the door;
	// in production, as the tester, the live server accepts one. `accepts` names the app's acceptance
	// ids, `tester` the production actor's name.
	scenarios: {
		accepts: [...string]
		tester: *"Tester" | string
	}
	// The host the reports go to, which a page must never ask for itself.
	_upstreamHost: strings.Split(strings.TrimPrefix(E.upstream, "https://"), ":")[0]

	// The files the generate step writes: the reporter's settings, beside its module, and what the
	// upload of the maps reads.
	out: {
		"errors.loader.json": {project: E.project, key: E.key, prefix: E.prefix, flag: E.flag}
		"errors.sourcemaps.json": {upstream: E.upstream, org: E.org, slug: E.slug, files: E.sourcemaps.files, build: E.sourcemaps.build, token: E.sourcemaps.token}
		if E.project != 0 && E.key != "" {
			"errors.scenarios.json": {
				(E.flag): {
					accepts: E.scenarios.accepts
					flags: [E.flag]
					actors: eli: name: "Eli"
					steps: [
						{by: "eli", open: "/?probe={run}", flag: E.flag},
						{by: "eli", response: {to: "\(E.prefix)/api/\(E.project)/envelope/", method: "POST", status: 200, matches: "\"id\"", sent: "\"release\":\"[0-9a-f]{12}\".*\"request\":\\{\"url\":\"https?://[^\"?#]+\"\\}", when: {throw: "scenario-throw-{run}"}}, why: "the uncaught error is one envelope to the door's own address, carrying its release and the page's path alone", flag: E.flag},
						{http: {path: "\(E.prefix)/api/events", anon: true, expect: {status: 200, has: ["scenario-throw-{run}", "\"type\":\"Error\"", "\"platform\":\"javascript\"", "\"level\":\"error\""], lacks: ["probe={run}", "\"user\"", "\"release\":\"unknown\""]}}, poll: true, why: "what the stand-in kept: the error's type and message, no query of the page's address, no user", flag: E.flag},
						{by: "eli", never: E._upstreamHost, why: "no address of another host was asked for: the reports go to the page's own origin", flag: E.flag},
					]
				}
				"\(E.flag)_tester": {
					accepts: E.scenarios.accepts
					flags: [E.flag]
					production: true
					actors: tess: name: E.scenarios.tester
					steps: [
						{by: "tess", open: "/", flag: E.flag},
						{by: "tess", signIn: true, flag: E.flag},
						{by: "tess", closeDialogs: true, flag: E.flag},
						{by: "tess", response: {to: "\(E.prefix)/api/\(E.project)/envelope/", method: "POST", status: 200, sent: "\"release\":\"[0-9a-f]{12}\"", when: {throw: "production check of \(E.flag) {run}"}}, timeout: 60, why: "the report reaches GlitchTip through the door, which answers 200", flag: E.flag},
					]
				}
			}
		}
	}
}
