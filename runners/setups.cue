package runners

// bsoneca's Mac Studio: a Colima VM of its own (profile arc) beside the default one, runners for
// bsoneca/pronto first (Bonk Chess's repository).
setups: "bsoneca-mac": {
	cluster: colima: profile: "arc"
	github: {owner: "bsoneca", kind: "user"}
	scaleSets: "pronto-arc": repo: "pronto"
}
