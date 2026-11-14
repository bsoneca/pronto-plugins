# runtime.nu: what the release engine takes from the pronto runtime the app pins, now that the
# engine is the app's own (pronto-plugins' gcp host, gcp/README.md): the runtime's directory, which
# the app's release rule puts in PRONTO_RUNTIME (mise's install of github:bonisoft3/pronto), and the
# one helper of its k8s release this engine calls, resolve-app, as upstream pronto has it.

# The pronto runtime's directory.
export def dir []: nothing -> string {
	let d = ($env.PRONTO_RUNTIME? | default "")
	if ($d | is-empty) {
		let found = (do { ^mise where github:bonisoft3/pronto } | complete)
		if $found.exit_code != 0 { error make {msg: "gcp: no pronto runtime: PRONTO_RUNTIME is unset and mise has no github:bonisoft3/pronto here"} }
		return ($found.stdout | str trim)
	}
	$d
}

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
		error make { msg: $"No release.cue for ($app_arg | default $env.PWD): run from an app directory or pass --app" }
	}
	{ name: ($dir | path basename), cue_path: $cue_path, dir: $dir }
}
