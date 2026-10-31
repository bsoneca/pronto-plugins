# Assembles the Firebase Hosting site, dist/firebase, from pronto's pages
# bundle: dist/browser/index.html as the site's index.html, and every file a
# host-DOM hatch declares at its own path. The bundle serves its files from a
# table inside the page; a hatch's module, imported by URL, and the documents a
# hatch navigates to or frames are fetched past that table, so Hosting must
# serve them. The list is the program's, read by the rule at each release
# (`cue export` of every host-DOM hatch's files) and handed in, never copied.
#
# Written into the app by pronto-firebase; regenerated, do not edit.
export def main [hatchFiles: string] {
	let bundle = "dist/browser/index.html"
	if not ($bundle | path exists) { error make {msg: $"($bundle) is missing: the bundle runs first"} }
	let files = ($hatchFiles | from json | uniq | sort)
	for f in $files {
		if ($f | str starts-with "/") or ($f | path split | any {|p| $p == ".."}) { error make {msg: $"($f) is not a path inside the app"} }
		if $f == "index.html" { error make {msg: "index.html is the bundle; no file may replace it"} }
		if not ($f | path exists) { error make {msg: $"($f) is declared by a hatch and missing"} }
	}
	rm -rf dist/firebase
	mkdir dist/firebase
	cp $bundle dist/firebase/index.html
	for f in $files {
		let dst = ("dist/firebase" | path join $f)
		mkdir ($dst | path dirname)
		cp $f $dst
	}
	print $"firebase: dist/firebase holds index.html and ($files | length) hatch file\(s\)"
}
