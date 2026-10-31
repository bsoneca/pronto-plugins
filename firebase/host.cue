// The Firebase host: releases a pronto app's pages bundle to Firebase Hosting,
// on unmodified pronto. pronto 0.14.0 has no firebase target, so the app
// targets none and holds the host's generated files instead, as the Android
// host's apps do: rules sayt merges with pronto's .say.yaml, the CLI pinned in a
// mise drop-in, and the script that assembles the site.
@extern(embed)

package firebase

import "encoding/json"

_site: _ @embed(file="site.nu", type=text)

// The CLI from npm on a pinned Node: its standalone macOS binary is built for
// x86_64 alone, which an Apple Silicon machine without Rosetta cannot run.
#Tools: {
	node:            "22.12.0"
	"firebase-tools": "15.32.1"
}

#Host: H={
	app!:     string
	project!: string & =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
	// The Hosting site within the project; its default site when empty.
	site: *"" | (string & =~"^[a-z0-9][a-z0-9-]*$")
	// `sayt release` with no platform deploys this channel; it expires alone.
	channel: *"preview" | (string & =~"^[a-zA-Z0-9_-]{1,63}$")
	expires: *"7d" | (string & =~"^[0-9]+[hd]$")
	// A keyless deploy on the tag: a Workload Identity provider trusting the
	// repository and a service account holding Firebase Hosting Admin. Both or
	// neither; without them `release@firebase` deploys from this machine.
	ciProvider: *"" | (string & =~"^projects/[0-9]+/locations/global/workloadIdentityPools/[^/]+/providers/[^/]+$")
	ciAccount:  *"" | (string & =~"^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$")
	_ci:        H.ciProvider != "" && H.ciAccount != ""
	_ciPaired:  true & ((H.ciProvider == "") == (H.ciAccount == ""))

	_only: [if H.site != "" {"hosting:\(H.site)"}, "hosting"][0]
	_cli:  "use tools.nu [run-mise]; run-mise exec -- firebase"
	// pronto's pages bundle, as its `release@pages` runs it in an installed
	// app: dist/browser/index.html, at the site's root.
	_bundle: "use tools.nu [run-mise]; let pronto = (run-mise where github:bonisoft3/pronto | str trim); run-mise exec -- deno run -A --config ($pronto | path join bundle deno.json) ($pronto | path join bundle bundle.ts) . --omnishell (run-mise where github:bonisoft3/omnishell | str trim) --mecha (run-mise where github:bonisoft3/mecha | str trim) --out dist/browser --base \"\""
	// The hatches' files come from the program at each release; site.nu, a
	// module of the app's, cannot reach sayt's tools.nu, so the rule asks.
	_assemble: "use tools.nu [run-mise]; use ./firebase/site.nu; site (run-mise exec -- cue export . -e '[for _, h in code.capabilities.hatches if h.kind == \"host-dom\" for f in h.files {f}]' --out json)"
	_deploy:   "\(H._cli) deploy --only \(H._only) --project \(H.project) --non-interactive"
	_push:     "use semver.nu [tag-on-head]; let tag = (tag-on-head); if ($tag | is-empty) { error make {msg: \"no release tag on HEAD to push\"} }; git push origin $tag"
	_unlessSnapshot: {#do: string, out: "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { \(#do) }"}

	surface: {
		miseConf: """
			[tools]
			node = "\(#Tools.node)"
			"npm:firebase-tools" = "\(#Tools["firebase-tools"])"

			"""
		rules: release: {
			// sayt's own `release` rule runs its version ceremony on the verb's
			// default platform, preview, beside the preview below: a preview
			// would bump the version and tag it. The versioned rule runs the
			// ceremony itself, so the builtin is off.
			builtin: null
			// A published version: bundle, assemble, then sayt's ceremony
			// (version, tag), then live. With a CI identity the tag is the
			// deploy, as pronto's pages target does it; without, this machine
			// deploys, as its cloudflare target does. --snapshot stops after
			// the ceremony's dry run: built, assembled, nothing tagged or live.
			firebase: {
				platform: "firebase"
				cmds: [
					{do: H._bundle},
					{do: H._assemble},
					{do: "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { release --skip=validate --clean } else { release --snapshot --skip=validate --clean }", use: "./release.nu"},
					if !H._ci {{do: (H._unlessSnapshot & {#do: H._deploy}).out}},
					{do: (H._unlessSnapshot & {#do: H._push}).out},
				]
			}
			// A deploy, not a published version: the same site on an expiring
			// channel under sayt's default platform, no ceremony, no tag.
			"firebase-preview": {
				platform: "preview"
				cmds: [
					{do: H._bundle},
					{do: H._assemble},
					{do: "\(H._cli) hosting:channel:deploy \(H.channel) --project \(H.project)\([if H.site != "" {" --site \(H.site)"}, ""][0]) --expires \(H.expires) --non-interactive"},
				]
			}
		}
	}

	// What an app holds, by path from its root. `merge` files are JSON whose
	// keys this host owns beside other hosts' (sayt reads one .say.json); a
	// seeded file is written once and then the app's.
	files: {
		".say.json": {
			seed:  false
			merge: true
			text:  json.Indent(json.Marshal({say: {for verb, rs in H.surface.rules {(verb): rulemap: rs}}}), "", "  ") + "\n"
		}
		".config/mise/conf.d/firebase.toml": {seed: false, text: H.surface.miseConf}
		"firebase/site.nu": {seed: false, text: _site}
		// Hosting only: a project's Firestore, Storage, Auth and their rules
		// are the app's data and are never deployed from here. The app adds the
		// headers and redirects its own documents need.
		"firebase.json": {
			seed: true
			text: json.Indent(json.Marshal({hosting: {
				if H.site != "" {site: H.site}
				public: "dist/firebase"
				ignore: ["firebase.json", "**/.*", "**/node_modules/**"]
				rewrites: [{source: "**", destination: "/index.html"}]
			}}), "", "  ") + "\n"
		}
		// The ceremony runs goreleaser as a shim, builds and the GitHub release
		// off, as pronto's pages target configures it.
		".goreleaser.yaml": {
			seed: true
			text: """
				version: 2
				project_name: \(H.app)
				dist: dist/goreleaser
				builds:
				  - builder: zig
				    skip: true
				release:
				  disable: true
				changelog:
				  disable: true

				"""
		}
		if H._ci {
			".github/workflows/firebase.yml": {
				seed: false
				text: """
					# Release the app to Firebase Hosting: on the version tag `sayt release@firebase`
					# pushes, build the site as a developer would, a snapshot since the tag is the
					# release already, and deploy it as the service account the repository may
					# impersonate through Workload Identity: no key is stored anywhere.
					# Written by pronto-firebase; regenerated, do not edit.

					name: firebase

					on:
					  push:
					    tags:
					      - 'v*'
					  workflow_dispatch:

					permissions:
					  contents: read
					  id-token: write

					concurrency:
					  group: firebase
					  cancel-in-progress: false

					jobs:
					  deploy:
					    runs-on: ubuntu-24.04
					    steps:
					      - uses: actions/checkout@v7
					      - uses: bonisoft3/sayt/.github/actions/sayt/install@v0.44.1
					        with:
					          version: v0.44.1
					      - run: sayt setup
					      - run: sayt release@firebase --snapshot
					      - uses: google-github-actions/auth@v2
					        with:
					          workload_identity_provider: \(H.ciProvider)
					          service_account: \(H.ciAccount)
					      - run: sayt --script tools.nu mise exec -- firebase deploy --only \(H._only) --project \(H.project) --non-interactive

					"""
			}
		}
	}
}
