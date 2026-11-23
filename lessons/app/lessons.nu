# The lessons host's generate step: the app's `lessons: courses:` (lessons_spec.cue) written where its readers read it.
# Written by pronto-lessons; regenerated, do not edit.
#
#   lessons write --sql spec/lessons_spec.sql --js hatch-src/src/lessons_spec.js [--messages messages]
#
# from `cue export . -e _lessonsOut` (lessons_plugin.cue): the database's spec (a raw migration), the page's courses, and the
# lines of every message key in each locale's catalogue (messages/<locale>.json).

# A file rewritten only when its text changes, so a generate that changes nothing leaves every watch and build cache
# where it was.
def save-changed [path: path] {
	let text = $in
	if not ($path | path exists) or (open --raw $path) != $text {
		mkdir ($path | path dirname)
		# Replaced in one rename: a reader never sees it half-written.
		let tmp = $"($path).($nu.pid).tmp"
		$text | save --force --raw $tmp
		mv --force $tmp $path
	}
}

# A catalogue's text with the courses' entries replaced: every `lesson_<course>_*` entry is dropped and the course's
# entries (the lines, as the last of the file) written again, the rest of it untouched. A course whose id begins another's
# (toy, toy_saga) is dropped with it, and both are written again, as an app's courses are all in one spec. The file must be
# laid out as JSON.stringify(_, null, 2) lays it out (one entry a line, two spaces, `}` alone on the last): an empty `{}` is
# one too, and any other layout is an error, never a second copy of an entry. (tests/unit/lessons_db.js `rewrite` is this,
# in JS: change both.)
export def catalogue [text: string, entries: string, courses: list<string>]: nothing -> string {
	if ($courses | is-empty) { return $text }
	let empty = $text =~ '^\{\s*\}\s*$'
	let dropped = $courses | reduce --fold $text {|c, t| $t | str replace --all --regex $"\(?m\)^  \"lesson_($c)_[a-z0-9_]+\": .*\n" "" }
	for c in $courses {
		if ($dropped =~ $"\"lesson_($c)_[a-z0-9_]+\"\\s*:") {
			error make {msg: $"lessons: a catalogue entry lesson_($c)_* is not laid out with two spaces, one a line"}
		}
	}
	let trim = '(?s),?\s*\n\}\s*$'
	if not $empty and not ($dropped =~ $trim) {
		error make {msg: "lessons: a catalogue must end with a `}` on a line of its own"}
	}
	let kept = if $empty { "{" } else { $dropped | str replace --regex $trim "" }
	if ($entries | is-empty) { $"($kept)\n}\n" } else if ($kept | str ends-with "{") { $"($kept)\n($entries)\n}\n" } else { $"($kept),\n($entries)\n}\n" }
}

export def write [--sql: path, --js: path, --messages: path = "messages"] {
	let out = ^cue export . -e _lessonsOut --out json | from json
	if $sql != null { $out.sql | save-changed $sql }
	if $js != null { $out.js | save-changed $js }
	for loc in ($out.messages | columns) {
		let path = $"($messages)/($loc).json"
		if not ($path | path exists) { error make {msg: $"lessons: no catalogue ($path) for the locale ($loc)"} }
		let text = open --raw $path
		let next = catalogue $text ($out.messages | get $loc) $out.courses
		if $next != $text { $next | save --force --raw $path }
	}
}
