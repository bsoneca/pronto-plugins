package runners

// bsoneca's Mac Studio: GitHub's runner on the Mac itself, no VM and no docker, for bsoneca/pronto
// (Bonk Chess's repository). Its jobs claim the machine's stack budget (pronto's tests/slot.ts).
// Images build in Cloud Build. The `arc` Colima VM it ran first stays stopped.
setups: "bsoneca-mac": {
	cluster: host: {}
	github: {owner: "bsoneca", kind: "user"}
	hostRunners: "pronto-mac": repo: "pronto"
}
