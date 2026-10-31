// One app's Firebase host files, by tag: `cue export ./firebase/export
// -t app=<name> -t project=<id> [-t site=… -t channel=… -t expires=…
// -t ciProvider=… -t ciAccount=…] -e files --out json`, each path from the
// app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/firebase"

_app:        string @tag(app)
_project:    string @tag(project)
_site:       *"" | string @tag(site)
_channel:    *"preview" | string @tag(channel)
_expires:    *"7d" | string @tag(expires)
_ciProvider: *"" | string @tag(ciProvider)
_ciAccount:  *"" | string @tag(ciAccount)

files: (firebase.#Host & {
	app:        _app
	project:    _project
	site:       _site
	channel:    _channel
	expires:    _expires
	ciProvider: _ciProvider
	ciAccount:  _ciAccount
}).files
