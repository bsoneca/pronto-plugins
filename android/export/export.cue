// One app's host files, by tag: `cue export ./android/export -t app=<name> [-t label=<label>]
// -e files --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/android"

_app:   string @tag(app)
_label: *_app | string @tag(label)

files: (android.#Host & {app: _app, label: _label}).files
