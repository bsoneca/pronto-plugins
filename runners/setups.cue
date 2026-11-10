package runners

// bsoneca's Mac Studio: GitHub's runner on the Mac itself, no VM and no docker, for bsoneca/pronto
// (Bonk Chess's repository). Its jobs claim the machine's stack budget (pronto's tests/slot.ts).
// Images build in Cloud Build. The `arc` Colima VM it ran first stays stopped.
setups: "bsoneca-mac": {
	cluster: host: {}
	github: {owner: "bsoneca", kind: "user"}
	hostRunners: "pronto-mac": repo: "pronto"
	// Two more ci runners under the same label, so PR checks run three at a time instead of queueing
	// behind one runner; tests/slot.ts still caps what their heavy steps put on the machine.
	hostRunners: "pronto-mac-2": {repo: "pronto", labels: ["pronto-mac"]}
	hostRunners: "pronto-mac-3": {repo: "pronto", labels: ["pronto-mac"]}
	// Releases only (cd.yml's release job runs on this label): a release never waits behind ci,
	// whose queue on pronto-mac can be long. Two runners, so two apps release at once; one release
	// per app at a time is cd.yml's concurrency group, not a runner count. Never plan, mirror or
	// bisect work here: a long job there held every release behind it (2026-11-07: a 1 h 40 min
	// bisect kept six cd runs queued).
	hostRunners: "pronto-release": repo: "pronto"
	hostRunners: "pronto-release-2": {repo: "pronto", labels: ["pronto-release"]}
	// cd's jobs of seconds (cd.yml's plan, mirror and release-plan, the 10-min tick's): they never
	// queue behind ci on pronto-mac, nor behind a release on pronto-release (the user, 2026-11-07:
	// "cd must not compete with ci. They must use different queues."). One runner is enough: each
	// takes under a minute. Replaces pronto-cd, same job, a name that says what it plans.
	hostRunners: "pronto-plan": repo: "pronto"
	// The pull-request gate's runners (a gate workflow's jobs): three, so up to three gates run at
	// once and a fourth waits in GitHub's queue, the only one (queue-research-2026-11-07 s.4).
	hostRunners: "pronto-gate-1": {repo: "pronto", labels: ["pronto-gate"]}
	hostRunners: "pronto-gate-2": {repo: "pronto", labels: ["pronto-gate"]}
	hostRunners: "pronto-gate-3": {repo: "pronto", labels: ["pronto-gate"]}
	// Light jobs only (ci.yml's `changed` and its `ci` summary): they take seconds and claim no
	// slot, so a pull request's ci starts at once instead of queueing behind checks that hold the
	// pronto-mac runners while they wait in tests/slot.ts (2026-11-06: a PR's `changed` waited up to
	// 7 h, and ci took a median 6.3 h end to end).
	hostRunners: "ci-light-1": {repo: "pronto", labels: ["ci-light"]}
	hostRunners: "ci-light-2": {repo: "pronto", labels: ["ci-light"]}
	hostRunners: "ci-light-3": {repo: "pronto", labels: ["ci-light"]}
	// Bulk jobs (pronto's ci.yml heavy checks, PR #804), apart from pronto-mac so light and release
	// work never queues behind them. Three: six let a change to a file every app copies start ten
	// checks at once (20 to 29 min queue, 2026-11-07), two left a full fan-out (a change to ci.yml) at
	// 15 checks on 2 runners; gates have pronto-gate now.
	hostRunners: "pronto-bulk-1": {repo: "pronto", labels: ["pronto-bulk"]}
	hostRunners: "pronto-bulk-2": {repo: "pronto", labels: ["pronto-bulk"]}
	hostRunners: "pronto-bulk-3": {repo: "pronto", labels: ["pronto-bulk"]}
}

// bsoneca/studio-apps, the apps Studio's owner makes (pronto's apps/studio): GitHub registers a
// personal account's runners per repository, so it has runners of its own on the same Mac, under one
// label for all its jobs (its ci.yml and automerge.yml: runs-on [self-hosted, macOS, studio-apps]).
// Two, so a pull request's light jobs never wait behind a check; a check's heavy steps claim the
// machine's budget through the app's tests/slot.ts like pronto's. A setup of its own, so applying it
// registers these alone.
setups: "bsoneca-mac-studio-apps": {
	cluster: host: {}
	github: {owner: "bsoneca", kind: "user"}
	hostRunners: "studio-apps-1": {repo: "studio-apps", labels: ["studio-apps"]}
	hostRunners: "studio-apps-2": {repo: "studio-apps", labels: ["studio-apps"]}
}

// bsoneca/pronto-fork, the fork of pronto every app pins (PRONTO-217): its ci (k8s/release_test.nu
// and the deno tests that stand alone) on each pull request to its fork line. One runner under its
// own label, a setup of its own so applying it registers this alone. The repository is public, so
// its ci job runs only for pull requests from the repository itself, never a fork's.
setups: "bsoneca-mac-pronto-fork": {
	cluster: host: {}
	github: {owner: "bsoneca", kind: "user"}
	hostRunners: "pronto-fork-1": {repo: "pronto-fork", labels: ["pronto-fork"]}
}
