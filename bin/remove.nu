# Takes away the files a host once wrote and writes no more, given
# `{remove: [path], removeMark: string}` as JSON: each path from the app's
# root, removed only while its first line still carries the mark, whatever
# the file's comment syntax, so a file the app made its own stays and is named.
def main [spec: path, app: path] {
	let s = (open --raw $spec | from json)
	for p in $s.remove {
		let dest = $app | path join $p
		if not ($dest | path exists) { continue }
		if (open --raw $dest | lines | first | default "" | str contains $s.removeMark) {
			rm $dest
			print $"removed ($p)"
		} else {
			print $"kept    ($p): its first line no longer carries ($s.removeMark)"
		}
	}
	# A directory the removals emptied goes with them.
	for d in ($s.remove | each {|p| $app | path join ($p | path dirname) } | uniq | sort --reverse) {
		if ($d != $app) and ($d | path exists) and ((ls -a $d | length) == 0) { rm $d; print $"removed ($d | path relative-to $app)/" }
	}
}
