// One app's host files, by tag: `cue export ./android/export -t app=<name> [-t label=<label>] [-t mode=terminal|vault] [-t base=<url>]
// -e files --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/android"

_app:   string @tag(app)
_label: *_app | string @tag(label)
_mode:  *"terminal" | "vault" @tag(mode)
_base:  string | *"https://\(_app).invalid" @tag(base)

files: (android.#Host & {app: _app, label: _label, mode: _mode, base: _base}).files
