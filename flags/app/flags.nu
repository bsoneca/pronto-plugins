# The flags host's generate step, run by the rule pronto/flags.cue adds,
# after pronto's writer. Written by pronto-flags; regenerated, do not edit.

const begin = "  # pronto-flags:begin — the app's feature flags, to flagd's remote evaluation (OFREP)"
const end = "  # pronto-flags:end"

# A file rewritten only when its text changes, so a generate that changes
# nothing leaves every watch and build cache where it was.
def save-changed [path: path] {
	let text = $in
	if not ($path | path exists) or (open --raw $path) != $text {
		mkdir ($path | path dirname)
		# Replaced in one rename: a reader (a gate beside a stack's generate) never sees it half-written.
		let tmp = $"($path).($nu.pid).tmp"
		$text | save --force --raw $tmp
		mv --force $tmp $path
	}
}

# The door's route to flagd, which pronto's writer regenerates without it. An
# earlier run's goes first. The door tells flagd which host a request reached,
# and which account it is from, over whatever a page sent: the flags' `local`
# values and `accounts` are the door's word, never the page's.
export def route [] {
	let route = [
		$begin
		"  handle /ofrep/* {"
		# An evaluation's context is a few fields; a kilobyte is plenty.
		"    request_body {"
		"      max_size 16KB"
		"    }"
		# `route`, so these run as written (Caddy orders directives by its own table).
		"    route {"
		# The account is the session's, the auth service's word, never the page's. forward_auth's
		# copy_headers drops a page's header too when the service names none, but the route says so
		# itself. flagd takes a body's targetingKey when the header is absent or empty, so a request
		# the session names no one for gets "no session", which no account id (no spaces) can be.
		# /auth/door always answers 2xx, which is what keeps a signed-out page's flags.
		"      request_header -X-Pronto-Account"
		"      forward_auth {$PRONTO_MESH:auth:9999} {"
		"        uri /auth/door"
		"        header_up dapr-app-id auth"
		"        copy_headers X-Pronto-Account"
		"      }"
		"      @anon not header X-Pronto-Account *"
		"      request_header @anon X-Pronto-Account \"no session\""
		"      reverse_proxy {$PRONTO_UPSTREAM_FLAGD:flagd:8693} {"
		"        header_up dapr-app-id flagd"
		"        header_up Host {upstream_hostport}"
		"        header_up X-Pronto-Host {host}"
		"      }"
		"    }"
		"  }"
		$end
	]
	let all = open --raw docker/Caddyfile | lines
	let from = $all | enumerate | where item == $begin | get index.0?
	let to = $all | enumerate | where item == $end | get index.0?
	let lines = if $from == null or $to == null { $all } else { [...($all | first $from) ...($all | skip ($to + 1))] }
	# Into the (app) snippet every listener imports, before its first route and
	# the comment that route carries.
	let at = $lines | enumerate | where {|l| $l.item | str starts-with "  handle /auth/*"} | get index.0?
	if $at == null { error make {msg: "docker/Caddyfile has no `handle /auth/*` to place the flags route before"} }
	# Another host's block ends with its end marker, which is no comment of this route's.
	let start = $at - ($lines | first $at | reverse | take while {|l| ($l | str starts-with "  #") and not ($l | str ends-with ":end")} | length)
	[...($lines | first $start) ...$route ...($lines | skip $start)] | str join "\n" | $"($in)\n" | save-changed docker/Caddyfile
}

# flagd's flag definitions, from the program's `flagd.document`, into the file
# the flagd image carries and a launch on the host reads.
export def write [] {
	$in | from json | to json --indent 2 | $"($in)\n" | save-changed flags/flags.json
}

# The flags in the app's database (the program's `flagd.sql`), into flags/flags.sql, which an app with a
# database lists among its raw migrations.
export def sql [] {
	$in | from json | save-changed flags/flags.sql
}
