// The infra host: an operator's Google Cloud state in CUE, applied by OpenTofu. The operator
// keeps one folder (`infra/`, say) in their own repository: this host writes its verbs
// (setup, generate, lint, verify@infra, release@infra), its tool pins, and a state file to
// start from; the schema and the OpenTofu export stay in this module and are imported.
@extern(embed)

package infra

_verbs: _ @embed(file="say.cue.txt", type=text)

// The CUE and OpenTofu pins. gcloud is the operator's own, where their login is: it makes the
// bucket OpenTofu keeps its state in, and hands OpenTofu a token.
#Tools: {
	cue:      "0.16.1"
	opentofu: "1.13.2"
}

#Host: {
	// The state folder's CUE module, which imports this module for the schema.
	module!: string & =~"^[a-z0-9.-]+(/[a-z0-9._-]+)*@v0$"
	// The bucket OpenTofu keeps its own state in, and the project that holds it.
	bucket!:  #BucketName
	project!: #ProjectID

	files: {
		".say.cue": {seed: false, text: _verbs}
		".mise.toml": {
			seed: false
			text: """
				[tools]
				"github:cue-lang/cue" = "\(#Tools.cue)"
				opentofu = "\(#Tools.opentofu)"

				"""
		}
		".gitignore": {
			seed: false
			text: """
				# Written by generate (cue export -e plan.tofu) and by verify@infra (the plan release@infra applies).
				tofu/main.tf.json
				tofu/*.tfplan*
				tofu/.terraform/

				"""
		}
		"cue.mod/module.cue": {
			seed: true
			text: """
				module: "\(module)"
				language: version: "v0.16.1"

				"""
		}
		// The state starts with its backend and no project: the operator adds each.
		"state.cue": {
			seed: true
			text: """
				package state

				import "github.com/bsoneca/pronto-plugins/infra"

				plan: infra.#Plan & {
					backend: {bucket: "\(bucket)", project: "\(project)"}
					state: projects: {}
				}

				"""
		}
	}
}
