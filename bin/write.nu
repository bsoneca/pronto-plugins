# Writes the files a host's `cue export ./<host>/export -e files --out json`
# lists into an app: each path from the app's root, overwritten unless it is
# seeded and already there, so a file the app has made its own survives a
# regeneration. A `merge` file is JSON several hosts share (sayt reads one
# .say.json): this host's keys are merged into it, its lists replaced whole,
# and the other hosts' keys kept.
def main [files: path, app: path] {
	open --raw $files | from json | transpose path spec | each {|f|
		let dest = $app | path join $f.path
		if $f.spec.seed and ($dest | path exists) {
			print $"kept    ($f.path)"
		} else if ($f.spec.merge? | default false) and ($dest | path exists) {
			open --raw $dest | from json | merge deep --strategy=overwrite ($f.spec.text | from json) | to json --indent 2 | $"($in)\n" | save --force --raw $dest
			print $"merged  ($f.path)"
		} else {
			mkdir ($dest | path dirname)
			$f.spec.text | save --force --raw $dest
			print $"wrote   ($f.path)"
		}
	} | ignore
}
