package unit

// The cue wrapper and vetted.ts (machine/), against a small CUE module: what a vet and an export keep,
// and what the wrapper replays (PRONTO-11). Moved from bsoneca/pronto's tools/machine (PRONTO-484).
cases: "vetted.ts keeps a vet's seconds with its key and reports what a hit saves": {
	suite: "machine"
	steps: [
		{call: "machine.vetRoundTrip"},
		{keep: "r"},
		{get: "first", matches: "^run vet\\nrun \\.\\nkey [0-9a-f]{64}\\nskipped 0\\nsaved 0.00$", why: "an unseen vet is run whole, with nothing skipped or saved"},
		{use: "r"},
		{get: "second", expect: "skipped 1\nsaved 12.00", why: "after a record of a 12 s run, the same vet has no key to run: all skipped, 12 s saved"},
		{use: "r"},
		{get: "entry", expect: "12.00", why: "the entry's file holds the seconds of its evaluation"},
	]
}
cases: "vetted.ts keeps an export's seconds beside its entry and prune keeps them together": {
	suite: "machine"
	steps: [
		{call: "machine.exportRoundTrip"},
		{keep: "r"},
		{get: "keyExit", expect: 1, why: "before a store: a miss"},
		{use: "r"},
		{get: "hitExit", expect: 0},
		{use: "r"},
		{get: "saved", expect: "7\n", why: "export-saved says the 7 s CUE_RUN_SECS gave the store"},
		{use: "r"},
		{get: "files", expect: ["entry", "entry.secs"], why: "the entry and its seconds; the orphan's seconds file is gone after a prune"},
	]
}
cases: "the cue wrapper replays an unchanged export it ran at once, outside the pool (PRONTO-11)": {
	suite: "machine"
	steps: [
		{call: "machine.wrapperExport"},
		{keep: "r"},
		{get: "codes", expect: [0, 0, 0, 0, 0, 0]},
		{use: "r"},
		{get: "first", expect: "run 1\n", why: "an export never seen is evaluated"},
		{use: "r"},
		{get: "firstReplayed", expect: false},
		{use: "r"},
		{get: "second", expect: "run 1\n", why: "the same export again, its learned peak under CUE_DIRECT_GB: the first run's bytes, not evaluated"},
		{use: "r"},
		{get: "secondReplayed", expect: true, why: "it says it was not evaluated again"},
		{use: "r"},
		{get: "off", expect: "run 2\n", why: "CUE_EXPORTED=off evaluates"},
		{use: "r"},
		{get: "small", expect: "run 3\n", why: "an export that took less CPU than CUE_REPLAY_MIN_S is evaluated, never looked up"},
		{use: "r"},
		{get: "file", expect: "run 4\n", why: "an export to a file (-o) evaluates"},
		{use: "r"},
		{get: "changed", expect: "run 5\n", why: "a changed input evaluates"},
		{use: "r"},
		{get: "changedReplayed", expect: false},
		{use: "r"},
		{get: "log", expect: ["export\tmiss", "export\thit", "export\tmiss"], why: "the cache log counts the direct path's exports too: a miss, the hit, the changed input's miss; what skipped the cache logs nothing"},
	]
}
cases: "slot.ts holds a claim for a live release in another account's pool, and only for that (PRONTO-762)": {
	suite: "machine"
	steps: [
		{call: "machine.foreignHold"},
		{keep: "r"},
		{get: "live", expect: true, why: "a live release record of the wanted uid, its process started before the write, within the hours"},
		{use: "r"},
		{get: "dead", expect: false, why: "a dead pid holds nothing"},
		{use: "r"},
		{get: "reused", expect: false, why: "a process that started after the record is a reused pid, no release"},
		{use: "r"},
		{get: "unknownStart", expect: false, why: "a start time that cannot be read is never a hold"},
		{use: "r"},
		{get: "symlinkFile", expect: false, why: "a weight file that is a link is not read as a hold"},
		{use: "r"},
		{get: "symlinkDir", expect: false, why: "a record dir that is a link is not a hold"},
		{use: "r"},
		{get: "wrongUid", expect: false, why: "a file another uid than STACK_HOLD_UID owns is not a hold"},
		{use: "r"},
		{get: "wrongDirUid", expect: false, why: "nor a dir"},
		{use: "r"},
		{get: "older", expect: false, why: "a record older than STACK_RELEASE_HOLD_MAX hours stops holding"},
		{use: "r"},
		{get: "weightZero", expect: false, why: "a release record weighs above 0"},
		{use: "r"},
		{get: "notRelease", expect: false, why: "a record without prio=release is no release"},
		{use: "r"},
		{get: "otherPid", expect: false, why: "a record whose pid is not the dir's holder is no release"},
		{use: "r"},
		{get: "badPid", expect: false, why: "an unparsable pid is ignored"},
		{use: "r"},
		{get: "none", expect: false, why: "an empty pool holds nothing"},
		{use: "r"},
		{get: "claimWeight0", expect: true, why: "a weight-0 claim is admitted while a release holds"},
		{use: "r"},
		{get: "claimWeight3", expect: false, why: "a claim with a weight waits while a release holds"},
	]
}
