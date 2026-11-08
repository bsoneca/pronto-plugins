// One app's modular-design host files, by tag: `cue export ./modular-design/export
// -t package=<pkg> -t module=<cue module path> [-t fresh=false] -e files --out json`, each
// path from the app's root to {seed, merge?, text}.
package export

import modulardesign "github.com/bsoneca/pronto-plugins/modular-design:modulardesign"

_package: string       @tag(package)
_module:  string       @tag(module)
_fresh:   *true | bool @tag(fresh,type=bool)

files: (modulardesign.#Host & {
	package: _package
	module:  _module
	fresh:   _fresh
}).files
