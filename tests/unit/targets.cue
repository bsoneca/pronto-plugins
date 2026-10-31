// `gcp/release_target.ts`: whether a program needs a server, the program with a release target
// among its meta.targets, and whether a release.cue releases into the shared project. A hosted builder loads
// this module from a clone of these plugins to give an app a server and a release.
package unit

cases: {
	// An app that keeps rows on a server, or signs people in, needs a cloud; one whose rows stay in
	// the browser is a web app.
	"a program needs a server when it keeps rows on one or signs people in": {suite: "targets", steps: [
		{call: "targets.needsCloud", args: ["code: state: entities: Booking: {durability: \"server\"}"], expect: true},
		{call: "targets.needsCloud", args: ["code: state: entities: Slot: {durability: \"live\"}"], expect: true},
		{call: "targets.needsCloud", args: ["code: capabilities: {\n\t\tauth: {required: false}\n}"], expect: true},
		{call: "targets.needsCloud", args: ["code: state: entities: Note: {durability: \"tab\"}"], expect: false},
	]}
	// pronto emits release@gcp only for a target the program lists: gcp joins the list, keeping the
	// others, a program that has it is left alone, and none listed is said as null.
	"gcp joins the program's targets, the others kept, once": {suite: "targets", steps: [
		{call: "targets.withTarget", args: ["code: meta: {\n\t\ttargets: []\n}\n", "gcp"], expect: "code: meta: {\n\t\ttargets: [\"gcp\"]\n}\n"},
		{call: "targets.withTarget", args: ["\t\ttargets: [\"pages\"]\n", "gcp"], expect: "\t\ttargets: [\"pages\", \"gcp\"]\n"},
		{call: "targets.withTarget", args: ["\t\ttargets: [\"gcp\"]\n", "gcp"], expect: "\t\ttargets: [\"gcp\"]\n"},
		{call: "targets.withTarget", args: ["code: meta: i18n: {}\n", "gcp"], expect: null},
	]}
	// An app in the shared project goes out without the warm preview: its checks ran, and a preview
	// kept warm would be a second database for every app. One elsewhere keeps its gate.
	"an app in the shared project releases without the warm preview, one elsewhere with it": {suite: "targets", steps: [
		{call: "targets.inShared", args: ["GCP: schema.#Release & {\n\tproject: \"example-shared-123\"\n}", {project: "example-shared-123", region: "us-central1"}], expect: true},
		{call: "targets.inShared", args: ["GCP: schema.#Release & {\n\tproject: \"example-other-456\"\n}", {project: "example-shared-123", region: "us-central1"}], expect: false},
		{call: "targets.inShared", args: ["GCP: schema.#Release & {\n\tproject: \"example-shared-123\"\n}", null], expect: false},
	]}
	// The release.cue it writes: release@gcp in the cloud's project, in the program's package, named
	// after the app as Cloud SQL and Cloud Run both take it.
	"the release written for an app is its own service and database in the project": {suite: "targets", steps: [
		{call: "targets.releaseCue", args: ["package myapp\n\ncode: {}\n", "my-app", {project: "example-shared-123", region: "us-central1"}], matches: "name:    \"my-app\""},
		{call: "targets.releaseCue", args: ["code: {}\n", "nameless", {project: "example-shared-123", region: "us-central1"}], throws: "names no package"},
	]}
}
