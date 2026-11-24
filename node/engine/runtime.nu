# runtime.nu: what the node release engine takes from the pronto runtime the app pins (upstream
# bonisoft3/pronto, installed by mise as github:bonisoft3/pronto): its directory, resolve-app, and the
# six helpers of its k8s release that are pure (a record in, a record out) and that the engine calls
# rather than copies, so the release data it hands the schema is upstream's own:
#
#   runtime-services, auth-provider-environment, release-tree, roles-reconciled   k8s/release.nu
#   run-job                                                                        k8s/release.nu
#   fresh-schema-runtime                                                           release-schema.nu
#
# Each runs in a nushell of its own that `use`s it by name, so a pin that renames or drops one fails
# there, at its first call, naming it; the contract test (contract_test.nu) fails on a change of what
# one answers. That list is the whole nushell dependency on upstream.

# Where each export lives, from the runtime's root.
const exports = {
	runtime-services: "k8s/release.nu"
	auth-provider-environment: "k8s/release.nu"
	release-tree: "k8s/release.nu"
	roles-reconciled: "k8s/release.nu"
	run-job: "k8s/release.nu"
	fresh-schema-runtime: "release-schema.nu"
}

# The pronto runtimes (the tool an app's mise pins, which lags the module its CUE pins by a release) this
# engine runs under. The last is the module contract_test.nu renders with; its runtime is the tool that
# module's distribution config names, and the test holds that its release.nu and release-schema.nu are
# the module's. 1.5.0, 1.5.1 and 1.6.0 carry the same two files. A release under another runtime is refused
# in its preflight, so a pin moves here first.
# 1.10.0 is the tool module v1.10.1 names, and 1.10.1 the tool an app's mise may pin beside it (the two carry the same files).
# 1.11.0 is the tool module v1.11.1 names, and 1.11.1 the tool an app's mise may pin beside it (k8s/release.nu and release-schema.nu are the same files as 1.10.1's).
export const validated_pins = ["1.5.0", "1.5.1", "1.6.0", "1.7.0", "1.10.0", "1.10.1", "1.11.0", "1.11.1"]

# The pronto runtime's directory: PRONTO_RUNTIME (the app's release rule sets it from mise), else mise's.
export def dir []: nothing -> string {
	let d = ($env.PRONTO_RUNTIME? | default "")
	if ($d | is-empty) {
		let found = (do { ^mise where github:bonisoft3/pronto } | complete)
		if $found.exit_code != 0 { error make {msg: "node: no pronto runtime: PRONTO_RUNTIME is unset and mise has no github:bonisoft3/pronto here"} }
		return ($found.stdout | str trim)
	}
	$d
}

# The runtime's version, as mise installed it (the directory's name), for the release's record.
export def version []: nothing -> string { dir | path basename }

export def resolve-app [app_arg?: string]: nothing -> record {
	let dir = if ($app_arg | is-empty) {
		$env.PWD
	} else if ($app_arg | path join "release.cue" | path exists) {
		$app_arg | path expand
	} else {
		# By name, inside the monorepo.
		git rev-parse --show-toplevel | str trim | path join "apps" $app_arg
	}
	let cue_path = ($dir | path join "release.cue")
	if not ($cue_path | path exists) {
		error make {msg: $"No release.cue for ($app_arg | default $env.PWD): run from an app directory or pass --app"}
	}
	{name: ($dir | path basename), cue_path: $cue_path, dir: $dir}
}

# A call of one of the six: `body` is nushell that reads the JSON payload as $p and writes JSON.
def call [fn: string, body: string, payload: any]: nothing -> any {
	let file = ($exports | get -o $fn)
	if $file == null { error make {msg: $"node: ($fn) is not among the upstream exports the engine imports"} }
	let f = (mktemp -t node-upstream.XXXXXX | str trim)
	$payload | to json | save -f $f
	let script = $"use '((dir) | path join $file)' [($fn)]; let p = \(open --raw '($f)' | from json\); ($body)"
	let r = (^$nu.current-exe --no-config-file -c $script | complete)
	rm -f $f
	if $r.exit_code != 0 { error make {msg: $"upstream ($fn) failed: ($r.stderr | str trim)"} }
	$r
}

# upstream's runtime-services: the services of the compose project the release runs, with their environment.
export def runtime-services [compose: record]: nothing -> record {
	(call runtime-services 'runtime-services $p | to json' $compose).stdout | from json
}

# upstream's auth-provider-environment: the OIDC settings, secrets and their digest of the auth service's environment.
# From 1.10 upstream's second argument is the list of provider names the program offers; before, the record of
# each provider's release settings (`release-providers` of render.nu hands the shape the runtime reads).
export def auth-provider-environment [environment: record, release_providers: any]: nothing -> record {
	(call auth-provider-environment 'auth-provider-environment $p.environment $p.providers | to json' {environment: $environment, providers: $release_providers}).stdout | from json
}

# The expression that reads the providers the program offers, when the runtime has it (1.10 on): else null.
export def program-providers-expr []: nothing -> any {
	let r = (^$nu.current-exe --no-config-file -c $"use '((dir) | path join k8s release.nu)' [PROGRAM_PROVIDERS]; print $PROGRAM_PROVIDERS" | complete)
	if $r.exit_code == 0 { $r.stdout | str trim } else { null }
}

# upstream's release-tree: the compose project (YAML text) with the door's tree as a release ships it.
export def release-tree [compose: string]: nothing -> string {
	(call release-tree '$p | release-tree' $compose).stdout
}

# upstream's roles-reconciled: whether CloudNativePG's managedRolesStatus has the roles the release needs.
export def roles-reconciled [roles: record]: nothing -> bool {
	(call roles-reconciled 'roles-reconciled $p | to json' $roles).stdout | from json
}

# upstream's fresh-schema-runtime: crud's Deployment (YAML text) with an annotation that rolls it.
export def fresh-schema-runtime [manifest: string]: nothing -> string {
	(call fresh-schema-runtime 'fresh-schema-runtime $p | to json' $manifest).stdout | from json
}

# upstream's run-job: a schema Job to completion, its logs the error when it fails (kubectl, in this environment).
export def run-job [manifest: string, name: string, namespace: string, --timeout-s: int = 600] {
	let r = (call run-job 'run-job $p.manifest $p.name $p.namespace --timeout-s $p.timeout; print "ok"' {manifest: $manifest, name: $name, namespace: $namespace, timeout: $timeout_s})
	print ($r.stdout | str replace -r "ok\\s*$" "" | str trim --right)
}
