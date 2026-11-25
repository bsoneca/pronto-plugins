// One app's iOS host files, by tag: `cue export ./ios/export -t app=<name> [-t label=<label>] [-t base=<url>]
// [-t package=<program.cue's package>] [-t config=<the app's ios/ios.json>] -e files --out json`, each path from the
// app's root to {seed, text}.
package export

import (
	"encoding/json"

	"github.com/bsoneca/pronto-plugins/ios"
)

_app:     string                              @tag(app)
_label:   *_app | string                      @tag(label)
_base:    string | *"https://\(_app).invalid" @tag(base)
_package: *"" | string                        @tag(package)
_config:  *"{}" | string                      @tag(config)
_unlock: [if json.Unmarshal(_config).unlock != _|_ {json.Unmarshal(_config).unlock}, "none"][0]
_entitlements: [if json.Unmarshal(_config).entitlements != _|_ {json.Unmarshal(_config).entitlements}, {}][0]
_marketingVersion: [if json.Unmarshal(_config).marketingVersion != _|_ {json.Unmarshal(_config).marketingVersion}, "0.1.0"][0]
_buildNumber: [if json.Unmarshal(_config).buildNumber != _|_ {json.Unmarshal(_config).buildNumber}, 1][0]

files: (ios.#Host & {app: _app, label: _label, base: _base, package: _package, unlock: _unlock, entitlements: _entitlements, marketingVersion: _marketingVersion, buildNumber: _buildNumber}).files
