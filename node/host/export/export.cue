// The node host files: `cue export ./node/host/export -e files --out json`, each path from the root of
// the directory `bin/pronto-node --host` writes into to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/node/host"

files: (host.#Host).files
