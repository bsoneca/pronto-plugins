// Errors: what an app's pages throw, reported to the operator's GlitchTip (a Sentry-protocol
// server, errors/metal.nu). The page's own small reporter (errors.js) sends each uncaught error,
// unhandled rejection and failed load to the app's door, which routes it to GlitchTip's ingest, so
// the page's policy (connect-src 'self') holds.
//
// This file is written into the app's own package (errors_plugin.cue), so every name here is
// prefixed: it sits beside the program's.
package errors

// What the app says of its project at GlitchTip. `project` and `key` are the ones `bin/pronto-errors
// metal` prints for the app's project; the key is public by design (every page sends it), so it
// is written here, not kept secret. Until both are written the reporter does nothing.
#Errors: E={
	// GlitchTip's id of the project, which the operator makes with `metal --projects`. 0: none yet.
	project: *0 | int & >=0
	// The project's public key: 32 hex digits. Empty: none yet.
	key: *"" | =~"^[0-9a-f]{32}$"
	// Where the door sends the reports in production; a host launch sends them to a stand-in.
	upstream: *"https://errors.invalid" | =~"^https://[a-z0-9.-]+(:[0-9]+)?$"
	// The address the door takes the reports at on the page's own origin; GlitchTip's own paths
	// (`/api/<project>/envelope/`) follow it.
	prefix: *"/e" | =~"^/[a-z0-9_-]+$"
	// The pronto-flags flag (flags_spec.cue) that turns the reporter on.
	flag: *"error_tracking" | =~"^[a-z][a-z0-9_-]{0,63}$"

	// The files the generate step writes: the reporter's settings, beside its module.
	out: {
		"errors.loader.json": {project: E.project, key: E.key, prefix: E.prefix, flag: E.flag}
	}
}
