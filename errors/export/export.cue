// One app's errors host files, by tag: `cue export ./errors/export -t package=<pkg> -e files --out json`,
// each path from the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/errors"

_package: string @tag(package)

files: (errors.#Host & {
	package: _package
}).files
