# An operator service's node Secret from a SOPS file (PRONTO-155), for identity/metal.nu and
# billing/metal.nu: `--secrets <dir>/secrets.metal.enc.yaml`, full k8s Secret manifests encrypted
# for every age recipient in .sops.yaml (bsoneca/pronto's services/<service>/, made by its
# tools/secrets/import.nu). Decrypted here, on the operator's Mac, with the sops and the age key
# pronto's release@k8s uses (k8s/release.nu sops-bin and sops-age-key: the Keychain item
# pronto-sops-age), of the pronto `mise where` finds from the file's folder; the plain manifests go
# only down a pipe, to the node's server-side apply, never to a file or an argument.

# The pronto whose k8s/release.nu decrypts `file`: the one pinned where the file lives.
def pronto-for [file: string]: nothing -> string {
	let mise = (which mise | get -o 0.path | default (
		glob ($env.HOME | path join "Library/Caches/sayt/mise-*/mise") | append (glob ($env.HOME | path join ".cache/sayt/mise-*/mise")) | sort | last))
	let r = (do { cd ($file | path dirname); ^$mise where github:bonisoft3/pronto } | complete)
	if $r.exit_code != 0 { error make {msg: $"no pronto pinned for ($file): ($r.stderr | str trim)"} }
	$r.stdout | str trim
}

# The decrypted manifests, as YAML documents: the age key stays inside the one nu that decrypts.
export def decrypt [file: string]: nothing -> string {
	let file = ($file | path expand)
	if not ($file | path exists) { error make {msg: $"no ($file)"} }
	let pronto = (pronto-for $file)
	let r = (do { ^$nu.current-exe -c $"use ($pronto)/k8s/release.nu [sops-bin sops-age-key]; with-env {SOPS_AGE_KEY: \(sops-age-key\)} { ^\(sops-bin\) -d --output-type yaml ($file) }" } | complete)
	if $r.exit_code != 0 { error make {msg: $"sops -d ($file): ($r.stderr | str trim)"} }
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

# The node command that applies them: server-side, owned by pronto-sops as release@k8s's are, so a
# Secret made by hand before is taken over, not refused.
export def apply-command [kubectl: string, namespace: string]: nothing -> string {
	$"($kubectl) apply -n ($namespace) --server-side --force-conflicts --field-manager=pronto-sops -f -"
}
