// The release-notes host: after an app's release goes live, a GitHub Release on the app's repo,
// tagged <app>/<revision> (README.md). The driver and its rules are this host's, written into the
// app as release-notes/; nothing of it is seeded, since the app has nothing of its own to say.
@extern(embed)

package releasenotes

_driver: _ @embed(file="release-notes.ts", type=text)
_rules:  _ @embed(file="notes.js", type=text)

#Host: {
	files: {
		"release-notes/release-notes.ts": {seed: false, text: _driver}
		"release-notes/notes.js": {seed: false, text: _rules}
	}
}
