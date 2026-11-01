# The ads host's generate step, run by the rule pronto/ads.cue adds, after
# pronto's writer. Written by pronto-ads; regenerated, do not edit.

const begin = "  # pronto-ads:begin — the publisher's ads.txt, which AdSense reads to know the site is theirs"
const end = "  # pronto-ads:end"

# A file rewritten only when its text changes, so a generate that changes
# nothing leaves every watch and build cache where it was.
def save-changed [path: path] {
	let text = $in
	if not ($path | path exists) or (open --raw $path) != $text {
		mkdir ($path | path dirname)
		$text | save --force --raw $path
	}
}

# The page module's spec (ads_spec.js beside ads.js) from the app's `adsense`:
# its publisher, "" for none, which ads.js reads to choose Google's ads or the
# stand-in.
export def page [path: path] {
	let adsense = $in | from json
	[
		"// The app's AdSense publisher, from ads_spec.cue. Written by pronto-ads' generate step; regenerated, do not edit."
		$"export const publisher = ($adsense.publisher | to json);"
		""
	] | str join "\n" | save-changed $path
}

# The door's /ads.txt from the app's `adsense` (ads_spec.cue), which pronto's
# writer regenerates without it; none while the app names no publisher. An
# earlier run's goes first.
export def route [] {
	let adsense = $in | from json
	let route = if ($adsense.publisher | is-empty) { [] } else {
		[
			$begin
			"  handle /ads.txt {"
			"    header Content-Type \"text/plain; charset=utf-8\""
			$"    respond \"google.com, ($adsense.publisher), DIRECT, f08c47fec0942fa0\" 200"
			"  }"
			$end
		]
	}
	let all = open --raw docker/Caddyfile | lines
	let from = $all | enumerate | where item == $begin | get index.0?
	let to = $all | enumerate | where item == $end | get index.0?
	let lines = if $from == null or $to == null { $all } else { [...($all | first $from) ...($all | skip ($to + 1))] }
	# Into the (app) snippet every listener imports, before its first route and
	# the comment that route carries.
	let at = $lines | enumerate | where {|l| $l.item | str starts-with "  handle /auth/*"} | get index.0?
	if $at == null { error make {msg: "docker/Caddyfile has no `handle /auth/*` to place the ads route before"} }
	# Another host's block ends with its end marker, which is no comment of this route's.
	let start = $at - ($lines | first $at | reverse | take while {|l| ($l | str starts-with "  #") and not ($l | str ends-with ":end")} | length)
	[...($lines | first $start) ...$route ...($lines | skip $start)] | str join "\n" | $"($in)\n" | save-changed docker/Caddyfile
}
