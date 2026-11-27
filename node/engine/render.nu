# render.nu: the release data and the manifests of a node release. It does what upstream's
# k8s/release.nu does between reading the app and applying it (its render-manifests and the data its
# `main` unifies into the release package), with the six pure helpers imported from upstream
# (runtime.nu) and the rendering by CUE: upstream's #BuildManifests, over the engine's patches
# (schema/node.cue), exported as `nodeManifests` from the app's release.cue.

use runtime.nu [runtime-services auth-provider-environment program-providers-expr register-clients]

export def nearest-on-path [found: list<string>, dirs: list<string>]: nothing -> string {
	let dirs = ($dirs | each {|d| $d | path expand })
	$found | each {|p| {path: $p, at: ($dirs | enumerate | where item == ($p | path dirname | path expand) | get index | append 1000000 | first)} } | sort-by at | first | get path
}

# `docker compose` run in `dir` with the compose plugin the app's mise pins (`docker-compose`, or `docker-cli-plugin-docker-compose`
# as aqua names it), linked into a docker config of this call's own, so the CLI finds it with no daemon and no plugin of the
# host's. With none on the PATH, the docker CLI's own plugins answer. Answers `complete`'s record.
export def --wrapped compose-run [dir: string, ...args: string]: nothing -> record {
	compose-exec $dir false $args
}

# The same, for a tenant's compose project: the process sees only `tenant-env`'s variables, so a `${VAR}` its files name interpolates
# nothing of the caller's (a token, a key) into what the release copies into a Job or an image.
export def --wrapped compose-run-tenant [dir: string, ...args: string]: nothing -> record {
	compose-exec $dir true $args
}

# What a tenant's compose resolution and bake may see of the caller's environment: the few variables a tool needs to run (and the docker
# config this call made), plus the names the caller lists in PRONTO_TENANT_ENV_ALLOW (comma separated; a proxy, say). As `NAME=value` words
# for `env -i`.
export def tenant-env []: nothing -> list<string> {
	let extra = ($env.PRONTO_TENANT_ENV_ALLOW? | default "" | split row "," | each {|n| $n | str trim } | where {|n| $n | is-not-empty })
	[PATH HOME TMPDIR LANG LC_ALL USER DOCKER_CONFIG SOURCE_DATE_EPOCH] | append $extra | uniq | each {|k|
		let v = ($env | get -o $k)
		if $v == null { null } else { $"($k)=(if ($v | describe | str starts-with 'list') { $v | str join ':' } else { $v | into string })" }
	} | compact
}

def compose-exec [dir: string, tenant: bool, args: list<string>]: nothing -> record {
	let found = ([docker-compose docker-cli-plugin-docker-compose] | each {|n| which --all $n } | flatten | get path | uniq)
	let run = {||
		let at = ($dir | path expand)
		if $tenant {
			# `env -i`: nothing but the allowlist survives into the process
			let docker = (which docker | first | get path)
			do { cd $at; ^env -i ...(tenant-env) $docker compose ...$args } | complete
		} else {
			do { hide-env -i AIRLOCK_SEAL_KEY AIRLOCK_SEAL_KEY_PREVIOUS; cd $at; ^docker compose ...$args } | complete
		}
	}
	if ($found | is-empty) { return (do $run) }
	let config = (mktemp -d -t node-compose.XXXXXX | str trim)
	mkdir ($config | path join cli-plugins)
	^ln -sf (nearest-on-path $found $env.PATH) ($config | path join cli-plugins docker-compose)
	try {
		with-env {DOCKER_CONFIG: $config} { do $run }
	} finally {
		rm -rf $config
	}
}

