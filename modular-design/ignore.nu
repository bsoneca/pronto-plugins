# What the app's .gitignore holds for modular design: each module's deps/ (the exports a module reads, copied there by
# modules/build.nu) and each place an export is written for the join (`join` in modules/modules.cue), unless a line
# already ignores it or the folder it is in. Adds what is missing, in the app's own file, and nothing else:
# `nu modular-design/ignore.nu <app>`, run by bin/pronto-modular-design.
def main [app: path] {
	cd $app
	let file = ".gitignore"
	let have = (if ($file | path exists) { open --raw $file | lines } else { [] })
	# The places named in modules/modules.cue as literals (one built by interpolation is the app's own to ignore).
	let outs = (if ("modules/modules.cue" | path exists) { open --raw modules/modules.cue | parse --regex 'join:\s*"(?<j>[^"\\]+)"' | get j } else { [] })
	let want = ($outs | each {|j| {line: $"/($j)", dir: $"/($j | path dirname)/"} } | prepend {line: "/modules/*/deps/", dir: "/modules/*/deps/"})
	let missing = ($want | where {|w| not (($w.line in $have) or ($w.dir in $have)) } | get line | uniq)
	if ($missing | is-empty) { print "kept    .gitignore"; return }
	let text = (if ($file | path exists) { open --raw $file | str trim --right } else { "" })
	let head = (if ($text | is-empty) { "" } else { $"($text)\n\n" })
	$"($head)# The modules' exports, written by modules/build.nu beside what reads them \(modules/modules.cue).\n($missing | str join "\n")\n" | save --force --raw $file
	print $"wrote   .gitignore \(($missing | str join ', '))"
}
