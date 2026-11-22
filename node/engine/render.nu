# render.nu: the release data and the manifests of a node release. It does what upstream's
# k8s/release.nu does between reading the app and applying it (its render-manifests and the data its
# `main` unifies into the release package), with the six pure helpers imported from upstream
# (runtime.nu) and the rendering by CUE: upstream's #BuildManifests, over the engine's patches
# (schema/node.cue), exported as `nodeManifests` from the app's release.cue.

use runtime.nu [runtime-services auth-provider-environment program-providers-expr]

export def nearest-on-path [found: list<string>, dirs: list<string>]: nothing -> string {
	let dirs = ($dirs | each {|d| $d | path expand })
	$found | each {|p| {path: $p, at: ($dirs | enumerate | where item == ($p | path dirname | path expand) | get index | append 1000000 | first)} } | sort-by at | first | get path
}

# `docker compose` run in `dir` with the compose plugin the app's mise pins (`docker-compose`, or `docker-cli-plugin-docker-compose`
# as aqua names it), linked into a docker config of this call's own, so the CLI finds it with no daemon and no plugin of the
# host's. With none on the PATH, the docker CLI's own plugins answer. Answers `complete`'s record.
export def --wrapped compose-run [dir: string, ...args: string]: nothing -> record {
	let found = ([docker-compose docker-cli-plugin-docker-compose] | each {|n| which --all $n } | flatten | get path | uniq)
	if ($found | is-empty) {
		return (do { hide-env -i AIRLOCK_SEAL_KEY AIRLOCK_SEAL_KEY_PREVIOUS; cd ($dir | path expand); ^docker compose ...$args } | complete)
	}
	let config = (mktemp -d -t node-compose.XXXXXX | str trim)
	mkdir ($config | path join cli-plugins)
	^ln -sf (nearest-on-path $found $env.PATH) ($config | path join cli-plugins docker-compose)
	try {
		with-env {DOCKER_CONFIG: $config} { do { hide-env -i AIRLOCK_SEAL_KEY AIRLOCK_SEAL_KEY_PREVIOUS; cd ($dir | path expand); ^docker compose ...$args } | complete }
	} finally {
		rm -rf $config
	}
}

# `docker compose config`'s project for the app, as JSON, read with no seal key in the environment
# so the airlock's shows the local stack's default, the development key a release refuses.
export def compose-config [dir: string]: nothing -> record {
	let r = (compose-run $dir --profile "*" config --format json)
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
# from the program. An app that declares none gives an empty record; an export that fails is an error.
export def release-providers [dir: string]: nothing -> any {
	# From pronto 1.10 the runtime names the expression (the providers are a list of names).
	let expr = (program-providers-expr | default `{if code.capabilities.auth != _|_ {if code.capabilities.auth.provider != _|_ {v: code.capabilities.auth.provider}, if code.capabilities.auth.provider == _|_ {v: {}}}, if code.capabilities.auth == _|_ {v: {}}}.v`)
	let r = (do { cd $dir; ^cue export . -e $expr --out json } | complete)
	# A failed export is not "no providers": the release stops, as it would for any other failed render.
	if $r.exit_code != 0 { error make {msg: $"the auth providers of ($dir) did not export: ($r.stderr | str trim)"} }
	$r.stdout | from json
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

# CloudNativePG reads the database image's tag as the Postgres major: read from the pushed image's own
# PG_MAJOR (`crane config` at `registry`, the node's, plain HTTP), as upstream's main reads it from the
# image it built. The registry needs no login: it is the node's loopback, reached through the tunnel.
export def database-tag [registry: string, repo: string, digest: string]: nothing -> string {
	let r = (^crane config --insecure $"($registry)/($repo)@($digest)" | complete)
	if $r.exit_code != 0 { error make {msg: $"crane config ($registry)/($repo)@($digest): ($r.stderr | str trim)"} }
	let majors = ($r.stdout | from json | get config.Env? | default [] | where {|e| $e starts-with "PG_MAJOR=" })
	if ($majors | is-empty) { error make {msg: $"($registry)/($repo)@($digest) has no PG_MAJOR in its environment: CloudNativePG reads the database image's tag as the Postgres major, so the image must set it"} }
	$majors | first | split row "=" | last
}
