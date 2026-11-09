// The Unity host: a pronto app opts into being drawn by pronto-csharp's host (a C# terminal on Jint,
// UI Toolkit, github.com/bsoneca/pronto-csharp) with one declaration of its own, unity_surface.cue,
// which this writes. Without it the app has no Unity file and the host stages nothing of it.
//
// The declaration says, as data: which of the program's screens get a Unity surface and the look
// (USS) of each; which of its hostDom hatches the host draws, by name, each bound to the app's own
// JavaScript module (unity/hatches/<name>/binding.cue), never C#; which scenarios the host runs; and which of its unit suites run there (the rest are the server's, with the reason) and whether its scenarios
// need its stack. The host reads only what it lists, from unity/unity.json, the same declaration as
// JSON, written beside it: it never finds a file by its name.
package unity

import (
	"encoding/json"
	"list"
	"strings"
	"struct"

	"github.com/bsoneca/pronto-plugins/assetlinks"
)

// A path in the app, from its root, never out of it.
// A leading dot is a dot-folder of the app (.pronto/), not a way out of it.
#Path: string & =~"^[A-Za-z0-9_.][A-Za-z0-9_./-]*$" & !~"(^|/)\\.\\.(/|$)" & !~"^\\.$"
#Name: string & =~"^[a-z][a-z0-9_-]*$"
// A host name an https link names: lowercase labels, no port, no scheme.
#LinkHost: string & =~"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$"
// An Android application id.
#Package: string & =~"^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
// The SHA-256 of a signing certificate, as Android prints it: 32 bytes in colon-separated upper-case hex.
#Fingerprint: string & =~"^[0-9A-F]{2}(:[0-9A-F]{2}){31}$"

// A hatch's binding (the app's unity/hatches/<name>/binding.cue, exported to binding.json): the app's own pure
// JavaScript module and what the hatch may see of its screen and do to it. The contract:
// github.com/bsoneca/pronto-csharp/blob/main/docs/pronto-unity-hatch-contract.md
#HatchBinding: {
	// The app's module (ES module; imports allowed), from the app's root.
	module: #Path & =~"\\.m?js$"
	// What the hatch sees of its screen, re-read before every call: rows of the elements a selector matches.
	reads: {[=~"^[A-Za-z_][A-Za-z0-9_]*$"]: {
		select: string & !=""
		attrs: [...string & !=""]
	}}
	// The only forms it may fill and submit (selectors of the screen's forms), and the only elements it may click.
	submits: [...string & !=""]
	clicks: *[] | [...string & !=""]
	// Present: the host calls tick() at this rate while the screen is open.
	tick?: {hz: int & >0 & <=120}
	// With tick: the held controls the host passes in.
	input?: [...string & !=""]
	if input != _|_ if tick == _|_ {input: _|_}
}

