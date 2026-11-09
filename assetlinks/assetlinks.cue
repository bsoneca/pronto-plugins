// The Digital Asset Links an app's door serves at /.well-known/assetlinks.json, written by each host
// that has an Android build (unity's player, android's terminal) into the app's own declaration. Each
// host states its package, its relations and its signing certificates as `_assetlinks: <package>`, a
// field of the app's package that every host file shares; each file then declares the one file the
// door serves, from all of them, with the same expression, so two hosts make one file and never two.
package assetlinks

import (
	"encoding/json"
	"strings"
)

// Lets an app's links open the package.
#Links: "delegate_permission/common.handle_all_urls"
// Lets the package use the credentials, passkeys among them, of the door's relying party.
#Credentials: "delegate_permission/common.get_login_creds"

// The SHA-256 of a signing certificate, as Android prints it: 32 bytes in colon-separated upper-case hex.
#Fingerprint: string & =~"^[0-9A-F]{2}(:[0-9A-F]{2}){31}$"

// One host's statement, as CUE source: its package's relations and the certificates that sign it.
#Statement: S={
	package: string & =~"^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
	relation: [...(#Links | #Credentials)] & [_, ...]
	fingerprints: [...#Fingerprint] & [_, ...]
	text: "_assetlinks: \(json.Marshal(S.package)): {relation: \(json.Marshal(S.relation)), fingerprints: \(json.Marshal(S.fingerprints))}"
}

// The imports #Declaration needs in the file that holds it.
#Imports: ["encoding/json", "list"]

// The file the door serves, from every host's statements, by package: the same text in every file that holds it.
#Declaration: strings.Join([
	"code: meta: wellKnown: \"assetlinks.json\": text: json.Indent(json.Marshal([for p in list.SortStrings([for k, _ in _assetlinks {k}]) {",
	"relation: _assetlinks[p].relation, target: {namespace: \"android_app\", package_name: p, sha256_cert_fingerprints: _assetlinks[p].fingerprints}",
	"}]), \"\", \"  \") + \"\\n\"",
], "")
