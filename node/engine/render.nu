# render.nu: the release data and the manifests of a node release. It does what upstream's
# k8s/release.nu does between reading the app and applying it (its render-manifests and the data its
# `main` unifies into the release package), with the six pure helpers imported from upstream
# (runtime.nu) and the rendering by CUE: upstream's #BuildManifests, over the engine's patches
# (schema/node.cue), exported as `nodeManifests` from the app's release.cue.

use runtime.nu [runtime-services auth-provider-environment]

# `docker compose config`'s project for the app, as JSON, read with no seal key in the environment
# so the airlock's shows the local stack's default, the development key a release refuses.
export def compose-config [dir: string]: nothing -> record {
	let r = (do { hide-env -i AIRLOCK_SEAL_KEY AIRLOCK_SEAL_KEY_PREVIOUS; cd ($dir | path expand); ^docker compose --profile "*" config --format json } | complete)
	if $r.exit_code != 0 { error make {msg: $"docker compose config failed in ($dir): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The app's facts, as generate wrote them.
export def facts [dir: string]: nothing -> record {
	let path = ($dir | path join .pronto cluster.json)
	if not ($path | path exists) { error make {msg: $"($path) is missing: generate the app before releasing it"} }
	let facts = (open $path)
	if not $facts.server { error make {msg: $"($path): this app has no server tier to release to Kubernetes"} }
	$facts
}

# What the engine does not reproduce yet, and says so before anything is built or written: the
# airlock and a trusted issuer's keys need cluster writes beyond the release data.
export def refusals [compose: record]: nothing -> list<string> {
	[
		(if "airlock" in ($compose.services | columns) { "the app's compose project runs the airlock, which the node engine does not release yet" })
		(if ($env.TRUSTED_JWKS? | default "" | is-not-empty) { "TRUSTED_JWKS is set, which the node engine does not apply yet" })
	] | compact
}

# The CUE a release.cue gives for the app's name, namespace and image, and its render choice,
# under the preview (a `-t preview=` tag).
def tags [preview: string]: nothing -> list<string> {
	if ($preview | is-empty) { [] } else { [-t $"preview=($preview)"] }
}

def cue-export [cue_path: string, expr: string, preview: string, ...more: string]: nothing -> any {
	let r = (do { cd ($cue_path | path dirname); ^cue export --expression $expr --out json ...(tags $preview) ($cue_path | path basename) ...$more } | complete)
	if $r.exit_code != 0 { error make {msg: $"($cue_path): ($expr): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The release's own settings (its Node), and the app's metadata, as release.cue states them.
export def node-config [cue_path: string, preview: string]: nothing -> record { cue-export $cue_path "Node" $preview }
export def app-meta [cue_path: string, preview: string]: nothing -> record {
	cue-export $cue_path "{name: App.name, namespace: App.namespace, type: App.type, image: App.image, render: App.render}" $preview
}

# The services whose images the release builds: the runtime's, the base five, migrate and render
# where the project has them (as upstream's main builds them).
export def build-services [compose: record, has_render: bool]: nothing -> list<string> {
	let names = ($compose.services | columns)
	(runtime-names $compose) | append [database crud electric auth caddy]
		| append (if "migrate" in $names { ["migrate"] } else { [] })
		| append (if $has_render { ["render"] } else { [] })
}

def runtime-names [compose: record]: nothing -> list<string> {
	runtime-services $compose | columns
}

# The providers compose gives the auth service, and each one's client: as upstream's main reads them
# from the program, an error being none.
export def release-providers [dir: string]: nothing -> record {
	let r = (do { cd $dir; ^cue export . -e '{if code.capabilities.auth != _|_ {if code.capabilities.auth.provider != _|_ {v: code.capabilities.auth.provider}, if code.capabilities.auth.provider == _|_ {v: {}}}, if code.capabilities.auth == _|_ {v: {}}}.v' --out json } | complete)
	if $r.exit_code == 0 { $r.stdout | from json } else { {} }
}

# What upstream's main unifies into the release package, and what its render-manifests adds: the
# roles and doors of .pronto/cluster.json, the runtime's services, the images pushed (`pushed`, by
# service: {tag, digest}), the auth settings, and migrate's environment. A seed that restates
# (services/database/migrations/901_seed_restate.sql) says so, as upstream's with U-D does.
export def release-data [dir: string, compose: record, facts: record, pushed: record]: nothing -> record {
	let runtime = (runtime-services $compose)
	let oidc = (auth-provider-environment ($compose.services.auth.environment? | default {}) (release-providers $dir))
	let migrate = if "migrate" in ($compose.services | columns) {
		{migrate: {env: ($compose.services.migrate.environment? | default {} | reject -o DATABASE_URL)}}
	} else { {} }
	let restate = if ($dir | path join services database migrations 901_seed_restate.sql | path exists) { {restate: true} } else { {} }
	{App: ({
		database: {tokenRoles: $facts.tokenRoles, declaredRoles: ($facts.declaredRoles? | default [])}
		runtime: $runtime
		doors: ($facts.doors? | default [])
		image: {pushed: ($pushed | items {|svc, p| [$svc {tag: $p.tag, digest: $p.digest}] } | into record)}
		auth: ($oidc | reject secretValues)
	} | merge $migrate | merge $restate)}
}

# The OIDC client secrets the release writes to a Secret of their own (never into a manifest).
export def oidc-secrets [compose: record, dir: string]: nothing -> record {
	(auth-provider-environment ($compose.services.auth.environment? | default {}) (release-providers $dir)).secretValues
}

# The release's manifests as a list of objects: `cue export -e nodeManifests` over release.cue and
# the data. An engine constraint that fails (the schema's `violations`) is CUE's error, here.
export def objects [cue_path: string, data: record, preview: string]: nothing -> list {
	let f = (mktemp -t node-data.XXXXXX.json | str trim)
	$data | to json | save -f $f
	let r = (do { cd ($cue_path | path dirname); ^cue export --expression nodeManifests --out json ...(tags $preview) ($cue_path | path basename) $f } | complete)
	rm -f $f
	if $r.exit_code != 0 { error make {msg: $"Failed to render the node manifests: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# A digest that cannot be an image's: what a check renders over where it pushed nothing.
export const placeholder_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

# Placeholder images for a check, which builds none: the database's tag is a Postgres major, the
# others' the tag a release would push.
export def placeholder-pushed [services: list<string>, tag: string]: nothing -> record {
	$services | each {|s| [$s {tag: (if $s == "database" { "17" } else { $tag }), digest: $placeholder_digest}] } | into record
}

# CloudNativePG reads the database image's tag as the Postgres major: read from the pushed image's
# own PG_MAJOR (`crane config`, with the build's registry login), as upstream's main reads it from
# the image it built.
export def database-tag [repo: string, digest: string]: nothing -> string {
	let host = ($repo | split row "/" | first)
	let cfg = (mktemp -d -t node-crane.XXXXXX | str trim)
	let token = (^gcloud auth print-access-token --quiet | str trim)
	with-env {DOCKER_CONFIG: $cfg} {
		$token | ^crane auth login $host -u oauth2accesstoken --password-stdin | ignore
		let r = (^crane config $"($repo)@($digest)" | complete)
		rm -rf $cfg
		if $r.exit_code != 0 { error make {msg: $"crane config ($repo)@($digest): ($r.stderr | str trim)"} }
		let major = ($r.stdout | from json | get config.Env | where {|e| $e starts-with "PG_MAJOR=" } | first | split row "=" | last)
		$major
	}
}
