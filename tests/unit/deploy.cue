// `deploy gcp` (gcp/deploy.ts, docs/intents.md) on a stand-in shop that keeps rows on a server:
// its release target written as the builder writes it, generated, its plan rendered as the dry run, its
// checks passed, and only when asked released and answering.
package unit

_apps: {project: "shared-apps", region: "us-central1", shared: "shared-apps"}
_server: "package shop\n\ncode: meta: {\n\ttargets: []\n}\ncode: state: entities: Order: {durability: \"server\"}\n"
_k8sShop: "package shop\n\nApp: schema.#ReleaseSpec & {\n\tname: \"shop\"\n\tgateway: host: \"shop-1.example\"\n}\n"
_k8sRules: "say:\n  release:\n    rulemap:\n      cloudflare:\n        platform: cloudflare\n      k8s:\n        platform: k8s\n        cmds:\n          - do: x\n"

cases: {
	"a new server app: its release target written, generated, its plan and checks passed, then it waits to be released": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", _apps]}, {keep: "out"},
		{get: "states", expect: ["done", "applied", "applied", "done", "done", "gate"]},
		{use: "out"}, {get: "notes.3", expect: "service shop in shared-apps, us-central1"},
		{use: "out"}, {get: "notes"}, {call: "probe.last", args: ["$"], matches: "--release"},
		{call: "shop.file", args: ["$shop", "release.cue"]},
		{call: "probe.holdsEach", args: ["$", ["project: \"shared-apps\"", "ssr: \"spa\""]], expect: [true, true], why: "the release target, in the project it was told"},
		{call: "shop.file", args: ["$shop", "program.cue"]},
		{call: "probe.includes", args: ["$", "targets: [\"gcp\"]"], expect: true, why: "gcp among the program's targets"},
		{call: "shop.verbs", args: ["$shop"], expect: ["generate", "lint", "test"], why: "nothing released"},
		{call: "shop.deployed", args: ["$shop", _apps & {release: true, studio: true}]},
		{pick: ["finished", "notes.6"], expect: [true, "https://shop-1.us-central1.run.app"], why: "released from the builder, it answers"},
		{call: "shop.verbs", args: ["$shop"]},
		{call: "probe.from", args: ["$", 3], expect: ["lint", "test", "release@gcp (no gate)"], why: "in the shared project, without the warm preview"},
		{call: "shop.deployed", args: ["$shop", _apps, "plan"]}, {get: "states"},
		{call: "probe.every", args: ["$", "done"], expect: true, why: "once online, a plan has nothing to do"},
	]}
	"an app in a project of its own is released with the warm preview its release tests first": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", {project: "shop-prod", region: "us-central1", release: true, shared: "shared-apps"}]},
		{get: "finished", expect: true},
		{call: "shop.verbs", args: ["$shop"]}, {call: "probe.last", args: ["$"], expect: "release@gcp"},
	]}
	"an app released to a Kubernetes cluster goes out by its own release, and answers at its gateway": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.written", args: ["$shop", "release.cue", _k8sShop]},
		{call: "shop.written", args: ["$shop", ".say.yaml", _k8sRules]},
		{call: "shop.deployed", args: ["$shop", _apps & {release: true}]},
		{pick: ["finished", "notes.1", "notes.3", "notes.6"], expect: [true, "a Kubernetes cluster", "shop at https://shop-1.example", "https://shop-1.example"]},
		{call: "shop.verbs", args: ["$shop"], expect: ["lint", "test", "release@k8s"]},
		{call: "shop.file", args: ["$shop", "program.cue"], expect: _server, why: "the author's program untouched"},
	]}
	"an app in the builder's shared project is released from the builder, not from a terminal": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", _apps & {release: true, studio: false}]}, {keep: "out"},
		{pick: ["names.5", "states.5"], expect: ["released", "gate"]},
		{use: "out"}, {get: "notes.5", matches: "from the builder"},
		{call: "shop.verbs", args: ["$shop"], expect: ["generate", "lint", "test"], why: "nothing released"},
	]}
	"a web app needs no Cloud Run, and nothing is touched": {suite: "deploy", steps: [
		{call: "shop.deploy", args: ["package shop\n\ncode: state: entities: Note: {durability: \"tab\"}\n"]}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", _apps]}, {keep: "out"},
		{get: "states", expect: ["gate"]},
		{use: "out"}, {get: "notes.0", matches: "release@pages"},
		{call: "shop.verbs", args: ["$shop"], expect: []},
		{call: "shop.file", args: ["$shop", "release.cue"], expect: null},
	]}
	"an author's release.cue declaring no release is theirs: it waits on them": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.written", args: ["$shop", "release.cue", "package shop\n\nPages: {}\n"]},
		{call: "shop.deployed", args: ["$shop", _apps]},
		{get: "states", expect: ["done", "gate"]},
		{call: "shop.file", args: ["$shop", "release.cue"], expect: "package shop\n\nPages: {}\n", why: "unchanged"},
	]}
	"a new server app told no project waits to be told one, and nothing is touched: there is no default": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", {region: "us-central1"}]}, {keep: "out"},
		{get: "states", expect: ["done", "gate"]},
		{use: "out"}, {get: "notes.1", matches: "--project <id>"},
		{call: "shop.file", args: ["$shop", "release.cue"], expect: null},
		{call: "shop.verbs", args: ["$shop"], expect: []},
	]}
	"with no shared project named, an app is released from the terminal like any other": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", {project: "shared-apps", region: "us-central1", release: true}]},
		{get: "finished", expect: true},
		{call: "shop.verbs", args: ["$shop"]}, {call: "probe.last", args: ["$"], expect: "release@gcp", why: "with the warm preview: no project is shared"},
	]}
	"in the shared project, a pronto that grants secrets on the whole project goes no further": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {call: "shop.unisolated", args: ["$"]}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", _apps & {release: true, studio: true}]}, {keep: "out"},
		{pick: ["names.3", "states.3"], expect: ["the release's plan", "gate"]},
		{use: "out"}, {get: "notes.3", matches: "other apps' secrets"},
		{call: "shop.verbs", args: ["$shop"], expect: ["generate"], why: "nothing released"},
	]}
	"an app whose checks fail is not released, and says what failed": {suite: "deploy", steps: [
		{call: "shop.deploy"}, {call: "shop.failing", args: ["$", "test"]}, {keep: "shop"},
		{call: "shop.deployed", args: ["$shop", _apps & {release: true, studio: true}]}, {keep: "out"},
		{pick: ["names.4", "states.4"], expect: ["linted and tested", "gate"]},
		{use: "out"}, {get: "notes.4", matches: "test: 1 error"},
		{call: "shop.verbs", args: ["$shop"], expect: ["generate", "lint", "test"], why: "nothing released"},
	]}
	"a release rule is found among the app's targets, not only the first": {suite: "deploy", steps: [
		{call: "deploy.hasReleaseRule", args: [_k8sRules, "k8s"], expect: true},
		{call: "deploy.hasReleaseRule", args: [_k8sRules, "gcp"], expect: false},
	]}
}
