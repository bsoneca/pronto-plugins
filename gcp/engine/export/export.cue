// One app's release engine files: `cue export ./gcp/engine/export -e files --out json`, each path
// from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/gcp/engine"

files: (engine.#Host & {}).files
