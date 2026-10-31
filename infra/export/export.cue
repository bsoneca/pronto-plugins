// The infra folder's files, by tag: `cue export ./infra/export -t module=<module>@v0
// -t bucket=<state bucket> -t project=<project that holds it> -e files --out json`, each path
// from the folder's root to {seed, text}.
package export

import "github.com/bsoneca/pronto-plugins/infra"

_module:  string @tag(module)
_bucket:  string @tag(bucket)
_project: string @tag(project)

files: (infra.#Host & {
	module:  _module
	bucket:  _bucket
	project: _project
}).files
