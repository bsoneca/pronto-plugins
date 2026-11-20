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

# The buildx plugin the app's mise pins: `docker-buildx`, `docker-cli-plugin-docker-buildx` (what aqua names
# docker/buildx's binary), or `buildx`. The one whose folder comes first on the PATH wins, not the first
# name tried: mise puts the app's pin ahead of the machine's, and a Homebrew `docker-buildx` (built with
# whatever Go is current, 0.38.0 with Go 1.27) must not shadow the pinned `docker-cli-plugin-docker-buildx`.
def buildx-binary []: nothing -> string {
	let found = ([docker-buildx docker-cli-plugin-docker-buildx buildx] | each {|n| which --all $n } | flatten | get path | uniq)
	if ($found | is-empty) { error make {msg: "missing on the PATH: docker-buildx: the app's mise pins it (aqua:docker/buildx), see node/README.md"} }
	nearest-on-path $found $env.PATH
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
def stage-context [app_dir: string, work: string, dest: string, include: list<string>] {
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
	$"($files | str join (char nul))(char nul)" | save -f ($work | path join files)
	mkdir $dest
	# macOS's bsdtar reads -T's list after every -C: one -C only.
	with-env {COPYFILE_DISABLE: "1"} { ^tar -cf - --null -C $app_dir -T ($work | path join files) | ^tar -xf - -C $dest }
	$files | length
}

# Builds the services' images on the node's buildkitd and pushes them to its registry, tagged `tag`
# (`release`, a preview's name, or `check`). Answers {<svc>: {tag, digest}}, the database's tag being
# its Postgres major (CloudNativePG reads it as one). `fwd` is the tunnel's local ports.
export def images [app_dir: string, node: record, fwd: record, services: list<string>, tag: string]: nothing -> record {
	let app = $node.name
	let host = $node.build.registry.host
	let dir = ($app_dir | path expand)
	let work = (mktemp -d -t node-build.XXXXXX | str trim | path expand)
	try {
		let staged = ($work | path join app)
		let count = (stage-context $dir $work $staged $node.build.include)
		let kib = (^du -sk $staged | split row "\t" | first | into int)
		print $"node: (stamp) build context: ($count) files, ($kib) KiB"
		let compose = (render compose-run $staged --profile "*" config)
		if $compose.exit_code != 0 { error make {msg: $"docker compose config failed in ($dir): ($compose.stderr | str trim)"} }
		runtime release-tree $compose.stdout | save -f ($work | path join release.compose.yaml)
		let meta = ($work | path join meta.json)
		let sets = ($services | each {|s| ["--set" $"($s).tags=($host)/($app)-($s):($tag)"] } | flatten)
		with-builder $work $fwd {|builder|
			with-env {SOURCE_DATE_EPOCH: "0"} {
				let r = (do { cd $staged; open --raw ($work | path join release.compose.yaml) | ^docker buildx bake -f - --builder $builder --push --provenance=false --progress=plain --metadata-file $meta $"--allow=fs.read=($staged)" --set $"*.platform=($node.environment.platform)" ...$sets ...$services } | complete)
				if $r.exit_code != 0 { error make {msg: $"docker buildx bake on the node's buildkitd failed:\n(($r.stdout + $r.stderr) | lines | last 40 | str join (char nl))(failed-step ($r.stdout + $r.stderr))(buildx-hint ($r.stdout + $r.stderr))"} }
				# what the client sent to the buildkitd, as buildx counted it
				let sent = (($r.stdout + $r.stderr) | lines | where {|l| $l =~ 'transferring context: [0-9.]+[kMG]?B ' } | each {|l| $l | str replace -r '^#[0-9]+ ' '' } | uniq)
				if ($sent | is-not-empty) { print $"node: (stamp) ($sent | str join '; ')" }
			}
		}
		let digests = (open $meta)
		$services | each {|s|
			let digest = ($digests | get $s | get "containerimage.digest")
			let final = if $s == "database" { render database-tag $"127.0.0.1:($fwd.registry)" $"($app)-($s)" $digest } else { $tag }
			[$s {tag: $final, digest: $digest}]
		} | into record
	} finally {
		rm -rf $work
	}
}
