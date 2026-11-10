package errors

import (
	"list"
	"strings"
)

// The spec as an app writes it, and what it gives the generate step.
_e: #Errors & {project: 1, key: "921d1ab3ed184f91867663937ab0002f", upstream: "https://errors.example.com"}
outFiles: list.SortStrings([for f, _ in _e.out {f}]) & ["errors.loader.json"]
loaderSettings: _e.out["errors.loader.json"] & {project: 1, key: "921d1ab3ed184f91867663937ab0002f", prefix: "/e", flag: "error_tracking"}
// An app that has written nothing is inert: no project, no key.
_blank: #Errors
blankIsInert: _blank.out["errors.loader.json"] & {project: 0, key: ""}

// The reporter: a host-DOM hatch answers every mount with its cleanup, on the early exit too.
_h: #Host & {package: "shop"}
_reporter:     _h.files["shell/hatches/errors/errors.js"].text
reporterInert: strings.Contains(_reporter, "if (started || !config.project || !config.key) return nothing;") & true
reporterEnds:  strings.Contains(_reporter, "\treturn nothing;\n}") & true
// It reports uncaught errors and failed loads (capture phase), and unhandled rejections.
reporterErrors:  strings.Contains(_reporter, "addEventListener(\"error\", onError, true);") & true
reporterRejects: strings.Contains(_reporter, "addEventListener(\"unhandledrejection\", onRejection);") & true
reporterLoads:   strings.Contains(_reporter, "new Set([\"script\", \"link\", \"img\"])") & true
// To the page's own origin, as a Sentry envelope, keeping alive, with no cookie.
reporterOrigin:    strings.Contains(_reporter, "fetch(`${config.prefix}/api/${config.project}/envelope/?sentry_key=${config.key}&sentry_version=7`") & true
reporterKeepalive: strings.Contains(_reporter, "keepalive: true,\n\t\tcredentials: \"omit\",") & true
// Only while the flag answers true, asked over OFREP on the page's own origin; what comes first is held.
reporterFlag:   strings.Contains(_reporter, "fetch(`/ofrep/v1/evaluate/flags/${config.flag}`") & true
reporterOnTrue: strings.Contains(_reporter, "(await res.json())?.value === true") & true
reporterHolds:  strings.Contains(_reporter, "if (state === \"pending\") held.push(e);") & true
reporterDrops:  strings.Contains(_reporter, "held = [];") & true
// What it sends: the page's path without query or hash, the release, no user.
reporterPath:     strings.Contains(_reporter, "request: { url: location.origin + location.pathname },") & true
reporterRelease:  strings.Contains(_reporter, "getElementById(\"pronto-assets\")") & true
reporterNoUser:   strings.Contains(_reporter, "user:") & false
reporterNoCookie: strings.Contains(_reporter, "document.cookie") & false
// Its limits: once a message, twenty events.
reporterOnce:   strings.Contains(_reporter, "if (seen.has(key)) return;") & true
reporterTwenty: strings.Contains(_reporter, "const MAX_EVENTS = 20;") & true

// The host's files, and the door's seat for the stand-in.
hostFiles: list.SortStrings([for f, _ in _h.files {f}]) & [
	"errors/errors.nu",
	"errors/standin.ts",
	"errors_hatch.cue",
	"errors_plugin.cue",
	"errors_spec.cue",
	"pronto/errors.cue",
	"pronto/exports.nu",
	"shell/hatches/errors/config.js",
	"shell/hatches/errors/errors.js",
]
specSeeded:        _h.files["errors_spec.cue"].seed & true
configSeeded:      _h.files["shell/hatches/errors/config.js"].seed & true
schemaInPackage:   strings.Contains(_h.files["errors_plugin.cue"].text, "\npackage shop\n") & true
standinHatch:      strings.Contains(_h.files["errors_hatch.cue"].text, "code: capabilities: hatches: \"errors-glitchtip\": {") & true
standinPeer:       strings.Contains(_h.files["errors_hatch.cue"].text, "PRONTO_UPSTREAM_ERRORS: {peer: \"errors\", port: \"http\"}") & true
writeBeforeWriter: strings.Contains(_h.files["pronto/errors.cue"].text, "\"priority\":-1") & true
routeAfterWriter:  strings.Contains(_h.files["pronto/errors.cue"].text, "\"priority\":3") & true
routeFromExports:  strings.Contains(_h.files["pronto/errors.cue"].text, "exports of errors") & true

// Once it knows whether it reports, it says so on the page (<html data-errors="on|off">), which a check waits for.
reporterMarks: strings.Contains(_reporter, "document.documentElement.dataset.errors = on ? \"on\" : \"off\";") & true