// What an app declares.
#Surface: {
	// The screens drawn on Unity, each a screen of the program, with its look: the screen's own
	// sheet and the sheets it shares with others, matched against the same markup the web draws.
	screens: {[#Name]: {
		uss: #Path & =~"\\.uss$"
		shared: [...#Path & =~"\\.uss$"]
	}}
	// The program's hostDom hatches the host draws, by name. A map gives each its binding (the generated
	// binding.json beside the app's binding.cue); the older list of names, or a name with no binding, is
	// not mounted: the screen falls back to its markup.
	hatches: [...#Name] | {[#Name]: {binding?: #Path & =~"\\.json$"}}
	// The scenarios the host runs, each a CUE file of the shared scenario schema: the app's own
	// (tests/scenarios/…) or ones written for Unity (unity/scenarios/…).
	scenarios: [...#Path & =~"\\.cue$"]
	// The app's unit suites (tests/unit/suites.cue) and where each runs. A suite is not all-or-nothing: the ones that
	// call the app's modules or a pronto machine run on the host, through tests/unit/registry.js; one that runs SQL on a
	// database (PGlite, Postgres) or reaches a server is left to it, named here with the reason, so the host counts it
	// as server-only and never as a failure. Every suite the app has is in one list or the other.
	suites: {
		// The suites run on the host: "all" of them, or the ones named.
		host: "all" | [...#Name]
		// The suites left to the server, each with why.
		server: {[#Name]: string & !=""}
	}
	// Whether its scenarios need its running stack (a door).
	cluster: bool
	// More of the app a hatch reads, beyond shell/, messages/ and tests/unit/.
	stage: [...#Path]
	// The app on Android: https links of `links` open the app's player (`package`) rather than the browser, as
	// an intent filter its build writes, and verified, by the assetlinks.json the app's door then serves for the
	// signing certificates named. A sign-in comes back to the app this way (the door's handoff code).
	android: {
		package: #Package
		links: [...#LinkHost]
		fingerprints: [...#Fingerprint]
	}
}

// The host the app's check runs on, a mise tool (private: mise needs GITHUB_TOKEN to fetch it), released from
// github.com/bsoneca/pronto-csharp by tools/release.sh.
#Tools: {"github:bsoneca/pronto-csharp": "0.1.0"}

#Host: H={
	// The app's CUE package, which unity_surface.cue joins.
	package!: string & =~"^[a-z][a-z0-9_]*$"
	// The bindings the app wrote (unity/hatches/<name>/binding.cue), each checked here and written as binding.json.
	bindings: {[#Name]: #HatchBinding}
	// A binding belongs to a hatch the declaration maps to its binding.json.
	for n, _ in H.bindings {
		if H.surface.hatches[n].binding == _|_ {_unmapped: (n): _|_}
		_bound: (n): H.surface.hatches[n].binding & "unity/hatches/\(n)/binding.json"
	}
	// The declaration, from the installer's arguments over the one the app already has.
	surface: #Surface & {
		screens: {[S=_]: {uss: *"unity/screens/\(S).uss" | _, shared: *[] | _}}
		hatches: *[] | _
		scenarios: *[] | _
		suites: {host: *"all" | _, server: *{} | _}
		cluster: *false | _
		stage: *[] | _
		// The generic host's player, until an app is built as a player of its own.
		android: {package: *"com.bsoneca.prontohost" | _, links: *[] | _, fingerprints: *[] | _}
	}
	// At least one screen: an opt-in that draws nothing is not one.
	surface: screens: struct.MinFields(1)

	// A suite runs here or is the server's, never both.
	_hostList: [...string]
	if H.surface.suites.host != "all" {_hostList: H.surface.suites.host}
	_clash: [for n in _hostList if H.surface.suites.server[n] != _|_ {n}]
	_clash: []

	// What the door serves at /.well-known/assetlinks.json (Digital Asset Links): the player may open its links. Links are
	// verified only for certificates named, so links with none (they would open the browser, never the app) are refused.
	if len(H.surface.android.links) > 0 {_assetlinks: json.Indent(json.Marshal([{
		relation: ["delegate_permission/common.handle_all_urls"]
		target: {namespace: "android_app", package_name: H.surface.android.package, sha256_cert_fingerprints: H.surface.android.fingerprints & [_, ...]}
	}]), "", "  ")}
	_linked: len(H.surface.android.links) > 0
	_wellKnown: [
		if H._linked {"""

			// The door serves the Digital Asset Links of the app's Android player, so its links open it,
			// beside any other host's (assetlinks).
			\((assetlinks.#Statement & {package: H.surface.android.package, relation: [assetlinks.#Links], fingerprints: H.surface.android.fingerprints}).text)
			\(assetlinks.#Declaration)
			"""},
		"",
	][0]
	// The map form when any hatch is bound: a name with no binding is listed and not mounted.
	_mapForm: len(H.bindings) > 0
	_boundNames: list.SortStrings([for n, _ in H.bindings {n}])
	_imports: list.SortStrings(list.Concat([[if H._mapForm || H._linked {"list"}], [if H._linked {"encoding/json"}]]))
	_import: [
		if len(H._imports) == 1 {"\nimport \"\(H._imports[0])\"\n"},
		if len(H._imports) > 1 {"\nimport (\n" + strings.Join([for i in H._imports {"\t\"\(i)\""}], "\n") + "\n)\n"},
		"",
	][0]
	_iter: [if H._mapForm {"h, _"}, "h"][0]
	// What `cue vet` (lint) can say of a binding: its hatch is drawn on a screen Unity draws, and no submits
	// selector is empty. Whether the module file exists is for pronto-unity to refuse when it writes, as CUE cannot stat.
	_boundLines: [for h in H._boundNames {
		"\t\t\"\(h)\": {screens: [for s, _ in unity.screens if code.surface.screens[s].hatches != _|_ if list.Contains(code.surface.screens[s].hatches, \"\(h)\") {s}] & [_, ...], submits: \(json.Marshal(H.bindings[h].submits)) & [...string & !=\"\"]}"
	}]
	_boundBlock: [if H._mapForm {"\n\t// Each bound hatch is on a screen drawn on Unity and names no empty form selector.\n\tbound: {\n" + strings.Join(H._boundLines, "\n") + "\n\t}"}, ""][0]

	// The `unity` verb, which sayt does not have: `./saytw unity` (platform local) stages the app from its folder into the
	// released host, runs its unit cases and its scenarios, and exits non-zero when any fails. A scenario that needs the
	// app's stack is skipped, as the host does, unless PRONTO_DOOR_<APP> names its door. sayt's builtin for a custom verb
	// is `true`, which would stop the rules after it, so it is off.
	miseConf: """
		[tools]
		"github:bsoneca/pronto-csharp" = "\(#Tools["github:bsoneca/pronto-csharp"])"

		"""
	rules: unity: local: {
		platform: "local"
		cmds: [{do: "use tools.nu [run-mise]; let host = (run-mise where github:bsoneca/pronto-csharp | str trim); run-mise exec -- bash ($host | path join tools unity-check.sh) ."}]
	}

	_header: "generated by pronto-unity from unity/host.cue — do not edit"
	_manifest: json.Indent(json.Marshal({generated: H._header, for k, v in H.surface {(k): v}}), "", "  ")

	files: {
		// sayt reads one .say.json; `self.verbs` declares the verb, the rule answers it (merged beside other hosts' keys).
		".say.json": {
			seed:  false
			merge: true
			text:  json.Indent(json.Marshal({say: {self: verbs: ["unity"], for verb, r in H.rules {(verb): rulemap: {builtin: null, for k, v in r {(k): v}}}}}), "", "  ") + "\n"
		}
		".config/mise/conf.d/unity.toml": {seed: false, text: H.miseConf}
		"unity_surface.cue": {
			seed: false
			text: """
				// \(H._header)
				package \(H.package)
				\(H._import)
				// The app's Unity surface: what pronto-csharp's host draws of it, and nothing else. The
				// host reads unity/unity.json, this declaration as JSON. Refresh both with pronto-unity.
				unity: \(json.Indent(json.Marshal(H.surface), "", "\t"))

				// Each screen and hatch it names is the program's own: one it lacks fails `cue vet` (lint).
				unityOfProgram: {
					routes: {for s, _ in unity.screens {(s): code.surface.screens[s].route}}
					hatches: [for \(H._iter) in unity.hatches {code.capabilities.hatches[h].kind & "host-dom"}]\(H._boundBlock)
				}
				\(H._wellKnown)
				"""
		}
		"unity/unity.json": {seed: false, text: H._manifest + "\n"}
		// Each binding as JSON for the host, generated from the app's binding.cue: never edited.
		for n, b in H.bindings {
			"unity/hatches/\(n)/binding.json": {seed: false, text: json.Indent(json.Marshal({generated: "generated by pronto-unity from unity/hatches/\(n)/binding.cue — do not edit", for k, v in b {(k): v}}), "", "  ") + "\n"}
		}
		// Each sheet named, seeded once, then the app's look.
		for s, v in H.surface.screens {
			(v.uss): {seed: true, text: "/* The Unity look of a screen: USS over its markup (data-x=\"v\" is class x--v). */\n"}
		}
		for s, v in H.surface.screens for p in v.shared {
			(p): {seed: true, text: "/* The Unity look of a screen: USS over its markup (data-x=\"v\" is class x--v). */\n"}
		}
	}
	// A refresh of an opt-in that named different sheets leaves the old ones: they are the app's.
}
