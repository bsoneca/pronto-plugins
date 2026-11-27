# push.nu: the node engine's build. The images are built by the node's operator buildkitd and pushed by
# it to the node's own registry (127.0.0.1:5000 as the node names it): `docker buildx bake --push` on the
# Mac with a buildx `remote` builder at the buildkitd's port, which tunnel.nu forwards over the release's
# ssh. No Docker daemon is asked: the Mac holds only the docker CLI with its buildx plugin, in a
# DOCKER_CONFIG of the release's own, so nothing of it is left in ~/.docker.
#
# The build context is the app as git sees it (what a clone has, minus the `.certs/` a machine's setup
# issued), staged in a scratch folder: buildx sends a local context from the client, and the whole folder
# would carry node_modules and keys into the upload. Images are not reused by source key: an unchanged
# service is a cache hit in the buildkitd, and a reproducible build pushes the digest it pushed before.

use build.nu [stamp]
use render.nu
export use render.nu [nearest-on-path]
use runtime.nu
use registry.nu
use tenant.nu

# The buildx plugin the app's mise pins: `docker-buildx`, `docker-cli-plugin-docker-buildx` (what aqua names
# docker/buildx's binary), or `buildx`. The one whose folder comes first on the PATH wins, not the first
# name tried: mise puts the app's pin ahead of the machine's, and a Homebrew `docker-buildx` (built with
# whatever Go is current, 0.38.0 with Go 1.27) must not shadow the pinned `docker-cli-plugin-docker-buildx`.
export def buildx-binary []: nothing -> string {
	let found = ([docker-buildx docker-cli-plugin-docker-buildx buildx] | each {|n| which --all $n } | flatten | get path | uniq)
	if ($found | is-not-empty) { return (nearest-on-path $found $env.PATH) }
	# none on the PATH: the plugin Docker itself installed (a builder image puts it in /usr/local/lib/docker/cli-plugins), found as `docker` finds it
	let dirs = ($env.PRONTO_DOCKER_PLUGIN_DIRS? | default "/usr/local/lib/docker/cli-plugins:/usr/lib/docker/cli-plugins:/usr/libexec/docker/cli-plugins:/usr/local/libexec/docker/cli-plugins" | split row ":")
	let installed = ($dirs | each {|d| $d | path join docker-buildx } | where {|p| ($p | path type) == "file" })
	if ($installed | is-empty) { error make {msg: "missing on the PATH: docker-buildx, and not in Docker's plugin folders: the app's mise pins it (aqua:docker/buildx), see node/README.md"} }
	$installed | first
}

# What the failed step printed: BuildKit's plain progress prefixes every line of a step with its number, and
# the error text that follows is the Dockerfile's own lines, which push the step's output out of a tail.
def failed-step [output: string]: nothing -> string {
	let lines = ($output | lines)
	let hit = ($lines | where {|l| $l =~ '^#[0-9]+ ERROR' } | first 1)
	if ($hit | is-empty) { return "" }
	let id = ($hit | first | parse --regex '^#(?<id>[0-9]+) ERROR' | get id.0)
	$"\nthe failed step, #($id):\n(($lines | where {|l| $l starts-with $"#($id) " } | last 30 | str join (char nl)))"
}

# Said after a failed bake whose session broke: buildx sends the Dockerfile's COPY sources to the buildkitd
# as gRPC header values, one per path (~7,900 for aprende's served image), and a buildx built with Go 1.27
# (Homebrew's 0.38.0, official 0.39.0) refuses more than 500 of them: 431, or a GOAWAY PROTOCOL_ERROR.
def buildx-hint [output: string]: nothing -> string {
	if not ($output =~ 'PROTOCOL_ERROR|431 \(Request Header Fields Too Large\)|Request Header Field') { return "" }
	$"\nthe session between buildx and the buildkitd broke: the Dockerfile's COPY sources travel as header values and a buildx built with Go 1.27 caps them at 500. buildx here: (buildx-binary), see node/README.md \(pin aqua:docker/buildx@0.39.1\)."
}