# `docker compose config`'s project for the app, as JSON, read with no seal key in the environment
# so the airlock's shows the local stack's default, the development key a release refuses. A tenant's is read with the
# environment of `tenant-env` alone.
export def compose-config [dir: string, --tenant]: nothing -> record {
	let r = if $tenant { compose-run-tenant $dir --profile "*" config --format json } else { compose-run $dir --profile "*" config --format json }
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
# A tenant's release (`--tenant`, `--host`) passes its namespace and host as the tags `tenant` and `tenantHost`, which the app's
# release.cue binds into Node.tenant.
def tags [preview: string, tenant: string = "", host: string = ""]: nothing -> list<string> {
	(if ($preview | is-empty) { [] } else { [-t $"preview=($preview)"] }) | append (if ($tenant | is-empty) { [] } else { [-t $"tenant=($tenant)" -t $"tenantHost=($host)"] })
}

def cue-export [cue_path: string, expr: string, preview: string, tenant: string, host: string, ...more: string]: nothing -> any {
	let r = (do { cd ($cue_path | path dirname); ^cue export --expression $expr --out json ...(tags $preview $tenant $host) ($cue_path | path basename) ...$more } | complete)
	if $r.exit_code != 0 { error make {msg: $"($cue_path): ($expr): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The release's own settings (its Node), and the app's metadata, as release.cue states them.
export def node-config [cue_path: string, preview: string, --tenant: string = "", --host: string = ""]: nothing -> record { cue-export $cue_path "Node" $preview $tenant $host }
export def app-meta [cue_path: string, preview: string, --tenant: string = "", --host: string = ""]: nothing -> record {
	cue-export $cue_path "{name: App.name, namespace: App.namespace, type: App.type, image: App.image, render: App.render}" $preview $tenant $host
}

# The services whose images the release builds: the runtime's, the base five, migrate and render
# where the project has them (as upstream's main builds them).
export def build-services [compose: record, has_render: bool, own: list<string> = []]: nothing -> list<string> {
	let names = ($compose.services | columns)
	(runtime-names $compose) | append [database crud electric auth caddy]
		| append (if "migrate" in $names { ["migrate"] } else { [] })
		| append (if $has_render { ["render"] } else { [] })
		| append $own | uniq
}

# The images the release's own services run (Node.services, and the blob plane's rclone-s3 and imgproxy), which the
# engine builds beside upstream's: compose services of those names.
export def own-images [node: record]: nothing -> list<string> {
	($node.services? | default {} | columns) | append (if ($node.blobs? | default null) != null { [rclone-s3 imgproxy] } else { [] })
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
# `origin` is the release's public origin, where the clients of an issuer that registers them are registered (upstream's
# register-clients); empty, nothing is registered (a check writes nowhere).
export def release-data [dir: string, compose: record, facts: record, pushed: record, origin: string]: nothing -> record {
	let runtime = (runtime-services $compose)
	let provided = (auth-provider-environment ($compose.services.auth.environment? | default {}) (release-providers $dir))
	let oidc = if ($origin | is-empty) { $provided } else { $provided | update oidc (register-clients $provided.oidc $origin $dir) }
	let migrate = if "migrate" in ($compose.services | columns) {
		{migrate: {env: ($compose.services.migrate.environment? | default {} | reject -o DATABASE_URL)}}
	} else { {} }
	let restate = if ($dir | path join services database migrations 901_seed_restate.sql | path exists) { {restate: true} } else { {} }
	{App: ({
		database: {tokenRoles: $facts.tokenRoles, declaredRoles: ($facts.declaredRoles? | default [])}
		runtime: $runtime
		replays: ($facts.replays? | default [])
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
export def objects [cue_path: string, data: record, preview: string, --tenant: string = "", --host: string = ""]: nothing -> list {
	let f = (mktemp -t node-data.XXXXXX.json | str trim)
	$data | to json | save -f $f
	let r = (do { cd ($cue_path | path dirname); ^cue export --expression nodeManifests --out json ...(tags $preview $tenant $host) ($cue_path | path basename) $f } | complete)
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

# The image the database's Dockerfile stage starts from, when the stage only copies files onto it: `{ref, name}` (the
# pinned docker-image:// reference of its additional context, and that context's name), else null. The text piped in is
# the `docker compose config` of the app as staged. The primary then runs the base and the schema Jobs the full image
# (schema/node.cue's dbBase), so the app's own SQL, which the image carries for them to replay, cannot recreate the
# primary. The base has every extension the full image's postgres needs, since the stage adds none: a RUN, an ADD, a copy
# from any other stage, or a base not pinned by digest gives null, and the Cluster keeps running the full image.
export def database-base [--within: string = ""]: string -> any {
	let build = ($in | from yaml | get -o services.database.build)
	if ($build | is-empty) { return null }
	let target = ($build | get -o target | default "")
	let file = ($build.context | path join ($build | get -o dockerfile | default "Dockerfile"))
	if not ($file | path exists) { return null }
	# A tenant names the context and the Dockerfile: with `--within <staged tree>` the file read is a regular file whose canonical path (symlinks resolved) is inside it,
	# never an absolute path or a traversal that makes the release worker open another file of the host (a null answer leaves the stage to the full image, which a tenant's
	# release refuses).
	if ($within | is-not-empty) {
		let real = ($file | path expand)
		if not ($real | str starts-with $"(($within | path expand))/") or (($real | path type) != "file") { return null }
	}
	# One instruction a line, each with its continuation lines, comments gone.
	let steps = (open --raw $file | str replace --all --regex '\\\n' ' ' | lines | each { str trim } | where {|l| $l != "" and not ($l | str starts-with "#") })
	let stages = ($steps | enumerate | where {|s| $s.item =~ '(?i)^FROM\s' })
	let stage = ($stages | where {|s| ($s.item | parse --regex '(?i)\sAS\s+(?<n>\S+)\s*$' | get -o n.0 | default "") == $target } | get -o 0)
	# With no target compose builds the last stage, which this does not read: left to the full image.
	if ($target | is-empty) or ($stage | is-empty) { return null }
	let from = ($stage.item | split row " " | where $it != "" | get 1)
	let upto = ($stages | where {|s| $s.index > $stage.index } | get -o 0.index | default ($steps | length))
	let body = ($steps | skip ($stage.index + 1) | first (($upto - $stage.index - 1) | into int))
	let ctx = ($build | get -o additional_contexts | default {} | get -o $from | default "")
	if not ($ctx | str starts-with "docker-image://") or not ($ctx | str contains "@sha256:") { return null }
	for line in $body {
		let op = ($line | split row " " | first)
		# An ENV the base lacks would change what postgres reads, so it disqualifies like a RUN.
		if not ($op =~ '(?i)^(ARG|WORKDIR|ENTRYPOINT|CMD|HEALTHCHECK|EXPOSE|LABEL|USER|STOPSIGNAL|COPY)$') { return null }
		if ($op =~ '(?i)^COPY$') {
			let src = ($line | parse --regex '--from=(?<f>\S+)' | get -o f.0)
			if ($src | is-not-empty) and $src != $from { return null }
			# Files land where the schema Jobs replay them (initdb.d) or in the stage's own working folder; a file placed
			# in postgres's own folders (an extension's library or control file) is something the base lacks.
			let dest = ($line | split row " " | where $it != "" | last)
			if not ($dest =~ '^(/docker-entrypoint-initdb\.d/|[^/])') { return null }
		}
	}
	{ref: ($ctx | str replace "docker-image://" ""), name: $from}
}

# `database-base`'s image put in the node's registry as `<app>-database-base`, tagged with its Postgres major as the
# database's is (CloudNativePG reads it), the digest the one it has everywhere: crane copies it as it is, so the image the
# primary runs is the same on every release until the base itself is moved. `registry` is the node's registry as this
# release reaches it (127.0.0.1:<fwd.registry>). Answers the image's `{tag, digest}`.
export def database-base-copy [base: record, app: string, registry: string]: nothing -> record {
	let digest = ($base.ref | split row "@" | last)
	# The digest already in the node's registry (the last release put it there) is read from there: no call to the base's
	# own registry, and no copy, while the base has not moved.
	let there = $"($registry)/($app)-database-base@($digest)"
	let present = ((^crane manifest --insecure $there | complete).exit_code == 0)
	let source = if $present { $there } else { $base.ref }
	let cfg = (^crane config --insecure $source | complete)
	if $cfg.exit_code != 0 { error make {msg: $"crane config ($source): ($cfg.stderr | str trim)"} }
	let majors = ($cfg.stdout | from json | get config.Env? | default [] | where {|e| $e starts-with "PG_MAJOR=" })
	if ($majors | is-empty) { error make {msg: $"($base.ref) has no PG_MAJOR in its environment: CloudNativePG reads the database image's tag as the Postgres major"} }
	let major = ($majors | first | split row "=" | last)
	# Copied each time, too: it puts the manifest under the major's tag again, which is cheap when the blobs are there.
	let copy = (^crane copy --insecure $source $"($registry)/($app)-database-base:($major)" | complete)
	if $copy.exit_code != 0 { error make {msg: $"crane copy ($source) to the node's registry: ($copy.stderr | str trim)"} }
	{tag: $major, digest: $digest}
}
