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
		# Replaced in one rename: a reader (a gate beside a stack's generate) never sees it half-written.
		let tmp = $"($path).($nu.pid).tmp"
		$text | save --force --raw $tmp
		mv --force $tmp $path
	}
}

# Nothing may frame the game but the game itself: any page could else frame it and drive ad views
# and clicks. The policy header carries `frame-ancestors`, which a <meta> cannot, and X-Frame-Options
# says the same to a browser that reads only that; both are appended to the game's own policy line,
# after a marker that says so.
const frame_mark = "  # pronto-ads:frame — the policy below ends with frame-ancestors 'self', and X-Frame-Options follows it"
const frame_head = "  header @terminal Content-Security-Policy \""
const frame_tail = "; frame-ancestors 'self'"
const frame_xfo = "  header @terminal X-Frame-Options SAMEORIGIN"

# An earlier run's addition taken out again, nothing else touched.
def unframe [lines: list<string>]: nothing -> list<string> {
	mut out = []
	# Where the marker is, the policy line is next and X-Frame-Options after it.
	mut after = 0
	for line in $lines {
		if $line == $frame_mark { $after = 2; continue }
		if $after == 2 and ($line | str starts-with $frame_head) {
			$after = 1
			$out = ($out | append ($line | str replace --regex "; frame-ancestors 'self'\"$" "\""))
			continue
		}
		if $after == 1 and $line == $frame_xfo { $after = 0; continue }
		$after = 0
		$out = ($out | append $line)
	}
	$out
}

# The Caddyfile's lines with the frame protection on while the app names a publisher, off otherwise: with
# none the lines are as pronto wrote them. Fails where the policy line is not there exactly once, or
# already says who may frame it (pronto's own then: this splice is to be deleted).
export def frame [lines: list<string>, on: bool]: nothing -> list<string> {
	let bare = unframe $lines
	if not $on { return $bare }
	let at = $bare | enumerate | where {|l| $l.item | str starts-with $frame_head} | get index | first 2
	if ($at | length) != 1 { error make {msg: "docker/Caddyfile has no single `header @terminal Content-Security-Policy` line to protect from framing"} }
	if ($bare | get ($at | first) | str contains "frame-ancestors") { error make {msg: "docker/Caddyfile's policy already has frame-ancestors: delete pronto-ads' frame splice (ads/ads.nu)"} }
	$bare | enumerate | each {|l|
		if $l.index == ($at | first) { [$frame_mark ($l.item | str replace --regex '"$' $"($frame_tail)\"") $frame_xfo] } else { [$l.item] }
	} | flatten
}

# What the generate step gives the page and the service from `adsense`, none while no publisher is named:
# ads/break.json, the ad document and its policy, which ads/server.ts answers /break with; and, in
# the page's module folder, ads_site.js, where its module learns the origins real ads play at.
def give [adsense: record, module: string] {
	if ($adsense.publisher | is-empty) {
		if ("ads/break.json" | path exists) { rm ads/break.json }
	} else {
		$adsense.break | to json --indent 2 | $"($in)\n" | save-changed ads/break.json
	}
	let live = ($adsense.publisher | is-not-empty)
	let site = if $live { $adsense.site } else { "" }
	let frame = if $live { $adsense.frame } else { "" }
	[
		"// Where the page may play real ads (ads_spec.cue's adsense.site and adsense.frame), and the origin of"
		"// the ad document that plays them: both empty while the app names no publisher, and then every ad is"
		"// the stand-in. Written by pronto-ads' generate step; regenerated, do not edit."
		$"export const site = ($site | to json);"
		$"export const frame = ($frame | to json);"
	] | str join "\n" | $"($in)\n" | save-changed ($module | path join ads_site.js)
}

# The door's /ads.txt and its frame protection from the app's `adsense` (ads_spec.cue), which pronto's
# writer regenerates without them; none while the app names no publisher. An earlier run's goes first.
# `module` is the folder of the page's module, where ads_site.js goes.
export def route [module: string] {
	let adsense = $in | from json
	give $adsense $module
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
	let lines = [...($lines | first $start) ...$route ...($lines | skip $start)]
	frame $lines ($adsense.publisher | is-not-empty) | str join "\n" | $"($in)\n" | save-changed docker/Caddyfile
}