# `body` run with a remote builder at the node's buildkitd, given its name: `{|builder| ... }`. The builder
# and the docker config it lives in belong to this call (`work` holds the config), and go with it.
export def with-builder [work: string, fwd: record, body: closure]: nothing -> any {
	let plugin = (buildx-binary)
	let config = ($work | path join docker)
	mkdir ($config | path join cli-plugins)
	^ln -sf $plugin ($config | path join cli-plugins docker-buildx)
	let builder = $"node-(random chars --length 6 | str lowercase)"
	with-env {DOCKER_CONFIG: $config} {
		let v = (^docker buildx version | complete)
		if $v.exit_code != 0 { error make {msg: $"docker buildx does not run with ($plugin): ($v.stderr | str trim)"} }
		print -e $"node: (stamp) buildx ($v.stdout | str trim) at ($plugin)"
		let c = (^docker buildx create --name $builder --driver remote $"tcp://127.0.0.1:($fwd.buildkit)" | complete)
		if $c.exit_code != 0 { error make {msg: $"docker buildx create at the node's buildkitd (127.0.0.1:($fwd.buildkit)): ($c.stderr | str trim)"} }
		try {
			do $body $builder
		} finally {
			do { ^docker buildx rm $builder } | complete | ignore
		}
	}
}

# `with-builder` at a buildkitd's own address (a tenant's build goes to the tenants' sandboxed buildkitd, which no tunnel reaches:
# the builder pod dials its Service), given `{|builder| ... }`; the builder and its docker config belong to this call.
export def with-remote-builder [work: string, address: string, body: closure]: nothing -> any {
	let plugin = (buildx-binary)
	let config = ($work | path join docker)
	mkdir ($config | path join cli-plugins)
	^ln -sf $plugin ($config | path join cli-plugins docker-buildx)
	let builder = $"node-(random chars --length 6 | str lowercase)"
	with-env {DOCKER_CONFIG: $config} {
		let v = (^docker buildx version | complete)
		if $v.exit_code != 0 { error make {msg: $"docker buildx does not run with ($plugin): ($v.stderr | str trim)"} }
		print -e $"node: (stamp) buildx ($v.stdout | str trim) at ($plugin)"
		let c = (^docker buildx create --name $builder --driver remote $address | complete)
		if $c.exit_code != 0 { error make {msg: $"docker buildx create at the tenants' buildkitd \(($address)\):($c.stderr | str trim)"} }
		try {
			do $body $builder
		} finally {
			do { ^docker buildx rm $builder } | complete | ignore
		}
	}
}

# The platforms the node's buildkitd builds for, read by starting the builder (it answers or fails here).
export def platforms [builder: string]: nothing -> list<string> {
	let r = (^docker buildx inspect $builder --bootstrap | complete)
	if $r.exit_code != 0 { error make {msg: $"the node's buildkitd does not answer: ($r.stderr | str trim)"} }
	$r.stdout | lines | where {|l| $l starts-with "Platforms:" } | each {|l| $l | str replace "Platforms:" "" | split row "," | each {|p| $p | str trim } } | flatten
}

# An untracked file that looks like a secret or a key: decrypted SOPS output, dotenv files, plaintext secrets
# files (SOPS' own `.enc.yaml` are fine), certificates and keys. Tracked files are reviewed; an untracked
# one is whatever the machine holds, so these are never staged.
export def looks-secret [path: string]: nothing -> bool {
	let name = ($path | path basename)
	($name =~ '\.dec\.') or ($name starts-with ".env") or ($name =~ '^secrets.*\.ya?ml$' and not ($name =~ '\.enc\.ya?ml$')) or ($name =~ '\.(pem|key)$')
}

# The app as git sees it, copied under `dest`: every tracked and untracked-but-not-ignored file, none of
# `.certs/`, none that is listed but gone, no untracked file that looks like a secret (said, not silent), and
# the ignored files the app's `build.include` names (generated files its Dockerfiles COPY), which must exist.
# Whether `file` (relative to the app) really is under the app's folder: no absolute path, no `..`, and no symlink, in any component, that
# leads out (its real path is under the real root).
export def under-root [root: string, file: string]: nothing -> bool {
	if ($file | str starts-with "/") or ($file | path split | any {|c| $c == ".." }) { return false }
	($root | path join $file | path expand) | str starts-with $"($root)/"
}

