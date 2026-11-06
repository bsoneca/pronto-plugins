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
	// whose queue on pronto-mac can be long. Same Mac; release-cron's own slot (STACK_PRIORITY=release)
	// already puts its rehearsal first on the machine.
	hostRunners: "pronto-release": repo: "pronto"
	// Light jobs only (ci.yml's `changed` and its `ci` summary): they take seconds and claim no
	// slot, so a pull request's ci starts at once instead of queueing behind checks that hold the
	// pronto-mac runners while they wait in tests/slot.ts (2026-11-06: a PR's `changed` waited up to
	// 7 h, and ci took a median 6.3 h end to end).
	hostRunners: "ci-light-1": {repo: "pronto", labels: ["ci-light"]}
	hostRunners: "ci-light-2": {repo: "pronto", labels: ["ci-light"]}
	hostRunners: "ci-light-3": {repo: "pronto", labels: ["ci-light"]}
}
