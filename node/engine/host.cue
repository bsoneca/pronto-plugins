// The release engine of a pronto app on the Contabo node (README.md, "The node release engine"):
// release@k8s for an app whose release.cue holds Node: node.#Release, upstream pronto's manifests
// patched and released to the node's k3s over an ssh tunnel, the images built in Cloud Build. Each
// file is written byte for byte as this directory holds it, with no header, so the app's copy and
// this one compare with cmp. build.nu is gcp/engine/build.nu (a symlink here: one build, one source,
// and pronto's harness.sh compares both copies).
//
// The rule runs before the runtime's own `k8s` rule and stops it (priority -1, stop), as the gcp
// engine's does: sayt unifies .say.json with the runtime's .say.yaml, so a rule of the same name
// could not replace it. PRONTO_RUNTIME tells the engine where the runtime the app pins is
// (runtime.nu), for the six helpers of its k8s release it calls.
@extern(embed)

package engine

import "encoding/json"

_release:  _ @embed(file="release.nu", type=text)
_render:   _ @embed(file="render.nu", type=text)
_runtime:  _ @embed(file="runtime.nu", type=text)
_build:    _ @embed(file="build.nu", type=text)
_tunnel:   _ @embed(file="tunnel.nu", type=text)
_rollback: _ @embed(file="rollback.nu", type=text)
_restore:  _ @embed(file="restore.nu", type=text)
_schema:   _ @embed(file="schema/node.cue", type=text)

// The engine's files, from the app's root.
#Files: {
	"node/release.nu":      _release
	"node/render.nu":       _render
	"node/runtime.nu":      _runtime
	"node/build.nu":        _build
	"node/tunnel.nu":       _tunnel
	"node/rollback.nu":     _rollback
	"node/restore.nu":      _restore
	"node/schema/node.cue": _schema
}

// sayt appends the verb's flags to a rule's last command, so the engine's call ends it.
_run: {
	#script: string
	out:     "use tools.nu [run-mise]; $env.PRONTO_RUNTIME = (run-mise where github:bonisoft3/pronto | str trim); run-mise exec -- nu \(#script)"
}

#Host: {
	rules: {
		release: "node-engine": {platform: "k8s", priority: -1, stop: true, cmds: [{do: (_run & {#script: "node/release.nu"}).out}]}
	}
	files: {
		for path, body in #Files {(path): {seed: false, text: body}}
		".say.json": {
			seed:  false
			merge: true
			text:  json.Indent(json.Marshal({say: {for verb, rs in rules {(verb): rulemap: rs}}}), "", "  ") + "\n"
		}
	}
}
