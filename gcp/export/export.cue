// One app's Cloud Run host files, by tag: `cue export ./gcp/export
// -t app=<name> -t project=<id> [-t region=… -t service=… -t repository=…
// -t origin=… -t maxScale=… -t memory=…] -e files --out json`, each path from
// the app's root to {seed, merge?, text}.
package export

import "github.com/bsoneca/pronto-plugins/gcp"

_app:        string @tag(app)
_project:    string @tag(project)
_region:     *"us-central1" | string @tag(region)
_service:    *_app | string @tag(service)
_repository: *"pronto" | string @tag(repository)
_origin:     *"" | string @tag(origin)
_maxScale:   *3 | int @tag(maxScale, type=int)
_memory:     *"512Mi" | string @tag(memory)

files: (gcp.#Host & {
	app:        _app
	project:    _project
	region:     _region
	service:    _service
	repository: _repository
	origin:     _origin
	maxScale:   _maxScale
	memory:     _memory
}).files
