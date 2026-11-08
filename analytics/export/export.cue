// One app's analytics host files, by tag: `cue export ./analytics/export
// -t package=<pkg> [-t journeys=false] [-t module=<cue module path>] -e files --out json`, each path from the app's root to
// {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/analytics"

_package:  string @tag(package)
_journeys: *"true" | string @tag(journeys)
_module:   *"" | string     @tag(module)

files: (analytics.#Host & {
	package:  _package
	journeys: _journeys == "true"
	module:   _module
}).files
