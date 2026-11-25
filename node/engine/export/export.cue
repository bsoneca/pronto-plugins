// One app's node release engine files: `cue export ./node/engine/export -e files --out json`, each
// path from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/node/engine"

// `-t releaseRule=true` (bin/pronto-node --engine --release-rule): also merge the `release@k8s` rule into `.say.json`.
_releaseRule: *false | bool @tag(releaseRule,type=bool)

files: (engine.#Host & {releaseRule: _releaseRule}).files