export def stage-context [app_dir: string, work: string, dest: string, include: list<string>, --tenant] {
	let root = ($app_dir | path expand)
	let outside = ($include | where {|f| not (under-root $root $f) })
	if ($outside | is-not-empty) { error make {msg: $"build.include names ($outside | str join ', '), which is not under the app's own folder \(an absolute path, a `..`, or a link that leads out\): it is never staged"} }
	let missing = ($include | where {|f| ($app_dir | path join $f | path type) != "file" })
	if ($missing | is-not-empty) { error make {msg: $"build.include names ($missing | str join ', '), which is not a file in ($app_dir): the app's generate writes it"} }
	let secret = ($include | where {|f| looks-secret $f })
	if ($secret | is-not-empty) { error make {msg: $"build.include names ($secret | str join ', '), which looks like a secret and is never staged"} }
	# NUL-separated, so a file name with a newline in it is one name
	let untracked = (do { cd $app_dir; ^git ls-files -z -o --exclude-standard } | split row (char nul) | where {|f| $f != "" })
	let denied = ($untracked | where {|f| looks-secret $f })
	if ($denied | is-not-empty) { print $"node: (stamp) not in the build context, untracked and secret-looking: ($denied | str join ', ')" }
	let files = (do { cd $app_dir; ^git ls-files -z -co --exclude-standard } | split row (char nul) | where {|f| $f != "" }
		| where {|f| not ($f starts-with ".certs/") and ($f not-in $denied) and ($app_dir | path join $f | path exists) }
		| append $include | uniq)
	# A tenant's context is regular files that really are in the app: a link (a tracked one too) never carries what it points at into the build.
	let files = if $tenant { $files | where {|f| ($root | path join $f | path type) == "file" and (under-root $root $f) } } else { $files }
	$"($files | str join (char nul))(char nul)" | save -f ($work | path join files)
	mkdir $dest
	# macOS's bsdtar reads -T's list after every -C: one -C only.
	with-env {COPYFILE_DISABLE: "1"} { ^tar -cf - --null -C $app_dir -T ($work | path join files) | ^tar -xf - -C $dest }
	$files | length
}

# The door's Caddyfile must carry the Dapr guard doorguard splices in (PRONTO-1307): no public prefix may reach a Dapr API
# path of the sidecar. Verified, never patched: the Caddyfile is generated, so the fix belongs to the app's generate.
export def verify-door-guard [staged: string] {
	let file = ($staged | path join docker Caddyfile)
	if not ($file | path exists) { return }
	let text = (open --raw $file)
	if not ($text | str contains "# PRONTO-1307: no public prefix reaches a Dapr API path of its sidecar") {
		error make {msg: "docker/Caddyfile lacks the Dapr guard (PRONTO-1307): /img, /blobs, /crud and /electric would proxy /v1.0 paths to the sidecar. Add the doorguard plugin (`bin/pronto-doorguard <app-dir>` in pronto-plugins, then the app's generate) and commit the Caddyfile"}
	}
	# A guard whose pattern is case-sensitive is the bypass of PRONTO-916: Caddy's `handle /crud/*` ignores case, so /CRUD/v1.0/metadata reaches the sidecar.
	if not ($text | str contains 'path_regexp daprapi (?i)^/(crud|img|blobs|electric)/v1\.0(-alpha1)?(/|$)') {
		error make {msg: "docker/Caddyfile carries an older Dapr guard whose pattern is case-sensitive (PRONTO-916): /CRUD/v1.0/metadata would reach the sidecar. Refresh the doorguard plugin (`bin/pronto-doorguard <app-dir>`, then the app's generate) and commit the Caddyfile it writes."}
	}
}

