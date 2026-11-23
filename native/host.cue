// What every native host says about an app, once (docs/native-terminal.md, "The layers"): the part of
// a host's spec that names no platform. android/host.cue embeds #Core, and ios/host.cue will; each adds
// its own identifiers, toolchain, project files and association statements (assetlinks, apple-app-site-association).
package native

import "encoding/json"

// Whether the terminal's sealed storage opens only after one strong-biometric prompt
// (the host's config file, `unlock`). none: its key needs no person, nobody is prompted.
#Unlock: "none" | "biometric"

#Core: C={
	// The app's name, as pronto's meta.name says it.
	app: string
	// What the launcher, the credential picker and the unlock prompt call it.
	label: *app | string
	// Where a release build finds the app's cluster; a debug build is told at start.
	base: *"https://\(app).invalid" | string
	// The app's CUE package (program.cue's), which the host's surface file joins.
	package: *"" | string
	unlock:  *"none" | #Unlock
	// The scenarios (the app's CUE, by path from its root) the host's integrate runs on a device; none is a
	// failure there, never a pass.
	scenarios: *[] | [...string]
	// The host's config file as it is first written, and then the app's.
	configSeed: json.Indent(json.Marshal({scenarios: C.scenarios}), "", "  ") + "\n"
}
