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
		$text | save --force --raw $path
	}
}

# The door's route to flagd, which pronto's writer regenerates without it. An
# earlier run's goes first. The door tells flagd which host a request reached,
# over whatever header a page sent: the flags' `local` values are the door's
# word, never the page's.
export def route [] {
	let route = [
		$begin
		"  handle /ofrep/* {"
		# An evaluation's context is a few fields; a kilobyte is plenty.
		"    request_body {"
		"      max_size 16KB"
		"    }"
		"    reverse_proxy {$PRONTO_UPSTREAM_FLAGD:flagd:8693} {"
		"      header_up dapr-app-id flagd"
		"      header_up Host {upstream_hostport}"
		"      header_up X-Pronto-Host {host}"
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
