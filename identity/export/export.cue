// One app's identity host files, by tag: `cue export ./identity/export
// -t package=<pkg> [-t frontImage=… -t broker=… -t brokerInternal=… -t providers=a,b] -e files
// --out json`, each path from the app's root to {seed, merge?, text}; `-e
// cleanup` the paths this host once wrote, taken away while they open with
// its `removeMark` (bin/remove.nu).
package export

import (
	"strings"

	"github.com/bsoneca/pronto-plugins/identity"
)

_package:        string                             @tag(package)
_broker:         *"http://localhost:28443" | string @tag(broker)
_brokerInternal: *"" | string                       @tag(brokerInternal)
_providers:      *"" | string                       @tag(providers)
_frontImage:     *"" | string                       @tag(frontImage)

_host: identity.#Host & {
	package: _package
	broker:  _broker
	if _brokerInternal != "" {brokerInternal: _brokerInternal}
	if _providers != "" {providers: strings.Split(_providers, ",")}
	if _frontImage != "" {frontImage: _frontImage}
}
files: _host.files
cleanup: {remove: _host.remove, removeMark: _host.removeMark}
