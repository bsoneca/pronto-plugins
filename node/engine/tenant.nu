# tenant.nu: what a tenant's release (`release.nu --tenant <namespace> --host <host>`) needs beyond the operator's. A tenant's release has two
# actors: the namespace's publisher (the KUBECONFIG it is given: rights in the namespace alone, no tunnel, no operator) and the push
# identity (`--push-kubeconfig`, or the pod's own account), which alone may reach the node's registry pod and the Envoy Gateway
# data plane. The checks here are the ones the operator's release makes with cluster-wide reads, made with the rights a publisher has.
# It imports nothing of the release (release.nu imports it).

use tunnel.nu
use build.nu [stamp]

# The engine's own folder: its schema is the one a tenant's release trusts, never the app's copy of it.
const engine_dir = path self .

# A tenant's namespace, as Studio's provisioner names it.
export def check-tenant-name [tenant: string] {
	if not ($tenant =~ '^studio-[a-z0-9-]{1,55}$') {
		error make {msg: $"a tenant's namespace is studio-<owner>-<app>-<hash>: ($tenant) is not"}
	}
}

# The kinds a tenant's publisher may write, read from the engine's own schema (`#PublisherKinds`, the one list the CUE also uses).
export def publisher-kinds []: nothing -> list<string> {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#PublisherKinds' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #PublisherKinds: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The issuers a tenant's release may register clients at, read from the engine's own schema (`#TenantIssuers`), never the app's copy.
export def tenant-issuers []: nothing -> list<string> {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#TenantIssuers' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #TenantIssuers: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# The database images a tenant's Cluster may run (`#TenantDatabaseImages`).
export def database-images []: nothing -> list { schema-export '#TenantDatabaseImages' }

# The approved database image a tenant's database stage (`render database-base`'s answer: {ref, name}, or null for a stage that does more than copy SQL onto a pinned
# base) sits on: its entry of `approved` (`#TenantDatabaseImages`) by digest, or null. The ref the engine copies is the entry's, never the tenant's string.
export def approved-database-base [base: any, approved: list]: nothing -> any {
	if $base == null { return null }
	let digest = ($base.ref | split row "@" | last)
	$approved | where {|a| $a.digest == $digest } | get -o 0
}

# One of the engine's own schema definitions, as data.
def schema-export [expr: string]: nothing -> any {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e $expr node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export ($expr): ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# A name the tenant's Node gives kubectl (a Secret a service reads, a ConfigMap it seeds) is a Kubernetes resource name, never an option:
# one that starts with a dash would be parsed as a flag (a `--kubeconfig` can name a credential plugin kubectl runs). Said before the first
# kubectl call that carries one.
export def check-names [node: record] {
	let names = ($node.services? | default {} | values | each {|s| ($s.secrets? | default {} | values) | append ($s.seed? | default {} | columns) } | flatten | uniq)
	let bad = ($names | where {|n| not (($n | into string) =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') })
	if ($bad | is-not-empty) { error make {msg: $"Node.services name ($bad | length) Secret or seed name\(s\) that are not Kubernetes resource names \(lowercase letters, digits, '-' and '.', starting and ending with a letter or digit\): ($bad | each {|n| $n | into string | str substring 0..40 | to nuon } | str join ', ')"} }
}

# A ConfigMap a service seeds is a ConfigMap the release writes: never one of the objects the provisioner or the engine owns (`#TenantReserved`).
export def check-seeds [seeds: list] {
	let reserved = (schema-export '#TenantReserved' | where kind == ConfigMap | get name)
	let bad = ($seeds | where {|s| $s.name in $reserved } | get name)
	if ($bad | is-not-empty) { error make {msg: $"Node.services seed the ConfigMap ($bad | str join ', '), which the provisioner or the engine owns"} }
}

# What a release may retire (kind to the kubectl resource it deletes, as kind.group), read from the engine's own schema (`#RetireKinds`).
export def retire-kinds []: nothing -> record {
	let r = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#RetireKinds' node.cue } | complete)
	if $r.exit_code != 0 { error make {msg: $"the engine's schema does not export #RetireKinds: ($r.stderr | str trim)"} }
	$r.stdout | from json
}

# What a tenant's release deletes after it rolled out, decided here in trusted code and never taken from the Node it exported (a release.cue
# may export a Node of its own that skips the schema's `retire`): each entry's kind must be one of `kinds` (the engine's allowlist, which holds no
# Cluster, volume claim, Secret or ExternalSecret), the resource kubectl is told is the allowlist's own for that kind, the name a plain name
# (never an option, a list or a selector), and neither the release's own record nor an object this release writes. It is always deleted in
# the tenant's namespace, `-n` of the caller. Refused before any write. Answers `{resource, name}` for each.
export def check-retire [node: record, kinds: record, objects: list]: nothing -> list {
	# what the release writes: its rendered objects and the ConfigMaps its services seed (applied apart from them, then mounted)
	let seeded = ($node.services? | default {} | values | each {|s| $s.seed? | default {} | columns } | flatten | each {|n| $"ConfigMap/($n)" })
	let written = ($objects | each {|o| $"($o.kind)/($o.metadata.name)" } | append $seeded)
	let exported = (do { cd ($engine_dir | path join schema); ^cue export --out json -e '#TenantNoRetire' node.cue } | complete)
	if $exported.exit_code != 0 { error make {msg: $"the engine's schema does not export #TenantNoRetire: ($exported.stderr | str trim)"} }
	let never = ($exported.stdout | from json)
	let reserved = (schema-export '#TenantReserved')
	let planned = ($node.retire? | default [])
	let problems = ($planned | each {|r|
		let kind = ($r.kind? | default "")
		let name = ($r.name? | default "")
		let id = $"($kind)/($name)"
		if ($kinds | get -o $kind) == null {
			$"retire names ($id): a tenant's release may retire only ($kinds | columns | str join ', ')"
		} else if not ($name =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') {
			$"retire names ($id): not a plain resource name"
		} else if $kind in $never {
			$"retire names ($id), which a tenant's release never retires \(the provisioner's publisher account, a NetworkPolicy and a CronJob are not its to delete\)"
		} else if $id in $written {
			$"retire names ($id), which this release writes"
		} else if ($reserved | any {|x| $x.kind == $kind and $x.name == $name }) {
			$"retire names ($id), an object the provisioner or the engine owns"
		}
	} | compact)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's retirement is refused: ($problems | str join '; ')"} }
	$planned | each {|r| {resource: ($kinds | get $r.kind), name: $r.name} }
}

# Every issuer a tenant's auth names must be exactly one of `issuers` (the engine's list): the release fetches the issuer's discovery
# document and POSTs a registration to it from Studio's builder pod, so an issuer the game picked is a request the pod makes for it (SSRF).
# `settings` is the OIDC settings the auth provider environment made and `environment` the compose auth service's own; a key ending in
# `_ISSUER` or `_INTERNAL` is an issuer. Refused before any fetch, naming the key: not https, with credentials or a port, a literal IP, or
# an origin not on the list. The error never carries the value (a URL may hold credentials, a path or a query). No auth service, or no
# issuer, passes.
export def check-issuers [settings: record, environment: record, issuers: list<string>] {
	let named = ([$settings $environment] | each {|r| $r | transpose key value } | flatten
		| where {|e| ($e.key =~ '(_ISSUER|_INTERNAL)$') and (($e.value | into string) | is-not-empty) }
		| each {|e| {key: $e.key, value: ($e.value | into string)} } | uniq)
	let problems = ($named | each {|e|
		let url = $e.value
		let authority = ($url | str replace -r '^https://' '' | split row -r '[/?#]' | first)
		if not ($url | str starts-with "https://") {
			$"($e.key) is refused: an issuer is an https origin"
		} else if ($authority | str contains "@") {
			$"($e.key) is refused: an issuer carries no credentials"
		} else if ($authority | str starts-with "[") {
			$"($e.key) is refused: an issuer is a name, never an IP address"
		} else if ($authority | str contains ":") {
			$"($e.key) is refused: an issuer names no port"
		} else if ($authority =~ '^[0-9.]+$') or ($authority =~ '^0[xX][0-9a-fA-F.]+$') {
			$"($e.key) is refused: an issuer is a name, never an IP address"
		} else if $url not-in $issuers {
			$"($e.key) is refused: it is not an issuer a tenant may use \(the engine allows ($issuers | str join ', ')\)"
		}
	} | compact)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's issuers are refused: ($problems | str join '; ')"} }
}

# The app's copy of the schema (`node/schema/node.cue`, which its release.cue imports) is made the engine's own, byte for byte: a copy the
# game's author edited would load refusals of its own choosing. It must be a regular file, the only one in its folder; the engine's copy
# replaces whatever it said.
export def check-engine-copy [app_dir: string] {
	let own = ($engine_dir | path join schema node.cue)
	let theirs = ($app_dir | path join node schema node.cue)
	let dir = ($theirs | path dirname)
	# `node` and `node/schema` are real folders of the app, never links (a link would lead the replacement into another checkout)
	let node_dir = ($app_dir | path join node)
	for step in [{in: $app_dir, name: "node", label: "node"} {in: $node_dir, name: "schema", label: "node/schema"}] {
		let found = if ($step.in | path type) == "dir" { ls -a $step.in | where {|e| ($e.name | path basename) == $step.name } } else { [] }
		if ($found | is-not-empty) and $found.0.type != "dir" { error make {msg: $"the app's ($step.label) is a ($found.0.type), not a folder: a tenant's release follows no link to its schema"} }
	}
	let entry = if ($dir | path type) == "dir" { ls -a $dir | where {|e| ($e.name | path basename) == "node.cue" } } else { [] }
	if ($entry | is-empty) { error make {msg: $"($theirs) is missing: a tenant's release imports the engine's schema from the app's node/schema"} }
	# only a regular file of the engine's own size is opened: a link, a FIFO (which would wait for a writer) or a device is refused unread
	if ($entry.0.type != "file") { error make {msg: $"the app's node/schema/node.cue is a ($entry.0.type), not a regular file: a tenant's release trusts no schema its author could have edited"} }
	# the folder holds that file alone: anything else would be loaded with the schema's package
	let others = (ls -a $dir | get name | each {|n| $n | path basename } | where {|n| $n != "node.cue" })
	if ($others | is-not-empty) { error make {msg: $"the app's node/schema holds ($others | str join ', ') beside node.cue: a tenant's release trusts no schema folder its author could have added to"} }
	# …and the engine's own copy is put over it, so nothing the author wrote is ever read (a comparison would leave a window between check and
	# use): written beside it and renamed over it, never into the entry itself. An app that runs its own vendored engine holds the one file
	# (same real path): nothing to put over it.
	if ($own | path expand) == ($theirs | path expand) { return }
	let fresh = ($dir | path join $".node.cue.(random uuid)")
	cp $own $fresh
	mv -f $fresh $theirs
}

def as-list [v: any]: nothing -> list {
	# a list of mappings describes as a table
	if $v == null { [] } else if (($v | describe) =~ '^(list|table)') { $v } else { [$v] }
}

# Why a path a compose file names may not be read (null when it may): `docker compose config` reads env_file, label_file, extends files and
# secrets' and configs' files with the release process's own rights, so a tenant's compose file may name only files inside its own folder,
# spelled as plain paths (no variable, no URL), as they resolve after links.
def compose-path-problem [root: string, value: any, what: string]: nothing -> any {
	if $value == null { return null }
	let p = (if ($value | describe | str starts-with "record") { $value.path? | default "" } else { $value | into string })
	if ($p | is-empty) { return null }
	if ($p | str contains '$') { return $"($what) names ($p), a path with a variable in it: a tenant's compose file names plain paths" }
	# docker reads a context that starts with git@ or github.com/ as a git remote too (the scp-like and the bare spellings), though neither has a scheme
	if ($p =~ '^(git@|github\.com/)') { return $"($what) names ($p), a git remote, which is not a path inside the app's own folder" }
	if ($p =~ '^[A-Za-z][A-Za-z0-9+.-]*:') { return $"($what) names ($p), which is not a path inside the app's own folder" }
	let full = ($root | path join $p | path expand)
	if $full == $root or ($full | str starts-with $"($root)/") { null } else { $"($what) names ($p), which is outside the app's own folder" }
}

# A tenant's compose files are checked before anything resolves them (the release's own `docker compose config` would read what they name with
# its own rights, and a value read from a file outside the app could reach a Job's environment): nothing they name may be outside the app's
# folder, no `include` is allowed, ssh forwarding is refused, and the project's `.env` names no COMPOSE_ variable (which can add compose files).
# Studio flattens its games' compose projects in a jail before the engine runs; this holds for any other caller.
export def check-compose-sources [app_dir: string] {
	let root = ($app_dir | path expand)
	let named = (ls -a $root | where {|e| let n = ($e.name | path basename); $n == ".env" or $n =~ '^(docker-)?compose([.-][A-Za-z0-9_.-]*)?\.ya?ml$' })
	# compose follows a link (and reads a folder's files as it likes): only a regular file is read here, so anything else with the name is refused
	mut problems = ($named | where type != file | each {|e| $"($e.name | path basename) is a ($e.type), not a regular file: compose would follow it to what this check does not read" })
	let files = ($named | where type == file | get name | where {|f| ($f | path basename) != ".env" })
	let env_file = ($root | path join .env)
	# only a regular file is opened: a `.env` that is a link was refused above and is never read
	if ($named | any {|e| ($e.name | path basename) == ".env" and $e.type == file }) {
		let names = (open --raw $env_file | lines | where {|l| ($l | str trim) =~ '^(export\s+)?COMPOSE_' })
		if ($names | is-not-empty) { $problems = ($problems | append ".env names a COMPOSE_ variable, which can add compose files from anywhere") }
	}
	for f in $files {
		let name = ($f | path basename)
		let parsed = (try { {ok: true, doc: (open --raw $f | from yaml)} } catch { {ok: false, doc: null} })
		let doc = $parsed.doc
		# a file with nothing in it (comments alone) names nothing
		if $parsed.ok and ($doc == null) { continue }
		if not $parsed.ok or not ($doc | describe | str starts-with "record") { $problems = ($problems | append $"($name) cannot be read as a YAML mapping"); continue }
		if ($doc | get -o include) != null { $problems = ($problems | append $"($name) has include, which pulls in files the engine does not read first") }
		for kind in [secrets configs] {
			for e in (($doc | get -o $kind | default {}) | transpose k v) {
				let bad = (compose-path-problem $root ($e.v | get -o file) $"($name) ($kind).($e.k).file")
				if $bad != null { $problems = ($problems | append $bad) }
			}
		}
		for s in (($doc | get -o services | default {}) | transpose k v) {
			let at = $"($name) services.($s.k)"
			for key in [env_file label_file] {
				for item in (as-list ($s.v | get -o $key)) {
					let bad = (compose-path-problem $root $item $"($at).($key)")
					if $bad != null { $problems = ($problems | append $bad) }
				}
			}
			let extends = ($s.v | get -o extends)
			# extends within the same file is allowed; one that names a file pulls in a file this check does not read, as include does
			if $extends != null and ($extends | describe | str starts-with "record") and (($extends | get -o file) != null) {
				$problems = ($problems | append $"($at).extends.file names another file, which this check does not read: extends within the same file is allowed")
			}
			let build = ($s.v | get -o build)
			if $build != null {
				let rec = if ($build | describe | str starts-with "record") { $build } else { {context: $build} }
				let ctx = ($rec | get -o context | default ".")
				let bad = (compose-path-problem $root $ctx $"($at).build.context")
				if $bad != null { $problems = ($problems | append $bad) }
				let df = ($rec | get -o dockerfile)
				if $df != null {
					let bad = (compose-path-problem $root ($root | path join $ctx $df) $"($at).build.dockerfile")
					if $bad != null { $problems = ($problems | append $bad) }
				}
				let extra = ($rec | get -o additional_contexts | default {})
				let pairs = if ($extra | describe | str starts-with "record") { $extra | transpose k v | each {|p| $p.v } } else { as-list $extra | each {|l| $l | into string | split row -n 2 "=" | last } }
				for v in $pairs {
					if ($v | into string) =~ '^(docker-image|service|target):' { continue }
					let bad = (compose-path-problem $root $v $"($at).build.additional_contexts")
					if $bad != null { $problems = ($problems | append $bad) }
				}
				if (as-list ($rec | get -o ssh) | is-not-empty) { $problems = ($problems | append $"($at).build.ssh forwards the release's ssh agent into a build") }
			}
		}
	}
	if ($problems | is-not-empty) { error make {msg: $"a tenant's compose project is refused before it is resolved: ($problems | str join '; ')"} }
}

# A Dockerfile a tenant's build reads, made safe for the tenants' one shared buildkitd (PRONTO-1945): its layer cache is content-addressed, so no tenant can place a layer another's build
# reuses, but a cache mount (`RUN --mount=type=cache`) is shared by id across every build and the id is the Dockerfile's choice (the target path by default), so one tenant could seed
# what another's build runs, or read what it left. The root fix is buildkit's own: `push.nu` gives every build `BUILDKIT_CACHE_MOUNT_NS=<namespace>` through bake's --set (which wins over a
# compose `args` value, and a tenant's own `args` naming it is refused: check-build-keys), so every cache mount's id is prefixed with the namespace by the frontend itself, those an ONBUILD
# trigger brings too. What follows is defence in depth on the staged text, and it reads the Dockerfile as buildkit does, instruction by instruction: only the leading comments and blank lines
# can hold a parser directive; only the flags of a RUN (and ONBUILD RUN) instruction are mount flags; a heredoc body, a comment, a command's arguments and every other instruction are
# preserved byte for byte. Each cache mount's id is made `<namespace>/<its id, or its target>` (the target as it is: two targets are two ids), the flag read as buildkit reads it (a flag
# name and a mount key or type in any case). Refused: a mount value that has an escape character (a continuation line could append a second `id=`), a variable in it, a quote, a cache
# mount with no target, an explicit id with `..` or `/`, a `--mount` with no `=`, an `escape=` directive, and any `# syntax=` (or `//syntax=`) directive but the official docker/dockerfile
# frontend's, which is dropped so the built-in frontend builds it. The frontend check runs again on the final bytes (BOM and shebang as buildkit skips them): a JSON Dockerfile, which
# buildkit reads a frontend from, is refused wherever it came from, one an approved directive was hiding included. Answers the text bake is sent, or fails with what a tenant's Dockerfile does.
export def stage-dockerfile [namespace: string]: string -> string {
	# the BOM buildkit skips before it reads a directive is no part of the text the rest reads
	let text = ($in | str replace --regex '^\x{FEFF}' '')
	# Buildkit and a regular expression disagree on what white space is (a form feed, a no-break space): a Dockerfile is plain, so no control character but tab, line feed and carriage return,
	# and no non-ASCII white space, is read at all, and every continuation below is a backslash, spaces and tabs, and the line end.
	if ($text =~ r#'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'#) { error make {msg: "a tenant's Dockerfile has a control character (other than tab, line feed and carriage return): a tenant's Dockerfile is plain text"} }
	# a carriage return is only half of a CRLF line end: buildkit trims every trailing one off a heredoc terminator, a hand strip trims one
	if ($text =~ r#'\r(?!\n)'#) { error make {msg: "a tenant's Dockerfile has a carriage return that does not end a CRLF line end: a tenant's Dockerfile is plain text"} }
	if ($text =~ r#'[\x{00A0}\x{1680}\x{2000}-\x{200B}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]'#) { error make {msg: "a tenant's Dockerfile has non-ASCII white space (a no-break space and the like), which buildkit and the staging read differently: a tenant's Dockerfile is plain text"} }
	# the staging swaps text for `__TENANT_COMMENT_<n>__` and `__TENANT_MOUNT_<n>__` placeholders while it works and swaps it back: a Dockerfile that has the word could smuggle text across
	if ($text | str contains '__TENANT_') { error make {msg: "a tenant's Dockerfile has `__TENANT_`, a word the engine's staging keeps for itself"} }
	let official = '(?i)^\s*(#|//)\s*syntax\s*=\s*docker/dockerfile(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?\s*$'
	mut out = []
	mut leading = true
	mut pending = []
	mut ins = []
	for line in ($text | split row "\n") {
		let bare = ($line | str replace --regex '\r$' '')
		# a heredoc body is content, up to its terminator
		if ($pending | is-not-empty) {
			$out = ($out | append $line)
			# a terminator is the line itself; with `<<-` leading tabs (and only tabs) are dropped first
			let want = ($pending | first)
			let seen = if $want.dash { $bare | str trim --left --char "\t" } else { $bare }
			if $seen == $want.word { $pending = ($pending | skip 1) }
			continue
		}
		if ($ins | is-empty) {
			if $leading {
				if ($bare | str trim | is-empty) or ($bare =~ '^\s*(#|//)') {
					if ($bare =~ '(?i)^\s*(#|//)\s*escape\s*=') { error make {msg: "a tenant's Dockerfile has an `escape=` directive, which moves the character a continuation line joins with: a tenant's build uses the default"} }
					if ($bare =~ '(?i)^\s*(#|//)\s*syntax\s*=') {
						if not ($bare =~ $official) { error make {msg: "a tenant's Dockerfile has a `# syntax=` directive, which picks a build frontend of its own: a tenant's build uses the buildkitd's built-in one"} }
						continue
					}
					$out = ($out | append $line)
					continue
				}
				$leading = false
			}
			# a comment between instructions, or a blank line
			if ($bare =~ '^\s*(#|$)') { $out = ($out | append $line); continue }
		} else if ($bare =~ '^\s*(#|$)') {
			# a comment or blank line inside a continued instruction is skipped by the parser: it joins the instruction as it is
			$ins = ($ins | append $line)
			continue
		}
		$ins = ($ins | append $line)
		if ($bare =~ '\\[ \t]*$') { continue }
		let done = (stage-instruction ($ins | str join "\n") $namespace)
		$ins = []
		$out = ($out | append $done.text)
		$pending = ($pending | append $done.heredocs)
	}
	if ($ins | is-not-empty) { $out = ($out | append (stage-instruction ($ins | str join "\n") $namespace).text) }
	let staged = ($out | str join "\n")
	frontend-check $staged
	$staged
}

# What buildkit reads at the head of a Dockerfile to pick a build frontend, applied to exactly the bytes bake is sent: the BOM and a leading shebang line are skipped (so a directive an earlier
# strip left at the head, or a BOM that was internal until then, is seen), and a JSON Dockerfile, or a `syntax` or an `escape` directive among the leading comments and blank lines, is refused.
def frontend-check [staged: string] {
	let body = ($staged | str replace --regex '^\x{FEFF}' '' | str replace --regex '^#![^\n]*\n' '' | str replace --regex '^\x{FEFF}' '')
	if ($body | str trim | str starts-with '{') { error make {msg: "a tenant's Dockerfile is JSON, which buildkit reads a frontend directive from: a tenant's Dockerfile is plain"} }
	for line in ($body | split row "\n") {
		let bare = ($line | str replace --regex '\r$' '' | str replace --all --regex '\x{FEFF}' '')
		if not (($bare | str trim | is-empty) or ($bare =~ '^\s*(#|//)')) { break }
		if ($bare =~ '(?i)^\s*(#|//)\s*escape\s*=') { error make {msg: "a tenant's Dockerfile has an `escape=` directive, which moves the character a continuation line joins with: a tenant's build uses the default"} }
		if ($bare =~ '(?i)^\s*(#|//)\s*syntax\s*=') { error make {msg: "a tenant's Dockerfile has a `# syntax=` directive, which picks a build frontend of its own: a tenant's build uses the buildkitd's built-in one"} }
	}
}

# The words of an instruction as the Dockerfile parser splits them: on white space and on a backslash before a line end, outside quotes; a backslash outside single quotes escapes the next
# character. The quotes stay in the word (they are what delimits a heredoc's name, `<<'END DOC'`).
def shell-words [text: string]: nothing -> list<string> {
	let chars = ($text | split chars)
	let n = ($chars | length)
	mut words = []
	mut cur = ""
	mut quote = ""
	mut i = 0
	while $i < $n {
		let c = ($chars | get $i)
		if $quote != "" {
			$cur = $cur ++ $c
			if $c == $quote { $quote = "" } else if $c == "\\" and $quote == '"' and ($i + 1) < $n { $cur = $cur ++ ($chars | get ($i + 1)); $i = $i + 1 }
		} else if $c == "'" or $c == '"' {
			$quote = $c
			$cur = $cur ++ $c
		} else if $c == "\\" and ($i + 1) < $n and (($chars | get ($i + 1)) in ["\n" "\r"]) {
			# a continuation: white space (and the line end, with a \r before the \n). Buildkit joins the lines with no separator, so a heredoc word that a continuation splits
			# (`<<#A\` then `B`) would be read as one word there and as two here: it is refused, not guessed.
			if ($cur == "<" or ($cur | str starts-with "<<")) {
				let after = ($chars | skip ($i + 1) | skip while {|x| $x in ["\r" "\n"] } | first 1)
				if ($after | is-not-empty) and not (($after | first) in [" " "\t"]) { error make {msg: "a tenant's Dockerfile splits a heredoc word across a continuation line: a tenant's heredoc word is on one line"} }
			}
			if ($cur | is-not-empty) { $words = ($words | append $cur); $cur = "" }
			$i = $i + 1
			if ($chars | get $i) == "\r" and ($i + 1) < $n and ($chars | get ($i + 1)) == "\n" { $i = $i + 1 }
		} else if $c == "\\" and ($i + 1) < $n {
			$cur = $cur ++ $c ++ ($chars | get ($i + 1))
			$i = $i + 1
		} else if $c in [" " "\t" "\n" "\r"] {
			if ($cur | is-not-empty) { $words = ($words | append $cur); $cur = "" }
		} else {
			$cur = $cur ++ $c
		}
		$i = $i + 1
	}
	if ($cur | is-not-empty) { $words = ($words | append $cur) }
	$words
}

# One logical instruction (its continuation lines joined with "\n"): a RUN (or ONBUILD RUN) has its mount flags made safe; the heredoc terminators it opens are answered, so their bodies are left alone.
def stage-instruction [ins: string, namespace: string]: nothing -> record {
	# a heredoc is opened by RUN, COPY and ADD (ONBUILD included), by a word that begins with `<<` and has a name (buildkit's `^<<(-?)\s*([^<]*)$`, the name unquoted)
	let keyword = ($ins | parse --regex '(?is)^\s*(?:ONBUILD\s+)?(?<k>[A-Za-z]+)' | get -o 0.k | default "" | str uppercase)
	# Buildkit joins the lines of a continued instruction with no separator and reads a heredoc from a word that is `<<` (or a file descriptor and `<<`) and a name: a hand split of the words
	# keeps diverging from it (a word joined to the next line's `<<`, a name joined across lines), so every ambiguous form is refused: a RUN, COPY or ADD that has a continuation and `<<`
	# anywhere (once its lines are joined as buildkit joins them), and any heredoc word with a backslash or split across a continuation. A heredoc is read only in a one-line instruction.
	if $keyword in [RUN COPY ADD] and ($ins =~ '\\[ \t]*\r?\n') and (($ins | str replace --all --regex '\\[ \t]*\r?\n' '') =~ '<<') {
		error make {msg: "a tenant's Dockerfile has `<<` in a RUN, COPY or ADD with a continuation line: buildkit joins the lines with no separator and reads a heredoc from the joined words, so a tenant's heredoc is in an instruction of one line"}
	}
	# A heredoc word is `<<NAME`, `<<-NAME` (with a file descriptor before it or not) and NAME is a plain name, bare or in one pair of quotes: every other word that has `<<` outside quotes
	# is refused (a quote, `$`, `\`, `#`, a space, a here-string or `<<` inside a word), and so is `<<` anywhere in an ONBUILD, which buildkit reads in a later build.
	if ($ins =~ '(?i)^\s*ONBUILD\s') and ($ins =~ '<<') {
		error make {msg: "a tenant's Dockerfile has `<<` in an ONBUILD instruction, which buildkit reads as a heredoc, or not, in a later build: a tenant's ONBUILD has none"}
	}
	let words = if $keyword in [RUN COPY ADD] { shell-words $ins } else { [] }
	let plain = r#'^\d*<<-?(?:[A-Za-z_][A-Za-z0-9_]*|'[A-Za-z_][A-Za-z0-9_]*'|"[A-Za-z_][A-Za-z0-9_]*")$'#
	let unquoted = {|w| $w | str replace --all --regex r#'"[^"]*"|'[^']*''# '' }
	let odd = ($words | where {|w| (do $unquoted $w) =~ '<<' and not ($w =~ $plain) })
	if ($odd | is-not-empty) { error make {msg: $"a tenant's Dockerfile has the word ($odd | first) with `<<` in it, which is not a plain heredoc word: a tenant's heredoc is <<NAME, <<-NAME, <<'NAME' or <<\"NAME\", with a name of letters, digits and underscores"} }
	let heredocs = ($words | where {|w| $w =~ $plain } | each {|w|
		let m = ($w | parse --regex '^\d*<<(?<dash>-?)(?<name>.*)$' | first)
		{word: ($m.name | str replace --all --regex r#'["']'# ''), dash: ($m.dash == "-")}
	})
	let m = ($ins | parse --regex '(?s)^(?<head>\s*(?i:ONBUILD\s+)?(?i:RUN))(?<flags>(?:[ \t]+|\\[ \t]*\r?\n(?:[ \t]*(?:#[^\n]*)?\r?\n)*)*(?:--\S+(?:[ \t]+|\\[ \t]*\r?\n(?:[ \t]*(?:#[^\n]*)?\r?\n)*)*)*)(?<rest>.*)$')
	if ($m | is-empty) { return {text: $ins, heredocs: $heredocs} }
	let parts = ($m | first)
	{text: $"($parts.head)((stage-run-flags $parts.flags $namespace))($parts.rest)", heredocs: $heredocs}
}

# The flags of one RUN, with every cache mount's id made the namespace's own.
def stage-run-flags [flags: string, namespace: string]: nothing -> string {
	# a comment line inside a continuation is skipped by buildkit: it is neither validated nor rewritten, and comes back as it was
	let lines = ($flags | split row "\n")
	mut kept = []
	mut comments = []
	for i in 0..(($lines | length) - 1) {
		let l = ($lines | get $i)
		if $i > 0 and ($l =~ '^[ \t]*#') {
			$kept = ($kept | append $"__TENANT_COMMENT_($comments | length)__")
			$comments = ($comments | append $l)
		} else { $kept = ($kept | append $l) }
	}
	let flags = ($kept | str join "\n")
	if ($flags =~ '(?i)--mount(\s|$)') { error make {msg: "a tenant's Dockerfile gives --mount without `=`: a tenant's mount flags are --mount=type=..."} }
	let found = ($flags | parse --regex '(?i)(?<flag>--mount=\S*)' | get flag | uniq | sort-by {|f| $f | str length } --reverse)
	mut out = $flags
	mut made = []
	for i in 0..(($found | length) - 1) {
		if ($found | is-empty) { break }
		let flag = ($found | get $i)
		let value = ($flag | str replace --regex '(?i)^--mount=' '')
		if ($value | str contains '$') { error make {msg: $"a tenant's Dockerfile has the mount flag ($flag), which names a variable: a build argument would expand to a cache id outside the namespace's"} }
		if ($value =~ r#'["'`\\]'#) { error make {msg: $"a tenant's Dockerfile has the mount flag ($flag), with a quote or an escape character in it: a continuation line could append a second id, so a tenant's mount flags are plain"} }
		let fields = ($value | split row ',' | each {|f| let kv = ($f | split row -n 2 '='); let k = ($kv | get 0 | str lowercase); let v = ($kv | get -o 1 | default ""); {k: $k, v: (if $k == "type" { $v | str lowercase } else { $v })} })
		# buildkit takes the last of a repeated key: a mount that repeats type, id or its target (dst and destination are the same key) is refused, so the one the rewrite reads is the one buildkit does
		for key in [[type] [id] [target dst destination]] {
			if ($fields | where {|f| $f.k in $key } | length) > 1 { error make {msg: $"a tenant's Dockerfile has the mount flag ($flag), which repeats ($key | first): buildkit reads the last one"} }
		}
		let kind = ($fields | where k == "type" | get -o 0.v | default "")
		let placeholder = $"__TENANT_MOUNT_($i)__"
		$out = ($out | str replace --all $flag $placeholder)
		if $kind != "cache" {
			$made = ($made | append {placeholder: $placeholder, flag: $flag})
			continue
		}
		let target = ($fields | where {|f| $f.k in [target dst destination] } | get -o 0.v | default "")
		if ($target | is-empty) { error make {msg: $"a tenant's Dockerfile has the cache mount ($flag), which names no target"} }
		let given = ($fields | where k == "id" | get -o 0.v | default "")
		if ($given | str contains '..') or ($given | str contains '/') { error make {msg: $"a tenant's Dockerfile has the cache mount id ($given), with `..` or `/` in it: a tenant's cache ids are plain names"} }
		let id = if ($given | is-empty) { $target } else { $given }
		let kept = ($fields | where k != "id" | each {|f| if ($f.v | is-empty) { $f.k } else { $"($f.k)=($f.v)" } })
		$made = ($made | append {placeholder: $placeholder, flag: $"--mount=($kept | append $"id=($namespace)/($id)" | str join ',')"})
	}
	for m in $made { $out = ($out | str replace --all $m.placeholder $m.flag) }
	for i in 0..(($comments | length) - 1) {
		if ($comments | is-empty) { break }
		$out = ($out | str replace $"__TENANT_COMMENT_($i)__" ($comments | get $i))
	}
	$out
}

# The services a tenant's release builds, and what they build from: the requested ones, then every service a requested one waits for (`depends_on`)
# or takes a build context from (`additional_contexts` of `service:` and `target:`), transitively. The compose project (YAML text) comes back with
# only those services: a service outside the set (a CI profile with build secrets) is never read for build options, staged or handed to bake. The keys that name another service at
# run time only (`network_mode`, `ipc` and `pid` as `service:<x>`, `volumes_from`, `links`, `external_links`) are dropped from what is kept: a build never reads them, and none may name a service that was left out.
# Taken AFTER `runtime release-tree`, which renames the services a build takes a context from (`service:<x>-served` becomes `service:<x>-served-release`).
export def build-closure [roots: list<string>]: string -> string {
	let doc = ($in | from yaml)
	let all = ($doc | get -o services | default {})
	mut wanted = ($roots | uniq)
	mut todo = $wanted
	while ($todo | is-not-empty) {
		let name = ($todo | first)
		$todo = ($todo | skip 1)
		let svc = ($all | get -o $name)
		if $svc == null { continue }
		let deps = ($svc | get -o depends_on | default [])
		let waits = if ($deps | describe | str starts-with "record") { $deps | columns } else { $deps | each {|d| $d | into string } }
		let build = ($svc | get -o build)
		let ctxs = if ($build | describe | str starts-with "record") { $build | get -o additional_contexts | default {} } else { {} }
		let values = if ($ctxs | describe | str starts-with "record") { $ctxs | values } else { $ctxs | each {|l| $l | into string | split row -n 2 '=' | last } }
		let takes = ($values | each {|v| $v | into string | parse --regex '^(?:service|target):(?<n>.+)$' | get -o 0.n } | compact)
		for n in ($waits | append $takes) {
			if not ($n in $wanted) { $wanted = ($wanted | append $n); $todo = ($todo | append $n) }
		}
	}
	let runtime_only = {|svc|
		let plain = ($svc | reject --optional volumes_from links external_links)
		["network_mode" "ipc" "pid"] | reduce --fold $plain {|key, acc|
			if (($acc | get -o $key | default "" | into string) | str starts-with "service:") { $acc | reject $key } else { $acc }
		}
	}
	let kept = ($all | transpose name v | where {|s| $s.name in $wanted } | reduce --fold {} {|s, acc| $acc | insert $s.name (do $runtime_only $s.v) })
	$doc | update services $kept | to yaml
}

# What a tenant's compose project may say about a build, read from the staged compose config (a service's `build`): the keys that reach past the build context or pick where its cache
# comes from or goes to (`cache_from`, `cache_to`, `ssh`, `secrets`, `network`, `extra_hosts`, `entitlements`, an inline Dockerfile) and a BUILDKIT_SYNTAX build argument are refused, and an
# additional context is a path inside the app, another service or stage of the project, or a docker-image:// pinned by its sha256 digest (the database stage's base): never an
# image that can move. Fails with every problem, before anything is built.
export def check-build-keys []: string -> nothing {
	let doc = ($in | from yaml)
	mut problems = []
	for s in (($doc | get -o services | default {}) | transpose name v) {
		let build = ($s.v | get -o build)
		if $build == null or not ($build | describe | str starts-with "record") { continue }
		let at = $"services.($s.name).build"
		for key in [cache_from cache_to ssh secrets network extra_hosts entitlements dockerfile_inline privileged] {
			if ($build | get -o $key) != null { $problems = ($problems | append $"($at).($key) reaches past a tenant's build context or picks where its cache comes from: a tenant's build is the buildkitd's own") }
		}
		let args = ($build | get -o args | default {})
		let names = if ($args | describe | str starts-with "record") { $args | columns } else { $args | each {|a| $a | into string | split row '=' | first } }
		if ("BUILDKIT_CACHE_MOUNT_NS" in $names) { $problems = ($problems | append $"($at).args names BUILDKIT_CACHE_MOUNT_NS, which the engine sets to the namespace's own") }
		# an extension key (x-bake and the like) is read by bake as build options of its own
		let ext = ($build | columns | where {|k| $k =~ '(?i)^x-' })
		if ($ext | is-not-empty) { $problems = ($problems | append $"($at) has the extension key\(s\) ($ext | str join ', '), which bake reads as build options") }
		let sext = ($s.v | columns | where {|k| $k =~ '(?i)^x-' })
		if ($sext | is-not-empty) { $problems = ($problems | append $"services.($s.name) has the extension key\(s\) ($sext | str join ', '), which bake reads as build options") }
		if ("BUILDKIT_SYNTAX" in $names) { $problems = ($problems | append $"($at).args names BUILDKIT_SYNTAX, which picks a build frontend of its own") }
		let ctxs = ($build | get -o additional_contexts | default {})
		let values = if ($ctxs | describe | str starts-with "record") { $ctxs | values } else { $ctxs | each {|l| $l | into string | split row -n 2 '=' | last } }
		for c in $values {
			let v = ($c | into string)
			if ($v | str starts-with "docker-image://") and not ($v =~ '@sha256:[0-9a-f]{64}$') { $problems = ($problems | append $"($at).additional_contexts names ($v), an image a tag can move: a tenant's build pins its images by digest") }
		}
	}
	if ($problems | is-not-empty) { error make {msg: $"a tenant's build is refused before it is made: ($problems | str join '; ')"} }
}

# What the engine's own constants say a tenant's release is: the tenants' sandboxed buildkitd and the node's registry as the push reaches it.
export def check-pins [node: record] {
	let buildkit = ($node.tenant?.buildkit? | default "")
	if not ($buildkit =~ '^tcp://buildkitd\.pronto-buildkit-tenants\.svc(\.cluster\.local)?:1234$') {
		error make {msg: $"a tenant's build is the tenants' buildkitd \(tcp://buildkitd.pronto-buildkit-tenants.svc:1234\), not ($buildkit)"}
	}
	let r = $node.build.registry
	if $r.host != "127.0.0.1:5000" or $r.port != 5000 or $r.namespace != "pronto-registry" {
		error make {msg: $"a tenant's registry is the node's \(127.0.0.1:5000, pronto-registry), not ($r.host) \(($r.namespace)\)"}
	}
}

# The service accounts a tenant's pods never run as (`#TenantForbiddenAccounts`), the volume types they may mount (`#TenantVolumeTypes`) and the annotation prefixes
# they never carry (`#TenantRefusedAnnotationPrefixes`) are the schema's: the cluster's admission policies (`#TenantAdmission`) read the same lists.

# Every container of a tenant's Deployment or Job (init and ephemeral included) that leaves allowPrivilegeEscalation unset is made to say
# false, in trusted code, before `check-objects` and any apply; one that says true stays true, and `check-objects` refuses it.
export def harden-objects [objects: list]: nothing -> list {
	let boxed = {|spec|
		["containers" "initContainers" "ephemeralContainers"] | reduce --fold $spec {|key, acc|
			if ($acc | get -o $key) == null { $acc } else {
				$acc | update $key ($acc | get $key | each {|c|
					if ($c.securityContext?.allowPrivilegeEscalation? | default null) == null { $c | upsert securityContext ($c.securityContext? | default {} | upsert allowPrivilegeEscalation false) } else { $c }
				})
			}
		}
	}
	$objects | each {|o|
		match ($o.kind? | default "") {
			"Deployment" | "Job" => { if ($o.spec?.template?.spec? | default null) == null { $o } else { $o | update spec.template.spec (do $boxed $o.spec.template.spec) } }
			# Upstream renders the postgres superuser on (`enableSuperuserAccess: true` and a `superuserSecret`): a tenant's database has none, so the engine says
			# so before check-objects holds the Cluster to it. What upstream's schema and migration Jobs connect as with that password (PRONTO-2066) is theirs to move.
			# CloudNativePG defaults an omitted postgresUID and postgresGID to 26, and the approved image's postgres user is 999: said here, so the object the API server sees is the one the check approved.
			"Cluster" => {
				let uid = (schema-export '#TenantClusterSpec' | get uid)
				$o | update spec (($o.spec? | default {}) | reject -o superuserSecret | upsert enableSuperuserAccess false | upsert postgresUID ($o.spec?.postgresUID? | default $uid) | upsert postgresGID ($o.spec?.postgresGID? | default $uid))
			}
			_ => $o
		}
	}
}

# A Postgres setting's value in the unit its bound is in (`#TenantParameters`): null when it is not written as that kind of value.
def parameter-value [kind: string, raw: any, base: int = 1]: nothing -> any {
	let text = ($raw | into string | str trim)
	match $kind {
		"int" => { if $text =~ '^-?[0-9]+$' { $text | into int } else { null } }
		"real" => { if $text =~ '^-?[0-9]+(\.[0-9]+)?$' { $text | into float } else { null } }
		"mem" => {
			let m = ($text | parse --regex '^(?<n>[0-9]+)\s*(?<u>kB|MB|GB|TB)?$')
			if ($m | is-empty) { null } else {
				($m.0.n | into int) * (match $m.0.u { "kB" => 1, "MB" => 1024, "GB" => 1048576, "TB" => 1073741824, _ => $base })
			}
		}
		"ms" => {
			let m = ($text | parse --regex '^(?<n>-?[0-9]+)\s*(?<u>ms|s|min|h|d)?$')
			if ($m | is-empty) { null } else {
				($m.0.n | into int) * (match $m.0.u { "s" => 1000, "min" => 60000, "h" => 3600000, "d" => 86400000, _ => 1 })
			}
		}
		_ => null
	}
}

# What a tenant's Cluster says about its Postgres settings that `#TenantParameters` refuses: a name it does not list, or a value out of its bound.
def parameter-problems [parameters: record]: nothing -> list<string> {
	let allowed = (schema-export '#TenantParameters')
	$parameters | transpose name value | each {|p|
		let rule = ($allowed | get -o $p.name)
		if $rule == null {
			$"sets the Postgres parameter ($p.name), which a tenant's database may not"
		} else if $rule.kind == "enum" {
			if ($p.value | into string) not-in $rule.values { $"sets ($p.name) to ($p.value), not one of ($rule.values | str join ', ')" }
		} else {
			let v = (parameter-value $rule.kind $p.value ($rule | get -o base | default 1))
			if $v == null { $"sets ($p.name) to ($p.value), which is not a ($rule.kind) value" } else if $v < $rule.min or $v > $rule.max { $"sets ($p.name) to ($p.value), outside what a tenant's database may have" }
		}
	} | compact
}

# What the engine's CUE refuses, checked again in nushell over the objects the game's own release.cue rendered (its `nodeManifests` is
# the author's, so the schema's `violations` are only as good as the schema it loaded): every object is a kind the publisher writes, in
# the tenant's namespace; a Service is a ClusterIP with no externalIPs; a pod's service account is not the publisher's, its images are
# the tenant's own path of the registry, and it asks for no user namespace, host namespace, privilege, unmasked /proc or unconfined
# seccomp or AppArmor. Said before anything is applied or asked of the server.
# The names of the Clusters the tenant's namespace already holds, as its publisher reads them: an older database, named as its author liked, whose operator-made
# service account (`<cluster>-db`, or the name the operator gave it then) no workload of this release may run as.
export def approved-cluster-image [image: any, node: record]: nothing -> bool {
	if $image == null or ($image | describe) != "string" { return false }
	let prefix = $"127.0.0.1:5000/($node.namespace)/"
	(schema-export '#TenantDatabaseImages' | any {|a| $image == $"($prefix)($node.name)-database-base:($a.major)@($a.digest)" })
}

# The Secrets the Clusters already in the namespace name as their `superuserSecret` (a legacy Cluster with superuser access on keeps the login whatever this release
# renders): no workload of this release reads them either.
export def live-superuser-secrets [namespace: string]: nothing -> list<string> {
	let r = (^kubectl get clusters.postgresql.cnpg.io -n $namespace -o json --ignore-not-found | complete)
	if $r.exit_code != 0 { error make {msg: $"reading the Clusters of ($namespace) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return [] }
	$r.stdout | from json | get -o items | default [] | each {|c| $c.spec?.superuserSecret?.name? | default "" } | where {|n| $n != "" }
}

export def live-clusters [namespace: string]: nothing -> list<string> {
	let r = (^kubectl get clusters.postgresql.cnpg.io -n $namespace -o json --ignore-not-found | complete)
	if $r.exit_code != 0 { error make {msg: $"reading the Clusters of ($namespace) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return [] }
	$r.stdout | from json | get -o items | default [] | each {|c| $c.metadata?.name? | default "" } | where {|n| $n != "" }
}

export def check-objects [objects: list, node: record, kinds: list<string>, live: list<string> = [], live_secrets: list<string> = []] {
	let ns = $node.namespace
	let prefix = $"127.0.0.1:5000/($ns)/"
	let refused_metadata = (schema-export '#TenantRefusedMetadata')
	let reserved = (schema-export '#TenantReserved')
	let forbidden_accounts = (schema-export '#TenantForbiddenAccounts')
	let account_suffix = (schema-export '#TenantAccountSuffix')
	let guarded_suffixes = (schema-export '#TenantGuardedSecretSuffixes')
	let tes = (schema-export '#TenantExternalSecret')
	let cluster_note_prefixes = (schema-export '#TenantRefusedClusterAnnotationPrefixes')
	let label_prefixes = (schema-export '#TenantRefusedLabelPrefixes')
	let volume_types = (schema-export '#TenantVolumeTypes')
	let sidecar_prefixes = (schema-export '#TenantRefusedAnnotationPrefixes')
	# the database operator names a Cluster's service account after the Cluster, and a Cluster is named as its author likes: every Cluster's
	# name is an account no pod of the release runs as (and the release's own is `<release>-db`, nothing else)
	let clusters = ($objects | where {|o| ($o.kind? | default "") == "Cluster" } | each {|o| $o.metadata?.name? | default "" } | append $live | uniq)
	# the secrets that hold the postgres superuser's password: each Cluster's superuserSecret and its `<cluster>-superuser` (the bootstrap secret is the owner's, and a reserved owner is refused above)
	let guarded_secrets = ($objects | where {|o| ($o.kind? | default "") == "Cluster" } | each {|c| [($c.spec?.superuserSecret?.name? | default "")] } | flatten | append ($clusters | each {|c| $"($c)-superuser" }) | append $live_secrets | where {|n| $n != "" } | uniq)
	let problems = ($objects | each {|o|
		let id = $"($o.kind? | default '?')/($o.metadata?.name? | default '?')"
		# an ExternalSecret whose spec is no object is refused, and read as an empty one by the checks below (a string has no cell paths)
		let bad_spec = (($o.kind? | default "") == "ExternalSecret" and (($o.spec? | default {} | describe) !~ '^record'))
		let o = if $bad_spec { $o | upsert spec {} } else { $o }
		mut why = []
		# a name kubectl is handed (rollback reads the Deployments' revisions by it) is a resource name, never an option
		if not (($o.metadata?.name? | default "" | into string) =~ '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$') { $why = ($why | append $"($id) is not named as a Kubernetes resource is") }
		# …on the object, and on the metadata a controller copies onto the objects it makes: a pod template's (a ReplicaSet and a Job copy
		# finalizers onto every pod, which then never finish terminating), a CronJob's, an ExternalSecret's target template
		for at in [[metadata] [spec template metadata] [spec jobTemplate spec template metadata] [spec target template metadata]] {
			for field in $refused_metadata {
				if ($o | get -o ($at | into cell-path) | default {} | get -o $field) != null { $why = ($why | append $"($id) sets ($at | append $field | str join '.'), which a tenant's release leaves to the engine") }
			}
		}
		# an ExternalSecret that takes a Secret of the namespace as a template source (target.template.templateFrom[].secret) copies it into its target Secret, which a workload may read:
		# never a Secret that holds a database's superuser password (indirect read of what the workload check below holds back)
		if ($o.kind? | default "") == "ExternalSecret" {
			let sources = ($o.spec?.target?.template?.templateFrom? | default [] | each {|t| $t.secret?.name? | default "" } | where {|n| $n != "" })
			let held = ($sources | where {|n| $n in $guarded_secrets or ($n | str ends-with $"($node.name? | default '')-db-postgres") or ($guarded_suffixes | any {|x| $n | str ends-with $x }) })
			if ($held | is-not-empty) { $why = ($why | append $"($id) takes the secret\(s\) ($held | str join ', ') as a template source, which hold the postgres superuser's password: a tenant's ExternalSecret never copies them") }
		}
		# PRONTO-2146: and one that reads a store (a ClusterSecretStore or a SecretStore, by spec.secretStoreRef, data, extract, find or sourceRef.storeRef) is read by the operator's
		# external-secrets controller with the store's own credentials: a tenant's ExternalSecret draws a Password generator's value alone (#TenantExternalSecret, the same list the
		# schema's violations and the -engine-externalsecrets admission policy hold)
		if ($o.kind? | default "") == "ExternalSecret" {
			let es = ($o.spec? | default {})
			if $bad_spec { $why = ($why | append $"($id) has a spec that is no object \(#TenantExternalSecret\)") }
			for k in $tes.noStore {
				if ($es | get -o $k) != null { $why = ($why | append $"($id) sets spec.($k), which names a store: a tenant's ExternalSecret reads none \(#TenantExternalSecret\)") }
			}
			for k in (try { $es | columns } catch { [] }) {
				if $k not-in $tes.spec and $k not-in $tes.noStore { $why = ($why | append $"($id) sets spec.($k), which a tenant's ExternalSecret may not \(#TenantExternalSecret\)") }
			}
			for k in $tes.emptyLists {
				if ($es | get -o $k | default [] | is-not-empty) { $why = ($why | append $"($id) sets spec.($k), a lookup in a store: a tenant's ExternalSecret reads none \(#TenantExternalSecret\)") }
			}
			for row in ($es | get -o dataFrom | default [] | enumerate) {
				let e = $row.item
				if ($e | describe) !~ '^record' { $why = ($why | append $"($id) spec.dataFrom[($row.index)] is no object \(#TenantExternalSecret\)"); continue }
				let at = $"($id) spec.dataFrom[($row.index)]"
				for k in (try { $e | columns } catch { [] }) {
					if $k not-in $tes.dataFrom { $why = ($why | append $"($at) sets ($k), which a tenant's ExternalSecret may not \(#TenantExternalSecret\)") }
				}
				let src = ($e | get -o sourceRef)
				if $src == null { $why = ($why | append $"($at) has no sourceRef.generatorRef \(#TenantExternalSecret\)"); continue }
				for k in (try { $src | columns } catch { [] }) {
					if $k not-in $tes.sourceRef { $why = ($why | append $"($at).sourceRef sets ($k), a store: a tenant's ExternalSecret draws from a generator alone \(#TenantExternalSecret\)") }
				}
				let gen = ($src | get -o generatorRef)
				if $gen == null { $why = ($why | append $"($at).sourceRef has no generatorRef \(#TenantExternalSecret\)"); continue }
				for k in (try { $gen | columns } catch { [] }) {
					if $k not-in $tes.generatorRef { $why = ($why | append $"($at).sourceRef.generatorRef sets ($k), which a tenant's ExternalSecret may not \(#TenantExternalSecret\)") }
				}
				let kind = ($gen | get -o kind)
				if $kind == null { $why = ($why | append $"($at) draws from a generator with no kind \(#TenantExternalSecret.generatorKinds\)") } else if $kind not-in $tes.generatorKinds { $why = ($why | append $"($at) draws from a generator of kind ($kind), which is no Password \(#TenantExternalSecret.generatorKinds\)") }
				let gv = ($gen | get -o apiVersion)
				if $gv != null and $gv != $tes.generatorAPIVersion { $why = ($why | append $"($at) draws from a generator of ($gv), not ($tes.generatorAPIVersion) \(#TenantExternalSecret\)") }
			}
		}
		# PRONTO-2147: the Secret an ExternalSecret writes (#TenantExternalSecret). The name that reaches the controller is spec.target.name, else the object's own; a tenant's is its own,
		# created as its Owner, and never a guarded one: a Merge onto `<cluster>-superuser`, a legacy Cluster's superuserSecret (read live, which no admission policy can) or the release's
		# `<release>-db-postgres` would write the database superuser's password. Upstream's `<release>-db-postgres` alone passes, with a generated password and no template source.
		if ($o.kind? | default "") == "ExternalSecret" {
			let own = ($o.metadata?.name? | default "")
			let target = ($o.spec?.target? | default {})
			let tname = ($target | get -o name)
			if $tname != null and $tname != $own { $why = ($why | append $"($id) sets spec.target.name ($tname), which is not its own name: a tenant's ExternalSecret writes the Secret of its own name \(#TenantExternalSecret\)") }
			let policy = ($target | get -o creationPolicy)
			if $policy != null and $policy not-in $tes.creationPolicies { $why = ($why | append $"($id) sets spec.target.creationPolicy ($policy): a tenant's ExternalSecret creates its Secret as its Owner alone \(#TenantExternalSecret\)") }
			let written = ([$own] | append (if $tname != null { [$tname] } else { [] }) | uniq)
			if ($written | any {|n| $n in $guarded_secrets or ($tes.superuserSuffixes | any {|x| $n | str ends-with $x }) }) { $why = ($why | append $"($id) writes a Secret that holds a database's superuser password \(#TenantGuardedSecretSuffixes\)") }
			if ($written | any {|n| $n | str ends-with $tes.dbSecretSuffix }) {
				let want = $"($node.name? | default '')($tes.dbSecretSuffix)"
				if $own != $want { $why = ($why | append $"($id) writes a database Secret that is not ($want): a tenant's database is the release's own \(#TenantExternalSecret\)") }
				let tpl = ($target | get -o template | default {})
				if ($tpl | get -o templateFrom) != null { $why = ($why | append $"($id) sets spec.target.template.templateFrom on a database Secret \(#TenantExternalSecret\)") }
				let data = ($tpl | get -o data | default {})
				for k in (try { $data | columns } catch { [] }) {
					if $k not-in $tes.dbSecretKeys { $why = ($why | append $"($id) sets spec.target.template.data.($k) on a database Secret, which holds only username and password \(#TenantExternalSecret\)") }
				}
				let pw = ($data | get -o password)
				if $pw != null and not (($pw | into string) =~ $tes.dbSecretPassword) { $why = ($why | append $"($id) sets a database Secret's password that is no reference to a generated key, but a value of its own \(#TenantExternalSecret\)") }
			}
		}
		# a Password generator is upstream's (#TenantExternalSecret.passwordKeys): else the `-db-postgres` password it feeds is a value the tenant chose (symbolCharacters, a short length)
		if ($o.kind? | default "") == "Password" {
			let pspec = ($o.spec? | default {})
			for k in (try { $pspec | columns } catch { [] }) {
				if $k not-in $tes.passwordKeys { $why = ($why | append $"($id) sets spec.($k), which a tenant's generator may not \(#TenantExternalSecret.passwordKeys\)") }
			}
			let plen = ($pspec | get -o length)
			if $plen != null and ($plen < $tes.passwordMinLength or $plen > $tes.passwordMaxLength) { $why = ($why | append $"($id) sets spec.length outside ($tes.passwordMinLength) to ($tes.passwordMaxLength) \(#TenantExternalSecret.passwordMinLength\)") }
			let psym = ($pspec | get -o symbols)
			if $psym != null and $psym != 0 { $why = ($why | append $"($id) sets spec.symbols, which a tenant's generator has none of \(#TenantExternalSecret\)") }
		}
		# a plain Secret of a guarded name is the same write by another route
		if ($o.kind? | default "") == "Secret" {
			let n = ($o.metadata?.name? | default "")
			if $n in $guarded_secrets or ($guarded_suffixes | any {|x| $n | str ends-with $x }) { $why = ($why | append $"($id) is a name that holds a database's superuser password: a tenant's release writes no such Secret \(#TenantGuardedSecretSuffixes\)") }
		}
		# an ExternalSecret that writes its target from a manifest of its own could set what the template cannot
		if ($o.kind? | default "") == "ExternalSecret" and ($o.spec?.target?.manifest? | default null) != null { $why = ($why | append $"($id) sets spec.target.manifest, which a tenant's release leaves to the operator's store") }
		if ($reserved | any {|r| $r.kind == ($o.kind? | default "") and $r.name == ($o.metadata?.name? | default "") }) { $why = ($why | append $"($id) is an object the provisioner or the engine owns") }
		if $"($o.apiVersion? | default '')/($o.kind? | default '')" not-in $kinds { $why = ($why | append $"($id) is not a kind a tenant's publisher writes") }
		if ($o.metadata?.namespace? | default "") != $ns { $why = ($why | append $"($id) is in namespace ($o.metadata?.namespace? | default 'none'), not ($ns)") }
		# A token a Secret of this type carries is a service account's (the publisher's included): never written by a tenant's release.
		if ($o.kind? | default "") == "Secret" and ($o.type? | default "") == "kubernetes.io/service-account-token" {
			$why = ($why | append $"($id) is a service account token")
		}
		# …nor one the operators make for it: an ExternalSecret's target template is the Secret the controller writes, whose type and annotations the
		# admission policy (which reads the ExternalSecret's sources alone) never sees. A Secret that names a service account in an annotation is the
		# token controller's to fill, of any type.
		let template = ($o.spec?.target?.template? | default {})
		let given = ($o.metadata?.annotations? | default {} | columns) | append ($template.metadata?.annotations? | default {} | columns)
		if ($o.kind? | default "") == "ExternalSecret" and (($template.type? | default "") == "kubernetes.io/service-account-token") {
			$why = ($why | append $"($id) targets a service account token Secret")
		}
		if ($o.kind? | default "") in [Secret ExternalSecret] and ($given | any {|k| $k | str starts-with "kubernetes.io/service-account." }) {
			$why = ($why | append $"($id) names a service account in a kubernetes.io/service-account.* annotation: the token controller would fill it")
		}
		if ($o.kind? | default "") == "Service" {
			if ($o.spec?.type? | default "ClusterIP") != "ClusterIP" { $why = ($why | append $"($id) is a ($o.spec.type) Service: a tenant's Service is a ClusterIP") }
			if ($o.spec?.externalIPs? | default [] | is-not-empty) { $why = ($why | append $"($id) names externalIPs") }
		}
		if ($o.kind? | default "") == "Cluster" {
			if ($node.name? | default "" | is-not-empty) and ($o.metadata?.name? | default "") != $"($node.name)($account_suffix)" { $why = ($why | append $"($id) is not named ($node.name)($account_suffix): a tenant's database is the release's own") }
			# an annotation under cnpg.io/ makes the operator rewrite the instance pod (podPatch, validation, reconcilePodSpec): never a tenant's Cluster's
			let cluster_notes = ($o.metadata?.annotations? | default {} | columns | where {|k| $cluster_note_prefixes | any {|p| $k | str starts-with $p } })
			if ($cluster_notes | is-not-empty) { $why = ($why | append $"($id) carries the annotation\(s\) ($cluster_notes | str join ', '), which make the database operator rewrite the instance pod: a tenant's Cluster has none") }
			let image = ($o.spec?.imageName? | default "")
			# a tenant's Cluster runs the engine's approved database base, copied to the tenant's own path (its full image stays with the Jobs): exactly that name
			let wanted = (schema-export '#TenantDatabaseImages' | each {|a| $"($prefix)($node.name)-database-base:($a.major)@($a.digest)" })
			if $image not-in $wanted { $why = ($why | append $"($id) runs ($image), not the approved database base ($wanted | str join ' or ')") }
			let allowed = (schema-export '#TenantClusterSpec')
			let cspec = ($o.spec? | default {})
			let extra = ($cspec | columns | where {|k| $k not-in $allowed.keys })
			if ($extra | is-not-empty) { $why = ($why | append $"($id) sets the Cluster field\(s\) ($extra | str join ', '), which a tenant's database may not: its image and what runs in its pod are the engine's") }
			# no access as the postgres superuser, whose password Secret CloudNativePG would make (a superuser reaches the pod: COPY ... TO PROGRAM)
			if ($cspec.enableSuperuserAccess? | default null) != false { $why = ($why | append $"($id) does not set enableSuperuserAccess: false: a tenant's database has no superuser access") }
			if ($cspec | get -o superuserSecret | default null) != null { $why = ($why | append $"($id) sets superuserSecret, which a tenant's database may not") }
			for problem in (parameter-problems ($cspec.postgresql?.parameters? | default {})) { $why = ($why | append $"($id) ($problem)") }
			let uid = ($cspec | get -o postgresUID | default 999)
			let gid = ($cspec | get -o postgresGID | default 999)
			if $uid != $allowed.uid or $gid != $allowed.uid { $why = ($why | append $"($id) runs the database as uid ($uid) and gid ($gid): a tenant's database is the approved base's, uid ($allowed.uid)") }
			# a managed role is a login of the database (never a superuser, never one that creates roles, never a member of a role that reaches the pod or the cluster)
			let refused_roles = (schema-export '#TenantRefusedRoles')
			let refused_prefixes = (schema-export '#TenantRefusedRolePrefixes')
			let reserved_role = {|n: string| ($n in $refused_roles) or ($refused_prefixes | any {|p| $n | str starts-with $p }) }
			# the database's owner is a role CloudNativePG sets the password of from the bootstrap secret on every reconcile: never one that is the postgres superuser or the operator's own
			# CloudNativePG's owner defaults to the database's name (and the database to `app`), so the effective owner is checked, always: `database: postgres` with no owner is the superuser's
			let database = ($cspec.bootstrap?.initdb?.database? | default "app")
			let owner = (if (($cspec.bootstrap?.initdb?.owner? | default "") | is-empty) { $database } else { $cspec.bootstrap.initdb.owner })
			if ($database in (schema-export '#TenantRefusedDatabases')) or (do $reserved_role $database) { $why = ($why | append $"($id) names the database ($database), a name a tenant's database never has") }
			if (do $reserved_role $owner) { $why = ($why | append $"($id) makes the database's owner ($owner), a role a tenant's database never has: CloudNativePG would set its password from the bootstrap secret, which the tenant's pods read") }
			if ($cspec.storage? | default {} | columns | any {|k| $k not-in (schema-export '#TenantStorageKeys') }) { $why = ($why | append $"($id) sets storage fields other than size and storageClass") }
			let max_stop = (schema-export '#TenantMaxStopSeconds')
			for key in [stopDelay smartShutdownTimeout] {
				let v = ($cspec | get -o $key | default null)
				if $v != null and (($v | describe) != "int" or $v > $max_stop or $v < 0) { $why = ($why | append $"($id) sets ($key) to ($v), past the ($max_stop) seconds a tenant's database may wait") }
			}
			for role in ($cspec.managed?.roles? | default []) {
				if (do $reserved_role ($role.name? | default "")) { $why = ($why | append $"($id) manages the role ($role.name? | default '?'), a name a tenant's database never has") }
				if ($role.superuser? | default false) == true { $why = ($why | append $"($id) manages the role ($role.name? | default '?') as a superuser") }
				if ($role.createrole? | default false) == true { $why = ($why | append $"($id) manages the role ($role.name? | default '?') with createrole") }
				let member = ($role.inRoles? | default [] | where {|r| do $reserved_role $r })
				if ($member | is-not-empty) { $why = ($why | append $"($id) makes the role ($role.name? | default '?') a member of ($member | str join ', '), which a tenant's database never is") }
			}
			let pg_extra = ($cspec.postgresql? | default {} | columns | where {|k| $k not-in $allowed.postgresql })
			if ($pg_extra | is-not-empty) { $why = ($why | append $"($id) sets postgresql.($pg_extra | str join ', postgresql.'), which a tenant's database may not") }
			let bs_extra = ($cspec.bootstrap? | default {} | columns | where {|k| $k not-in $allowed.bootstrap })
			if ($bs_extra | is-not-empty) { $why = ($why | append $"($id) sets bootstrap.($bs_extra | str join ', bootstrap.'), which a tenant's database may not") }
			let init_extra = ($cspec.bootstrap?.initdb? | default {} | columns | where {|k| $k not-in $allowed.initdb })
			if ($init_extra | is-not-empty) { $why = ($why | append $"($id) sets bootstrap.initdb.($init_extra | str join ', bootstrap.initdb.'), which a tenant's database may not") }
			# a Service the operator makes for the database must stay inside the cluster: a LoadBalancer or NodePort one would publish it
			let outward = ($o.spec?.managed?.services?.additional? | default [] | where {|a| ($a.serviceTemplate?.spec?.type? | default "ClusterIP") != "ClusterIP" or ($a.serviceTemplate?.spec?.externalIPs? | default [] | is-not-empty) })
			if ($outward | is-not-empty) { $why = ($why | append $"($id) has a managed Service that is not a ClusterIP, or names externalIPs") }
		}
		# a pod that reads the postgres superuser's password (the secret of the Cluster's bootstrap owner, `<app>-db-postgres`, `<cluster>-superuser`) could log in as it and run a program
		# in the instance pod: refused before anything is written. Upstream's release reads it in its Jobs and services (PRONTO-2066): until that moves, an upstream render is refused here.
		let pod_spec = (match ($o.kind? | default "") { "Deployment" | "Job" => $o.spec?.template?.spec?, "CronJob" => $o.spec?.jobTemplate?.spec?.template?.spec?, _ => null })
		if $pod_spec != null {
			let guarded = ($guarded_secrets | append $"($node.name? | default '')-db-postgres" | where {|n| $n != "-db-postgres" })
			let refs = (
				(($pod_spec.containers? | default []) | append ($pod_spec.initContainers? | default []) | append ($pod_spec.ephemeralContainers? | default []) | each {|c|
					($c.env? | default [] | each {|e| $e.valueFrom?.secretKeyRef?.name? | default "" }) | append ($c.envFrom? | default [] | each {|e| $e.secretRef?.name? | default "" })
				} | flatten)
				| append ($pod_spec.volumes? | default [] | each {|v| [($v.secret?.secretName? | default "")] | append ($v.projected?.sources? | default [] | each {|s| $s.secret?.name? | default "" }) } | flatten)
			)
			let reads = ($refs | where {|n| $n != "" and ($n in $guarded or ($guarded_suffixes | any {|x| $n | str ends-with $x })) } | uniq)
			if ($reads | is-not-empty) { $why = ($why | append $"($id) reads the secret\(s\) ($reads | str join ', '), the postgres superuser's password: a tenant's workload never does") }
		}
		let spec = (if ($o.kind? | default "") in [Deployment Job] { $o.spec?.template?.spec? } else { null })
		if $spec != null {
			# `serviceAccount` is the deprecated spelling of `serviceAccountName`, and either may carry the account
			for account in [($spec.serviceAccountName? | default "") ($spec.serviceAccount? | default "")] {
				if $account in $forbidden_accounts { $why = ($why | append $"($id) runs as the service account ($account)") }
				# the database operator names the cluster's account `<cluster>-db` and binds it to what the database needs, which a tenant's workload never is
				if ($account | str ends-with $account_suffix) or ($account != "" and $account in $clusters) { $why = ($why | append $"($id) runs as the service account ($account), which a database's cluster owns") }
			}
			# …nor a pod the operator would take for one of the cluster's (it selects its pods, and its policies admit them, by the labels it keeps
			# under its own prefix)
			if ($o.spec?.template?.metadata?.labels? | default {} | columns | any {|k| $label_prefixes | any {|p| $k | str starts-with $p } }) { $why = ($why | append $"($id) carries a label under cnpg.io/, which marks a database's own pods") }
			# no runtime class (a sandbox or a host runtime of the node's) and no priority class (a tenant must not pre-empt the node's own pods)
			if ($spec.runtimeClassName? | default "" | is-not-empty) { $why = ($why | append $"($id) sets runtimeClassName ($spec.runtimeClassName)") }
			if ($spec.priorityClassName? | default "" | is-not-empty) { $why = ($why | append $"($id) sets priorityClassName ($spec.priorityClassName)") }
			if ($spec.hostUsers? | default true) == false { $why = ($why | append $"($id) sets hostUsers: false") }
			for key in (schema-export '#TenantRefusedHostFields') { if ($spec | get -o $key | default false) == true { $why = ($why | append $"($id) sets ($key)") } }
			for v in ($spec.volumes? | default []) {
				let kinds = ($v | columns | where {|c| $c != "name" })
				let other = ($kinds | where {|k| $k not-in $volume_types })
				if ($other | is-not-empty) { $why = ($why | append $"($id) mounts the volume ($v.name? | default '?') of type ($other | str join ', '), which a tenant's pod may not") }
			}
			if ($spec.securityContext?.seccompProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) runs with an Unconfined seccomp profile") }
			if ($spec.securityContext?.appArmorProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) runs with an Unconfined AppArmor profile") }
			let notes = ($o.spec?.template?.metadata?.annotations? | default {})
			# Dapr's sidecar is the platform's: its image, resources and ports are not a tenant's to choose
			let sidecar = ($notes | columns | where {|k| $sidecar_prefixes | any {|p| $k | str starts-with $p } })
			if ($sidecar | is-not-empty) { $why = ($why | append $"($id) sets the Dapr sidecar annotation\(s\) ($sidecar | str join ', ')") }
			if ($notes | transpose k v | any {|a| ($a.k | str starts-with "container.apparmor.security.beta.kubernetes.io/") and (($a.v | into string | str lowercase) == "unconfined") }) { $why = ($why | append $"($id) runs with an unconfined AppArmor profile") }
			let containers = (($spec.containers? | default []) | append ($spec.initContainers? | default []) | append ($spec.ephemeralContainers? | default []))
			for c in $containers {
				let image = ($c.image? | default "")
				if not ($image | str starts-with $prefix) { $why = ($why | append $"($id) container ($c.name? | default '?') runs ($image), not an image under ($prefix)") } else if not ($image =~ '@sha256:[0-9a-f]{64}$') { $why = ($why | append $"($id) container ($c.name? | default '?') runs ($image), which is pinned by tag alone: a tenant's image carries its sha256 digest") }
				if ($c.securityContext?.procMount? | default "Default") != "Default" { $why = ($why | append $"($id) container ($c.name? | default '?') sets procMount ($c.securityContext.procMount)") }
				if ($c.securityContext?.privileged? | default false) == true { $why = ($why | append $"($id) container ($c.name? | default '?') is privileged") }
				# Absent is not false: the API server lets a container escalate unless it says it may not. `harden-objects` says so before this runs.
				let escalation = ($c.securityContext?.allowPrivilegeEscalation? | default null)
				if $escalation == true { $why = ($why | append $"($id) container ($c.name? | default '?') allows privilege escalation") } else if $escalation != false { $why = ($why | append $"($id) container ($c.name? | default '?') does not set allowPrivilegeEscalation: false") }
				if ($c.securityContext?.capabilities?.add? | default [] | is-not-empty) { $why = ($why | append $"($id) container ($c.name? | default '?') adds capabilities") }
				if ($c.ports? | default [] | any {|p| ($p | get -o hostPort | default null) != null }) { $why = ($why | append $"($id) container ($c.name? | default '?') sets a hostPort") }
				if ($c.securityContext?.seccompProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) container ($c.name? | default '?') runs with an Unconfined seccomp profile") }
				if ($c.securityContext?.appArmorProfile?.type? | default "") == "Unconfined" { $why = ($why | append $"($id) container ($c.name? | default '?') runs with an Unconfined AppArmor profile") }
			}
		}
		$why
	} | flatten)
	if ($problems | is-not-empty) { error make {msg: $"a tenant's render is refused: ($problems | str join '; ')"} }
}
# `body` run as the push identity: kubectl with the kubeconfig file given, or, with none, with the pod's own account (the pod's
# service account, so KUBECONFIG is hidden and the environment must say this is a pod).
export def with-push [push_kubeconfig: string, body: closure]: nothing -> any {
	if ($push_kubeconfig | is-not-empty) {
		if not ($push_kubeconfig | path exists) { error make {msg: $"--push-kubeconfig names ($push_kubeconfig), which does not exist"} }
		with-env {KUBECONFIG: $push_kubeconfig} { do $body }
	} else {
		if ($env.KUBERNETES_SERVICE_HOST? | is-empty) { error make {msg: "a tenant's push runs as the builder pod's own account when --push-kubeconfig is empty: this is not a pod (KUBERNETES_SERVICE_HOST is unset)"} }
		do { hide-env -i KUBECONFIG; do $body }
	}
}

# The app's release.cue must have bound the tags the engine passes into Node.tenant: the namespace and host it released into are the
# ones the operator named, never ones the game's own file chose.
export def check-binding [node: record, tenant: string, host: string] {
	let bound = ($node.tenant? | default {})
	if ($bound.namespace? | default "") != $tenant or ($bound.host? | default "") != $host or $node.namespace != $tenant or $node.host != $host {
		error make {msg: $"the app's release.cue does not bind the tags tenant and tenantHost into Node.tenant \(Node.tenant.namespace is ($bound.namespace? | default 'unset'), --tenant is ($tenant); Node.tenant.host is ($bound.host? | default 'unset'), --host is ($host)\)"}
	}
	# The release registers OIDC clients at the origin and skips the door's probes for a preview with no host: both are the operator's host alone.
	if ($node.preview? | default "" | is-not-empty) { error make {msg: "a tenant's release is never a preview: Node.preview must be empty"} }
	if ($node.origin? | default "") != $"https://($host)" { error make {msg: $"a tenant's origin is https://($host), the operator's host, not the Node's ($node.origin? | default 'unset')"} }
}

# What a tenant's release never does, said before anything is built or written: it decrypts no SOPS file with the cluster's key (the
# operator's), and it runs no hook (the release.cue's own commands would run with its publisher's and its pusher's credentials).
export def tenant-refusals [app_dir: string, node: record] {
	let sops = ($node.secrets? | default "secrets.metal.enc.yaml")
	if ($app_dir | path join $sops | path exists) {
		error make {msg: $"a tenant's release decrypts no secrets with the cluster's key: ($sops) is the operator's"}
	}
	if ($node.hooks.afterJobs | is-not-empty) {
		error make {msg: "a tenant's release runs no hooks: hooks.afterJobs would run the release.cue's commands with its publisher's and its pusher's credentials"}
	}
}

# `kubectl auth can-i`'s word: yes or no, never a failure of the question itself.
def --wrapped can-i [...args: string]: nothing -> bool {
	let r = (^kubectl auth can-i ...$args | complete)
	if $r.exit_code != 0 and ($r.stdout | str trim) != "no" { error make {msg: $"kubectl auth can-i ($args | str join ' '): ($r.stderr | str trim)"} }
	($r.stdout | str trim) == "yes"
}

# The namespace is the provisioner's and the KUBECONFIG its publisher's, though a publisher cannot read a namespace: the rights to release in
# it are asked, an operator's (it may create namespaces) is refused, and the namespace's own record (the ConfigMap pronto-release) must
# be absent or say this app, which only a tenant's release writes: one app per tenant namespace.
export def check-namespace [node: record] {
	let ns = $node.namespace
	if not (can-i create deployments.apps -n $ns) { error make {msg: $"this KUBECONFIG may not release into ($ns): a tenant's release runs as the namespace's publisher"} }
	if (can-i create namespaces) { error make {msg: "this KUBECONFIG may create namespaces, so it is an operator's: release without --tenant"} }
	let r = (^kubectl get configmap pronto-release -n $ns --ignore-not-found -o json | complete)
	if $r.exit_code != 0 { error make {msg: $"reading the record of ($ns) failed: ($r.stderr | str trim)"} }
	if ($r.stdout | str trim | is-empty) { return }
	let app = ($r.stdout | from json | get -o data.app | default "")
	if ($app | is-empty) { error make {msg: $"namespace ($ns) holds an operator's release (pronto-release names no tenant app): not a tenant's to change"} }
	if $app != $node.name { error make {msg: $"namespace ($ns) records the release of ($app): one app per tenant namespace"} }
}

# What the push identity must be allowed, asked before anything is built, and only what the chosen path uses: the registry pod's port-forward
# and the registry's lease (a path that builds, the only one that asks at all) and, with `--door` (a live release: a check never checks the
# door), the Envoy Gateway's Service reads and, off the cluster, its data plane's port-forward.
export def check-push-rights [node: record, push_kubeconfig: string, --door] {
	# A live release run in the builder pod (no push kubeconfig) checks the door by dialling the gateway's Service from the pod, which the
	# pod's NetworkPolicy must admit: a builder says so with PRONTO_BUILDER_GATEWAY_EGRESS=1, set only where its policy reaches the gateway's
	# data plane. Without it the rollout would run and the door check time out after it, so it is refused before anything is built or written.
	if $door and ($push_kubeconfig | is-empty) and (($env.PRONTO_BUILDER_GATEWAY_EGRESS? | default "") != "1") {
		error make {msg: "this builder pod does not declare that its network policy reaches the Envoy Gateway (PRONTO_BUILDER_GATEWAY_EGRESS=1), so a live tenant release's door check could not run after the rollout: release from a builder whose policy does, or with --push-kubeconfig"}
	}
	with-push $push_kubeconfig {
		let registry = $node.build.registry.namespace
		# Off the cluster (a kubeconfig is given) the door check forwards to the gateway's pod; in the builder pod it dials the Service's
		# ClusterIP, so the pod's account needs no port-forward in the gateway's namespace.
		let forward = ($door and ($push_kubeconfig | is-not-empty))
		let push_role = "studio-builder-push"
		let gateway_role = "studio-builder-gateway"
		for ask in ([
			# the registry's pod is found by label and forwarded to
			{verb: "get pods", args: [get pods -n $registry], where: $registry, role: $push_role}
			{verb: "list pods", args: [list pods -n $registry], where: $registry, role: $push_role}
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n $registry], where: $registry, role: $push_role}
			{verb: "create leases.coordination.k8s.io", args: [create leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			# the lease is acquired (create), read (get), renewed (patch) and released (delete); listing and replacing leases are the collector's alone
			{verb: "get leases.coordination.k8s.io", args: [get leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			{verb: "patch leases.coordination.k8s.io", args: [patch leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
			{verb: "delete leases.coordination.k8s.io", args: [delete leases.coordination.k8s.io -n $registry], where: $registry, role: $push_role}
		] | append (if $door { [
			# the door check lists the gateway's Services by label, and reads each
			{verb: "get services", args: [get services -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "list services", args: [list services -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
		] } else { [] }) | append (if $forward { [
			# forwarding to a Service finds a pod behind it, then forwards to that pod
			{verb: "get pods", args: [get pods -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "list pods", args: [list pods -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
			{verb: "create pods/portforward", args: [create pods --subresource=portforward -n envoy-gateway-system], where: "envoy-gateway-system", role: $gateway_role}
		] } else { [] })) {
			if not (can-i ...$ask.args) { error make {msg: $"the push identity may not ($ask.verb) in ($ask.where): it needs the Role ($ask.role) \(services/buildkit-tenants\)"} }
		}
	}
}

# Waits until the port-forward `pid` answers on `port`; fails with kubectl's message when it died or never did.
def wait-forward [pid: int, port: int, log: string, --seconds: int = 30] {
	let deadline = ((date now) + ($seconds * 1sec))
	loop {
		let up = ((^kill -0 $pid | complete).exit_code == 0)
		if $up and (tunnel answers $port) { return }
		if not $up { error make {msg: $"the registry's kubectl port-forward closed: (open --raw $log | str trim)"} }
		if (date now) > $deadline { error make {msg: $"the registry's kubectl port-forward did not answer on 127.0.0.1:($port) in ($seconds) s: (open --raw $log | str trim)"} }
		sleep 250ms
	}
}

# `body` run with a port-forward, as the push identity, to the node's registry pod: `{|port| ... }`, the local port. The forward goes on
# every exit path.
export def with-registry-forward [push_kubeconfig: string, body: closure]: nothing -> any {
	with-push $push_kubeconfig {
		let pods = (^kubectl get pods -n pronto-registry -l app=registry -o json | complete)
		if $pods.exit_code != 0 { error make {msg: $"reading the node's registry pod failed: ($pods.stderr | str trim)"} }
		let running = ($pods.stdout | from json | get items | where {|p| ($p.status?.phase? | default "Running") == "Running" })
		if ($running | is-empty) { error make {msg: "the node's registry has no pod to push to"} }
		let pod = {stdout: ($running | first | get metadata.name), stderr: "", exit_code: 0}
		let local = (tunnel free-ports 1 | first)
		let log = (mktemp -t registry-forward.XXXXXX | str trim)
		let started = (^sh -c $"kubectl port-forward -n pronto-registry 'pod/($pod.stdout | str trim)' '($local):5000' >'($log)' 2>&1 & echo $!" | complete)
		if $started.exit_code != 0 { rm -f $log; error make {msg: $"kubectl port-forward did not start: ($started.stderr | str trim)"} }
		let pid = ($started.stdout | str trim | into int)
		let out = (try {
			wait-forward $pid $local $log
			{ok: (do $body $local)}
		} catch {|e|
			^kill $pid | complete | ignore
			rm -f $log
			error make {msg: $e.msg}
		})
		^kill $pid | complete | ignore
		rm -f $log
		$out.ok
	}
}
