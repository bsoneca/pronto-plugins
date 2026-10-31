// The Google Cloud host: releases a pronto app's door to Cloud Run, on
// unmodified pronto. pronto 0.14.0 admits `gcp` in #Target and builds no rule
// for it (its PENDING.md: "gcp has no rule"), so the app holds this host's
// files instead, as the Firebase host's apps do: release rules sayt merges with
// pronto's .say.yaml, the CLI pinned in a mise drop-in, and the module that
// builds, checks and deploys the image.
//
// The image is the door `sayt launch` runs, built from bayt's own definition
// of it for Cloud Run's linux/amd64, without the developer's certificates, and
// served on :8080, the port Cloud Run forwards to. A door alone carries an app
// whose rows the browser keeps; an app with server rows or auth needs Cloud SQL
// and the services beside the door, which this host refuses until it builds them.
@extern(embed)

package gcp

import "encoding/json"

_module: _ @embed(file="gcp.nu", type=text)

// gcloud's installer and its commands run on Python 3.10 or newer, which
// macOS does not have: a pinned one, put on gcloud's PATH as it installs.
#Tools: {
	python: "3.12.11"
	gcloud: "589.0.0"
}

#Host: H={
	app!:     string
	project!: string & =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
	region:   *"us-central1" | (string & =~"^[a-z]+-[a-z]+[0-9]$")
	// The Cloud Run service; `<service>-preview` holds plain `sayt release`.
	service: *H.app | (string & =~"^[a-z]([a-z0-9-]{0,47}[a-z0-9])?$")
	// The Artifact Registry repository the images go to, in the region.
	repository: *"pronto" | (string & =~"^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")
	// The address readers reach the door at, which the door must be told
	// (ORIGIN). Empty: the service's own run.app address.
	origin:    *"" | (string & =~"^https://[A-Za-z0-9.-]+$")
	maxScale:  *3 | (int & >=1 & <=100)
	memory:    *"512Mi" | (string & =~"^[0-9]+(Mi|Gi)$")

	_args:  "--project \(H.project) --region \(H.region) --repository \(H.repository) --max-scale \(H.maxScale) --memory \(H.memory)\([if H.origin != "" {" --origin \(H.origin)"}, ""][0])"
	_use:   "use ./gcp/gcp.nu"
	_image: "use ./gcp/gcp.nu; gcp image \(H.app)"
	_push:  "use semver.nu [tag-on-head]; let tag = (tag-on-head); if ($tag | is-empty) { error make {msg: \"no release tag on HEAD to push\"} }; git push origin $tag"
	_unlessSnapshot: {#do: string, out: "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { \(#do) }"}

	surface: {
		miseConf: """
			[tools]
			python = "\(#Tools.python)"
			gcloud = { version = "\(#Tools.gcloud)", depends = ["python"] }

			"""
		rules: release: {
			// sayt's own `release` rule runs its version ceremony on the verb's
			// default platform, preview, beside the preview below: a preview
			// would bump the version and tag it. The versioned rule runs the
			// ceremony itself, so the builtin is off.
			builtin: null
			// A published version: the image built and checked, sayt's ceremony
			// (version, tag), then the image pushed under the version and the
			// service moved to it by digest. --snapshot stops after the
			// ceremony's dry run: built and checked, nothing tagged or live.
			gcp: {
				platform: "gcp"
				cmds: [
					{do: H._image},
					{do: "if ($env.SAY_RELEASE_ARGS_SNAPSHOT? | is-empty) { release --skip=validate --clean } else { release --snapshot --skip=validate --clean }", use: "./release.nu"},
					{do: (H._unlessSnapshot & {#do: "use semver.nu [tag-on-head]; \(H._use); gcp deploy \(H.app) \(H.service) (tag-on-head | path basename) \(H._args)"}).out},
					{do: (H._unlessSnapshot & {#do: H._push}).out},
				]
			}
			// A deploy, not a published version: the same image on its own
			// service, scaling to zero, no ceremony and no tag.
			"gcp-preview": {
				platform: "preview"
				cmds: [
					{do: H._image},
					{do: "\(H._use); gcp deploy \(H.app) \(H.service)-preview preview \(H._args)"},
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
		".config/mise/conf.d/gcp.toml": {seed: false, text: H.surface.miseConf}
		"gcp/gcp.nu": {seed: false, text: _module}
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
	}
}
