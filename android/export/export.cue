// One app's host files, by tag: `cue export ./android/export -t app=<name> [-t label=<label>] [-t mode=terminal|vault] [-t base=<url>]
// [-t package=<program.cue's package>] [-t config=<the app's android/android.json>] -e files --out json`, each path from the
// app's root to {seed, text}.
package export

import (
	"encoding/json"

	"github.com/bsoneca/pronto-plugins/android"
)

_app:   string @tag(app)
_label: *_app | string @tag(label)
_mode:  *"terminal" | "vault" @tag(mode)
_base:  string | *"https://\(_app).invalid" @tag(base)
_package: *"" | string @tag(package)
_config:  *"{}" | string @tag(config)
_signing: [if json.Unmarshal(_config).signing != _|_ {json.Unmarshal(_config).signing}, []][0]

files: (android.#Host & {app: _app, label: _label, mode: _mode, base: _base, package: _package, signing: _signing}).files