# Builds the services' images on the node's buildkitd and pushes them to its registry, tagged `tag`
# (`release`, a preview's name, or `check`). Answers {<svc>: {tag, digest}}, the database's tag being
# its Postgres major (CloudNativePG reads it as one). `fwd` is the tunnel's local ports.
export def images [app_dir: string, node: record, fwd: record, services: list<string>, tag: string, lease: string = ""]: nothing -> record {
	let app = $node.name
	let host = $node.build.registry.host
	let dir = ($app_dir | path expand)
	let work = (mktemp -d -t node-build.XXXXXX | str trim | path expand)
	try {
		let staged = ($work | path join app)
		let count = (stage-context $dir $work $staged $node.build.include)
		verify-door-guard $staged
		let kib = (^du -sk $staged | split row "\t" | first | into int)
		print $"node: (stamp) build context: ($count) files, ($kib) KiB"
		let compose = (render compose-run $staged --profile "*" config)
		if $compose.exit_code != 0 { error make {msg: $"docker compose config failed in ($dir): ($compose.stderr | str trim)"} }
		runtime release-tree $compose.stdout | save -f ($work | path join release.compose.yaml)
		let meta = ($work | path join meta.json)
		let sets = ($services | each {|s| ["--set" $"($s).tags=($host)/($app)-($s):($tag)"] } | flatten)
		with-builder $work $fwd {|builder|
			# Bake, then ask the registry for each pushed manifest, config and layer: a registry whose blob descriptor cache outlived a
			# garbage collection takes a reproducible build's push as already there and writes only links (PRONTO-1868), and the pods'
			# pull then fails minutes into the rollout. The first miss restarts the registry (an empty cache; `lease` is this release's own,
			# and no other may be in flight) and bakes once more.
			for attempt in 1..2 {
			with-env {SOURCE_DATE_EPOCH: "0"} {
				let r = (do { cd $staged; open --raw ($work | path join release.compose.yaml) | ^docker buildx bake -f - --builder $builder --push --provenance=false --progress=plain --metadata-file $meta $"--allow=fs.read=($staged)" --set $"*.platform=($node.environment.platform)" ...$sets ...$services } | complete)
				if $r.exit_code != 0 { error make {msg: $"docker buildx bake on the node's buildkitd failed:\n(($r.stdout + $r.stderr) | lines | last 40 | str join (char nl))(failed-step ($r.stdout + $r.stderr))(buildx-hint ($r.stdout + $r.stderr))"} }
				# what the client sent to the buildkitd, as buildx counted it
				let sent = (($r.stdout + $r.stderr) | lines | where {|l| $l =~ 'transferring context: [0-9.]+[kMG]?B ' } | each {|l| $l | str replace -r '^#[0-9]+ ' '' } | uniq)
				if ($sent | is-not-empty) { print $"node: (stamp) ($sent | str join '; ')" }
			}
			let pushed = (open $meta)
			let lost = (registry lost-images $"127.0.0.1:($fwd.registry)" ($services | each {|s| {repo: $"($app)-($s)", digest: ($pushed | get $s | get "containerimage.digest")} }))
			if ($lost | is-empty) { break }
			let names = ($lost | each {|i| $"($i.repo)@($i.digest)" } | str join ", ")
			if $attempt == 2 { error make {msg: $"registry lost ($names): it still does not serve them after a restart and a second push, so nothing is rolled out"} }
			print -e $"node: (stamp) registry lost ($names) \(a stale blob cache\): restarting the registry and baking again"
			let why = (registry restart-alone $node.build $lease)
			if $why != "" { error make {msg: $"registry lost ($names): ($why)"} }
			}
		}
		let digests = (open $meta)
		let built = ($services | each {|s|
			let digest = ($digests | get $s | get "containerimage.digest")
			let final = if $s == "database" { render database-tag $"127.0.0.1:($fwd.registry)" $"($app)-($s)" $digest } else { $tag }
			[$s {tag: $final, digest: $digest}]
		} | into record)
		# The primary runs the database's base where the stage only copies files onto it (PRONTO-615): the image
		# CloudNativePG recreates the instance for then never moves with the app's SQL.
		let base = if "database" in $services { $compose.stdout | render database-base } else { null }
		if ($base | is-empty) { $built } else { $built | insert "database-base" (render database-base-copy $base $app $"127.0.0.1:($fwd.registry)") }
	} finally {
		rm -rf $work
	}
}

