// The release engine of a pronto app on Google Cloud (README.md, "The release engine"):
// release@gcp and verify@gcp for an app whose release.cue holds GCP: schema.#Release, Cloud Run
// beside Cloud SQL, its sidecars, previews, the rc gate and the local gate's ledger. It was the
// pronto fork's gcp/; the app now holds it, so the release no longer needs a runtime that carries
// it. Each file is written byte for byte as this directory holds it, with no header, so the app's
// copy and this one compare with cmp.
//
// The rules run before the runtime's own `gcp` rule and stop it (priority -1, stop), as an app's
// `launch@local` does: sayt unifies .say.json with the runtime's .say.yaml, so a rule of the same
// name could not replace it. PRONTO_RUNTIME tells the engine where the runtime the app pins is
// (runtime.nu), for the two things it still reads there: its version and the local gate's files.
@extern(embed)

package engine

import "encoding/json"

_release: _ @embed(file="release.nu", type=text)
_build:   _ @embed(file="build.nu", type=text)
_verify:  _ @embed(file="verify.nu", type=text)
_secrets: _ @embed(file="secrets.nu", type=text)
_gateKey: _ @embed(file="local-gate-key.nu", type=text)
_record:  _ @embed(file="release-record.nu", type=text)
_runtime: _ @embed(file="runtime.nu", type=text)
_schema:  _ @embed(file="schema/gcp.cue", type=text)

// The engine's files, from the app's root.
#Files: {
	"gcp/release.nu":        _release
	"gcp/build.nu":          _build
	"gcp/verify.nu":         _verify
	"gcp/secrets.nu":        _secrets
	"gcp/local-gate-key.nu": _gateKey
	"gcp/release-record.nu": _record
	"gcp/runtime.nu":        _runtime
	"gcp/schema/gcp.cue":    _schema
}

// sayt appends the verb's flags to a rule's last command, so the engine's call ends it.
_run: {
	#script: string
	out:     "use tools.nu [run-mise]; $env.PRONTO_RUNTIME = (run-mise where github:bonisoft3/pronto | str trim); run-mise exec -- nu \(#script)"
}

#Host: {
	rules: {
		release: "gcp-engine": {platform: "gcp", priority: -1, stop: true, cmds: [{do: (_run & {#script: "gcp/release.nu"}).out}]}
		verify: "gcp-engine": {platform: "gcp", priority: -1, stop: true, cmds: [{do: (_run & {#script: "gcp/verify.nu"}).out}]}
	}
	files: {
		for path, body in #Files {(path): {seed: false, text: body}}
		".say.json": {
			seed:  false
			merge: true
			text: json.Indent(json.Marshal({say: {for verb, rs in rules {(verb): rulemap: rs}}}), "", "  ") + "\n"
		}
	}
}
