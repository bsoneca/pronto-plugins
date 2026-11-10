# An operator service's node Secret from a SOPS file (PRONTO-155), for identity/metal.nu and
# billing/metal.nu: `--secrets <file>`, full k8s Secret manifests encrypted for every age recipient
# in .sops.yaml (bsoneca/pronto's services/<service>/secrets.metal.enc.yaml, made by its
# tools/secrets/import.nu). Decrypted on the operator's Mac by that checkout's own
# tools/secrets/sops.nu, the one mechanism pronto's tools use (the sops release@k8s pins, the
# Keychain key pronto-sops-age); the plain manifests go only down a pipe, to the node's
# server-side apply, never to a file or an argument.

# The decrypted manifests, as YAML documents, from the pronto checkout that holds `file`.
export def decrypt [file: string]: nothing -> string {
	let file = ($file | path expand)
	if not ($file | path exists) { error make {msg: $"no ($file)"} }
	let root = (do { cd ($file | path dirname); ^git rev-parse --show-toplevel } | complete)
	if $root.exit_code != 0 { error make {msg: $"($file) is in no git checkout"} }
	let tool = ($root.stdout | str trim | path join tools secrets sops.nu)
	if not ($tool | path exists) { error make {msg: $"no ($tool): --secrets reads a file from a pronto checkout that has it"} }
	let r = (do { ^$nu.current-exe -c $"use ($tool) [decrypt]; decrypt ($file)" } | complete)
	if $r.exit_code != 0 { error make {msg: $"decrypt ($file): ($r.stderr | str trim)"} }
	$r.stdout
}

# The file's documents, held to what the service reads: Secrets only, one named `name` holding every
# key in `keys`, so a file that lost a key fails here, not as a pod that cannot start. Returns the
# YAML to apply, each Secret in `namespace`.
export def secret-manifests [name: string, namespace: string, keys: list<string>]: string -> string {
	let docs = ($in | split row --regex '(?m)^---\s*$' | where {|d| $d | str trim | is-not-empty } | each { from yaml })
	let odd = ($docs | where {|d| $d.kind? != "Secret" or $d.apiVersion? != "v1" })
	if ($odd | is-not-empty) { error make {msg: $"the secrets file holds something besides v1 Secrets: (($odd | each {|d| $'($d.kind?)/($d.metadata?.name?)' } | str join ', '))"} }
	let own = ($docs | where {|d| $d.metadata.name == $name })
	if ($own | length) != 1 { error make {msg: $"the secrets file holds (($own | length)) Secrets named ($name), not one"} }
	let held = (($own | first).data? | default {} | columns) ++ (($own | first).stringData? | default {} | columns)
	let missing = ($keys | where {|k| $k not-in $held })
	if ($missing | is-not-empty) { error make {msg: $"Secret ($name) lacks (($missing | str join ', '))"} }
	$docs | each {|d| $d | upsert metadata.namespace $namespace | to yaml } | str join "---\n"
}

# The node command that applies them: server-side, owned by pronto-sops as release@k8s's and
# pronto's tools/secrets/sops.nu apply-to-node are, so a Secret made by hand before is taken over.
export def apply-command [kubectl: string, namespace: string]: nothing -> string {
	$"($kubectl) apply -n ($namespace) --server-side --force-conflicts --field-manager=pronto-sops -f -"
}