# `text` (a compose project) with every path that is `from` or under it spelled under `to`.
export def rebase-paths [text: string, from: string, to: string]: nothing -> string {
	let escaped = ($from | str replace -a -r '([^A-Za-z0-9_/-])' '\$1')
	$text | str replace -a -r ("(?m)" + $escaped + "([/\"'\\s]|$)") ($to + '${1}')
}

# A tenant's build (`release.nu --tenant`): the images built on the tenants' sandboxed buildkitd (`node.tenant.buildkit`), which writes each
# as an OCI archive and never pushes; then pushed, as the push identity (`push_kubeconfig`, or the pod's own account), through a
# port-forward to the registry pod, to `<registry>/<namespace>/<app>-<service>:<tag>`. An untrusted Dockerfile never reaches the operator's
# buildkitd, which has no sandbox and could overwrite any image in the registry. A lost image after the push is an error: a tenant's
# release cannot restart the registry. Answers {<svc>: {tag, digest}}, the database's tag being its Postgres major.
export def tenant-images [app_dir: string, node: record, services: list<string>, tag: string, push_kubeconfig: string]: nothing -> record {
	let app = $node.name
	let ns = $node.namespace
	# a service is a build target and a path under the staging folder: a name, never an option or a path (a Node a release.cue exports itself
	# skips the schema's service-name grammar)
	let odd = ($services | where {|s| not ($s =~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') })
	if ($odd | is-not-empty) { error make {msg: $"a tenant's build targets are service names: ($odd | length) of them are not \(lowercase letters, digits and '-'\)"} }
	let dir = ($app_dir | path expand)
	let work = (mktemp -d -t node-build.XXXXXX | str trim | path expand)
	try {
		let staged = ($work | path join app)
		let count = (stage-context $dir $work $staged $node.build.include --tenant)
		verify-door-guard $staged
		print $"node: (stamp) build context: ($count) files"
		let compose = (render compose-run-tenant $staged --profile "*" config)
		if $compose.exit_code != 0 { error make {msg: $"docker compose config failed in ($dir): ($compose.stderr | str trim)"} }
		# The staged copy is what bake may read: a path the project names inside the app's own folder (an absolute build context a flatten wrote)
		# is the staged copy's, so the grant below covers it and nothing outside the app is added to it.
		let rebased = (rebase-paths $compose.stdout $dir $staged)
		# The tenants' buildkitd is shared: no build key that reaches past the context, and every Dockerfile's cache mounts are the namespace's own (PRONTO-1945), on the staged copy the
		# build reads and never on the author's files.
		$rebased | tenant check-build-keys
		mut staged_files = []
		for s in (($rebased | from yaml | get -o services | default {}) | transpose name v) {
			let build = ($s.v | get -o build)
			if $build == null or not ($build | describe | str starts-with "record") { continue }
			let file = ($build | get -o context | default "." | path join ($build | get -o dockerfile | default "Dockerfile") | path expand)
			if $file in $staged_files { continue }
			if not ($file | str starts-with $"(($staged | path expand))/") or not ($file | path exists) or (($file | path type) != "file") {
				error make {msg: $"a tenant's service ($s.name) builds from ($file), which is not a regular file inside the staged app"}
			}
			open --raw $file | tenant stage-dockerfile $ns | save -f $file
			$staged_files = ($staged_files | append $file)
		}
		runtime release-tree $rebased | save -f ($work | path join release.compose.yaml)
		# The Cluster runs the engine's approved database base, never the tenant's: the database stage must only copy SQL onto a base the engine approves (#TenantDatabaseImages).
		# Said before anything is built; the engine's own ref is what is copied below.
		let approved_base = if "database" in $services {
			let base = ($rebased | render database-base --within $staged)
			let ok = (tenant approved-database-base $base (tenant database-images))
			if $ok == null {
				let what = if $base == null { "does more than copy SQL onto a base pinned by digest (a RUN, an ADD, an ENV, a copy from another stage or into postgres's own folders)" } else { $"sits on ($base.ref), which the engine does not approve" }
				error make {msg: $"a game's database stage ($what): a tenant's database runs an approved database image \(mecha's, by digest\) and its stage only copies SQL onto it. A new extension is a new mecha release the engine approves first."}
			}
			$ok
		} else { null }
		let out = ($work | path join oci)
		mkdir $out
		let sets = ($services | each {|s| ["--set" $"($s).output=type=oci,dest=($out)/($s).tar" "--set" $"($s).tags="] } | flatten)
		with-remote-builder $work $node.tenant.buildkit {|builder|
			with-env {SOURCE_DATE_EPOCH: "0"} {
				let r = (do { cd $staged; open --raw ($work | path join release.compose.yaml) | ^env -i ...(render tenant-env) (which docker | first | get path) buildx bake -f - --builder $builder --provenance=false --progress=plain $"--allow=fs.read=($staged)" $"--allow=fs.write=($out)" --set $"*.platform=($node.environment.platform)" --set $"*.args.BUILDKIT_CACHE_MOUNT_NS=($ns)" ...$sets -- ...$services } | complete)
				if $r.exit_code != 0 { error make {msg: $"docker buildx bake on the tenants' buildkitd failed:\n(($r.stdout + $r.stderr) | lines | last 40 | str join (char nl))(failed-step ($r.stdout + $r.stderr))"} }
			}
		}
		let pushed = (tenant with-registry-forward $push_kubeconfig {|port|
			let registry = $"127.0.0.1:($port)"
			let built = ($services | each {|svc|
				let layout = ($out | path join $svc)
				mkdir $layout
				^tar -xf ($out | path join $"($svc).tar") -C $layout
				let repo = $"($ns)/($app)-($svc)"
				let r = (^crane push --insecure $layout $"($registry)/($repo):($tag)" | complete)
				if $r.exit_code != 0 { error make {msg: $"crane push of ($repo) to the node's registry failed: ($r.stderr | str trim)"} }
				let digest = ($"($r.stdout)($r.stderr)" | lines | each {|l| $l | parse --regex '@(?<d>sha256:[0-9a-f]{64})' | get -o d.0 } | compact | last)
				{svc: $svc, repo: $repo, digest: $digest}
			})
			# The approved base, the engine's own ref, copied to the tenant's path under its Postgres major, and read back at the digest the engine approved.
			let base_pushed = if $approved_base == null { null } else {
				let repo = $"($ns)/($app)-database-base"
				let copy = (^crane copy --insecure $approved_base.ref $"($registry)/($repo):($approved_base.major)" | complete)
				if $copy.exit_code != 0 { error make {msg: $"crane copy ($approved_base.ref) to the node's registry: ($copy.stderr | str trim)"} }
				let got = (^crane digest --insecure $"($registry)/($repo):($approved_base.major)" | complete)
				if $got.exit_code != 0 or ($got.stdout | str trim) != $approved_base.digest { error make {msg: $"the copied database base at ($repo):($approved_base.major) is ($got.stdout | str trim), not the approved ($approved_base.digest)"} }
				{repo: $repo, digest: $approved_base.digest, major: $approved_base.major}
			}
			let lost = (registry lost-images $registry (($built | each {|b| {repo: $b.repo, digest: $b.digest} }) | append (if $base_pushed == null { [] } else { [{repo: $base_pushed.repo, digest: $base_pushed.digest}] })))
			if ($lost | is-not-empty) {
				let names = ($lost | each {|i| $"($i.repo)@($i.digest)" } | str join ", ")
				error make {msg: $"registry lost ($names) after the push: a tenant's release cannot restart the registry, so nothing is rolled out; publish again"}
			}
			let result = ($built | each {|b|
				let final = if $b.svc == "database" { render database-tag $registry $b.repo $b.digest } else { $tag }
				[$b.svc {tag: $final, digest: $b.digest}]
			} | into record)
			if $base_pushed == null { $result } else { $result | insert "database-base" {tag: $base_pushed.major, digest: $base_pushed.digest} }
		})
		$pushed
	} finally {
		rm -rf $work
	}
}
