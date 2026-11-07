// One app's pronto-probe files, by tag: `cue export ./probe/export -t package=<pkg> -e files
// --out json`, each path from the app's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/probe:probe"

_package: string @tag(package)

files: (probe.#Host & {package: _package}).files
