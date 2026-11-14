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
