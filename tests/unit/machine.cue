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
cases: "slot.ts holds a claim for a live release in another account's pool, and only for that, and trusts only its own pool (PRONTO-762)": {
	suite: "machine"
	steps: [
		{call: "machine.foreignHold"},
		{keep: "r"},
		{get: "live", expect: true, why: "a live release record of the wanted uid on disk (real files, not writable by others, its process started before the write) holds"},
		{use: "r"},
		{get: "onlyBad", expect: false, why: "a record whose weight is a symlink, and one whose weight is group-writable, hold nothing"},
		{use: "r"},
		{get: "waiting", expect: true, why: "a release's waiting ticket in queue/ holds too (894 holds while a release waits)"},
		{use: "r"},
		{get: "waitingGroupWritable", expect: false, why: "a group-writable ticket does not"},
		{use: "r"},
		{get: "groupWritablePool", expect: false, why: "a pool dir that others can write is not believed"},
		{use: "r"},
		{get: "ownUidRefused", expect: false, why: "a hold pool owned by this account's own uid is refused, whatever it holds"},
		{use: "r"},
		{get: "ownGood", expect: true, why: "this account's own pool, mode 755, is trusted"},
		{use: "r"},
		{get: "ownOpen", expect: false, why: "this account's own pool with mode 777 is refused (a squatted or loosened path)"},
		{use: "r"},
		{get: "dead", expect: false, why: "a dead pid holds nothing"},
		{use: "r"},
		{get: "reused", expect: false, why: "a process that started after the record is a reused pid, no release"},
		{use: "r"},
		{get: "reusedWithinSlack", expect: true, why: "ps's whole seconds: a start a second and a half after the record's mtime is still its own"},
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
		{get: "groupWritableFile", expect: false, why: "a group-writable record file is not believed"},
		{use: "r"},
		{get: "otherWritableDir", expect: false, why: "nor an other-writable dir"},
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
		{get: "ticketLive", expect: true, why: "a live waiting release ticket holds"},
		{use: "r"},
		{get: "ticketDead", expect: false, why: "a dead ticket's pid holds nothing"},
		{use: "r"},
		{get: "ticketReused", expect: false, why: "a ticket whose process started after its name's time is a reused pid"},
		{use: "r"},
		{get: "ticketOld", expect: false, why: "a ticket older than the hours cap stops holding"},
		{use: "r"},
		{get: "ticketPlain", expect: false, why: "a ticket without release=1 is no release"},
		{use: "r"},
		{get: "ticketWeightZero", expect: false, why: "a release ticket weighs above 0"},
		{use: "r"},
		{get: "ticketFields", expect: true, why: "release=1 is read after nested, mem and cores, as the claim's scan reads it"},
		{use: "r"},
		{get: "ticketAfterWhat", expect: false, why: "a release=1 inside the what is not the mark"},
		{use: "r"},
		{get: "ticketPrio", expect: true, why: "prio=release, the field this copy writes, is read after nested, mem and cores"},
		{use: "r"},
		{get: "ticketPrioNormal", expect: false, why: "prio=normal is the field; a release=1 after it is in the what"},
		{use: "r"},
		{get: "ticketPrioWeight0", expect: false, why: "a weight-0 prio=release ticket holds nothing"},
		{use: "r"},
		{get: "heldPrioTicket", expect: true, why: "another account's live prio=release ticket holds"},
		{use: "r"},
		{get: "uidUnset", expect: -1, why: "STACK_HOLD_UID unset: no hold"},
		{use: "r"},
		{get: "uidEmpty", expect: -1, why: "STACK_HOLD_UID empty is not uid 0: no hold"},
		{use: "r"},
		{get: "uidSigned", expect: -1, why: "STACK_HOLD_UID must be digits"},
		{use: "r"},
		{get: "uidText", expect: -1, why: "digits only"},
		{use: "r"},
		{get: "uidOwn", expect: -1, why: "this account's own uid is refused"},
		{use: "r"},
		{get: "uidOther", expect: 501, why: "another account's uid is read"},
		{use: "r"},
		{get: "uidZero", expect: 0, why: "0 spelled out is root's uid, read"},
		{use: "r"},
		{get: "trustSymlink", expect: false, why: "an own-pool path that is a link is refused"},
		{use: "r"},
		{get: "trustOther", expect: false, why: "one another account owns is refused"},
		{use: "r"},
		{get: "trust777", expect: false, why: "one every account can write is refused"},
		{use: "r"},
		{get: "trust775", expect: false, why: "one the group can write is refused"},
		{use: "r"},
		{get: "trustGood", expect: true, why: "one only we can write is used"},
		{use: "r"},
		{get: "claimWeight0", expect: true, why: "a weight-0 claim is admitted while a release holds"},
		{use: "r"},
		{get: "claimWeight3", expect: false, why: "a claim with a weight waits while a release holds"},
		{use: "r"},
		{get: "besideUnder", expect: true, why: "a release runs, none waits, load1 7 under 18: beside"},
		{use: "r"},
		{get: "besideOver", expect: false, why: "load1 at 18 is not under 18: held"},
		{use: "r"},
		{get: "besideWaiting", expect: false, why: "a waiting release keeps its room: held"},
		{use: "r"},
		{get: "besideUnknown", expect: false, why: "an unknown load admits nothing beside a release"},
		{use: "r"},
		{get: "besideNoRelease", expect: false, why: "only a running release is a rehearsal to run beside"},
		{use: "r"},
		{get: "admitUnder", expect: true, why: "a gate (3) beside a rehearsal (8 of 15) under load 18 is admitted"},
		{use: "r"},
		{get: "holdOver", expect: false, why: "the same gate at load1 20 waits"},
		{use: "r"},
		{get: "besideFull", expect: false, why: "beside a rehearsal, a claim whose weight does not fit waits"},
		{use: "r"},
		{get: "besideRunnerFull", expect: false, why: "beside a rehearsal a runner job must fit too"},
		{use: "r"},
		{get: "besideAhead", expect: false, why: "beside a rehearsal the older tickets reserve their room"},
		{use: "r"},
		{get: "besideForeign", expect: false, why: "never beside another account's release: its weight is not in this pool"},
		{use: "r"},
		{get: "heldBeside", expect: true, why: "a claim beside a rehearsal with no room still waits for the release: its deadline resets"},
		{use: "r"},
		{get: "heldRelease", expect: false, why: "a release claim is never held by a release"},
		{use: "r"},
		{get: "heldWeight0", expect: false, why: "a weight-0 claim is never held"},
		{use: "r"},
		{get: "olderBesideKeeps", expect: true, why: "an older weighted ticket that fits beside a release keeps its place, whatever the arriving claim's weight: a weight-0 cue claim cannot take the memory it reserved"},
		{use: "r"},
		{get: "olderHeldSkipped", expect: false, why: "with no room beside the release, the older weighted ticket is held and skipped, as before"},
		{use: "r"},
		{get: "olderBesideFull", expect: false, why: "beside a release, an older ticket whose weight does not fit is still skipped"},
		{use: "r"},
		{get: "olderReleaseKept", expect: true, why: "an older release ticket that fits is kept, beside or not"},
		{use: "r"},
		{get: "poolWeight0Low", expect: true, why: "a weight-0 claim with an older weighted ordinary ticket, a local release and load under the bar: room beside"},
		{use: "r"},
		{get: "poolWeight0Foreign", expect: false, why: "another account's release leaves no room beside, for the older tickets too"},
		{use: "r"},
		{get: "poolWeight0NoOlder", expect: false, why: "no older weighted ordinary ticket: nothing to judge, no load read"},
		{use: "r"},
		{get: "poolRelease", expect: false, why: "a release claim reads nothing and judges none beside, as before"},
		{use: "r"},
		{get: "poolWeighted", expect: true, why: "a weighted claim's own beside, already read"},
		{use: "r"},
		{get: "poolReadFails", matches: "\\| cause: Requires sys access$", why: "a weight-0 claim whose load read fails is failed with the read's cause, never kept waiting behind every older ticket in silence (bsoneca/pronto#1555)"},
		{use: "r"},
		{get: "holdLoadUnset", expect: 18, why: "an unset STACK_HOLD_LOAD is one load per core"},
		{use: "r"},
		{get: "holdLoadEmpty", expect: 18, why: "an empty STACK_HOLD_LOAD is one load per core"},
		{use: "r"},
		{get: "holdLoadSet", expect: 12, why: "a valid STACK_HOLD_LOAD is used"},
		{use: "r"},
		{get: "holdLoadZero", matches: "STACK_HOLD_LOAD.*\"0\"", why: "an explicit 0 fails loudly, naming the variable and the value (bsoneca/pronto#1555)"},
		{use: "r"},
		{get: "holdLoadNegative", matches: "STACK_HOLD_LOAD.*\"-3\"", why: "an explicit negative fails loudly"},
		{use: "r"},
		{get: "holdLoadGarbage", matches: "STACK_HOLD_LOAD.*\"abc\"", why: "an explicit non-number fails loudly, never the default"},
		{use: "r"},
		{get: "nestOfRelease", expect: true, why: "a release's nested claim is one"},
		{use: "r"},
		{get: "nestOfUnrelated", expect: false, why: "an ordinary gate's nested claim while an unrelated release runs is not"},
		{use: "r"},
		{get: "nestTopLevel", expect: false, why: "a release's top-level claim is not nested"},
		{use: "r"},
		{get: "nestDeadAncestor", expect: false, why: "a nested claim whose release ancestor is dead (no holder) is not"},
		{use: "r"},
		{get: "nestedUnmarkedAdmitted", expect: true, why: "a release's nested cue claim skips an unmarked (old-format) ordinary ticket: it waits for the release, so counting its memory deadlocks"},
		{use: "r"},
		{get: "nestedMarkedWaits", expect: false, why: "a marked ordinary ticket may be admitted beside the release, so its memory still counts and the nested claim waits"},
		{use: "r"},
		{get: "nestedUnmarkedOrdinaryClaim", expect: false, why: "a claim that is not a release's nested one still counts an unmarked ticket, as before"},
		{use: "r"},
		{get: "ticketMarkRoundTrip", expect: "{\"weight\":3,\"nested\":false,\"mem\":4,\"cores\":2,\"release\":false,\"marked\":true,\"what\":\"gate x\"}", why: "ticketText writes the marker and parseTicket reads it back, leaving the label alone"},
		{use: "r"},
		{get: "ticketOldText", expect: "{\"weight\":3,\"nested\":false,\"mem\":4,\"cores\":2,\"release\":false,\"marked\":false,\"what\":\"gate x\"}", why: "an old ticket text parses as unmarked"},
		{use: "r"},
		{get: "ticketMarkedRelease", expect: "{\"weight\":8,\"nested\":false,\"release\":true,\"marked\":true,\"what\":\"beside=1 r\"}", why: "only the first word after the priority is the marker: a label that repeats it keeps it"},
		{use: "r"},
		{get: "loadRead", expect: 7, why: "load1 is the first of the machine's three load averages"},
		{use: "r"},
		{get: "loadFails", expect: "load1 could not be read beside a release (Deno.loadavg): Requires sys access | cause: Requires sys access", why: "a failed read fails the claim with its cause, never a hold that moves its deadline for the whole release (PRONTO-1020)"},
		{use: "r"},
		{get: "loadEmpty", expect: "load1 could not be read beside a release (Deno.loadavg): no number, got undefined", why: "a read with no number fails as a failed read does, never a load that admits nothing or everything"},
	]
}

// The run owner (harness/files/tests/slot.ts, PRONTO-684): who a run's members are, over tables given as data.
cases: "the run owner plans a run's members from a table, reuses of a pid included, and fails closed on a read it cannot make": {
	suite: "machine"
	steps: [
		{call: "machine.ownPure"},
		{keep: "r"},
		{use: "r"},
		{get: "basic", expect: [101], why: "a live process of this uid attributed to the root and started after it is a member; another's responsible pid, and another uid, are not"},
		{use: "r"},
		{get: "beforeRoot", expect: [], why: "a process that started before the root cannot be its member, whatever it says"},
		{use: "r"},
		{get: "zombie", expect: [], why: "a zombie is not signalled: its parent reaps it"},
		{use: "r"},
		{get: "reusedOurs", expect: [102], why: "the root's pid now held by Q (another start time): what was attributed to it and began before Q is the run's"},
		{use: "r"},
		{get: "reusedNamedSkipped", expect: ["103"], why: "and what began after Q is skipped, named: it is Q's own, never ours"},
		{use: "r"},
		{get: "reusedHoldersOwn", expect: [], why: "a root whose pid is held by another process, and everything attributed to that pid started after it: nothing is planned"},
		{use: "r"},
		{get: "reusedHoldersOwnDead", expect: [], why: "the same for a dead run's record: Q's processes are never reaped as the old run's"},
		{use: "r"},
		{get: "errMembers", expect: [109], why: "a read error on one pid does not hide a member that read fine"},
		{use: "r"},
		{get: "errSkipped", expect: ["106:gone", "107:another account's", "108:another account's"], why: "ESRCH is a pid gone, EPERM and a read error on another uid's pid are skipped"},
		{use: "r"},
		{get: "esrchFails", expect: 0, why: "ESRCH is not a failure"},
		{use: "r"},
		{get: "eperm", expect: 0, why: "another uid's EPERM is skipped, not a failure"},
		{use: "r"},
		{get: "otherUidRead", expect: 0, why: "a read error on a pid of another uid is skipped"},
		{use: "r"},
		{get: "ownUidRead", expect: 1, why: "a read error on a live pid of this uid fails the plan, closed"},
		{use: "r"},
		{get: "listError", expect: ["the process list could not be read: proc_listallpids returned -1 (errno 1)"], why: "a list that cannot be read fails with its cause"},
		{use: "r"},
		{get: "age", expect: 2000, why: "a member's age is the clock's now less its start (µs to ms)"},
		{use: "r"},
		{get: "deadRuns", expect: ["200:201", "300:301"], why: "a run whose supervisor is alive is not dead; one whose supervisor's pid now has another start time is, and its members are planned; the clock and the table are given"},
		{use: "r"},
		{get: "deadListError", expect: [1], why: "a dead-run reap on a list that cannot be read fails every record, closed"},
		{use: "r"},
		{get: "linuxMembers", expect: [110, 111, 114, 117, 119], why: "on Linux the members are the root's subtree and the orphans (the supervisor's, or init's once it is gone) that carry its PRONTO_RUN marker, with theirs; not the supervisor's own children (115), one with another run's marker (118), or one whose parent is init (112)"},
		{use: "r"},
		{get: "linuxDead", expect: [[119]], why: "a dead supervisor's run is reaped by its marker: the orphan init took is found, an unmarked process is not"},
		{use: "r"},
		{get: "linuxDeadReused", expect: [[122]], why: "a reused root pid's child is not planned; a marked orphan under a subreaper that is not init is"},
		{use: "r"},
		{get: "linuxUnreadable", expect: [116], why: "a child of the supervisor whose environ cannot be read is skipped and said, never signalled"},
		{use: "r"},
		{get: "nestedSupervisorGone", expect: 0, why: "a responsible pid whose run's supervisor is gone is not a live run: a claim there owns"},
		{use: "r"},
		{get: "nestedByResponsible", expect: 300, why: "a process whose responsible pid is a root with a live record is inside that run"},
		{use: "r"},
		{get: "nestedRootReused", expect: 0, why: "a responsible pid whose process now has another start time is no run's root"},
		{use: "r"},
		{get: "nestedByAncestry", expect: 300, why: "a live supervisor with a record on the parent chain makes a process nested: the moment before the root's record has its name"},
		{use: "r"},
		{get: "nestedSupervisorReused", expect: 0, why: "a supervisor pid with another start time is not one"},
		{use: "r"},
		{get: "notNested", expect: 0, why: "a process under no run owns"},
		{use: "r"},
		{get: "nestedThrows", expect: true, why: "a table that cannot be read throws: nested or not is not guessed"},
		{use: "r"},
		{get: "movedSent", expect: [], why: "a member whose start time changed between the list and the signal is skipped: nothing is sent to its pid"},
		{use: "r"},
		{get: "movedSurvivors", expect: [], why: "and it is no survivor"},
		{use: "r"},
		{get: "movedFailed", expect: [], why: "and no failure"},
		{use: "r"},
		{get: "stubbornSurvivors", expect: 1, why: "a member still there after TERM and KILL is a survivor"},
		{use: "r"},
		{get: "stubbornNamed", expect: "pid 101 (age N, stubborn)", why: "named by pid, age and command"},
		{use: "r"},
		{get: "stubbornListed", expect: 1, why: "and listed as left running"},
		{use: "r"},
		{get: "deniedFailed", expect: true, why: "a signal that cannot be sent fails the run, closed"},
		{use: "r"},
		{get: "recordOfOwn", expect: 50, why: "a keeper's record is the one of its own supervisor, though an older run's done record has the same root pid"},
		{use: "r"},
		{get: "recordOfOld", expect: "done", why: "and the old one is found only by its own supervisor"},
		{use: "r"},
		{get: "recordOfNone", expect: 0, why: "with only the old record, a keeper finds none: it plans against and deletes nothing of another run"},
	]
}
cases: "a short-lived parent's detached Apple sleep is stopped when the run passes": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "orphan"}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "code", expect: 0, why: "the run passes"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the sleeper, detached by a double fork and setsid from a parent that had already exited, is gone"},
		{use: "r"},
		{get: "named", expect: true, why: "and is said: left running by the run's label"},
		{use: "r"},
		{get: "recordGone", expect: true, why: "the run's ledger record is gone"},
	]
}
cases: "a short-lived parent's detached Apple sleep is stopped when the owner gets TERM": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "wait", signal: "SIGTERM"}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "nonzero", expect: true, why: "TERM ends the run nonzero"},
		{use: "r"},
		{get: "code", expect: 130, why: "130, as every listener here has ended"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the sleeper is gone"},
		{use: "r"},
		{get: "recordGone", expect: true, why: "the ledger is clean"},
	]
}
cases: "a short-lived parent's detached Apple sleep is stopped when the owner gets INT": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "wait", signal: "SIGINT"}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "code", expect: 130, why: "INT ends the run 130"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the sleeper is gone"},
	]
}
cases: "a short-lived parent's detached Apple sleep is stopped when the owner gets HUP": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "wait", signal: "SIGHUP"}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "code", expect: 129, why: "HUP ends the run 129"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the sleeper is gone"},
	]
}
cases: "another run's detached sleep is never signalled": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "wait", signal: "SIGTERM", foreign: true}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "this run's sleeper is gone"},
		{use: "r"},
		{get: "foreignKept", expect: true, why: "the other owned run's sleeper is still running"},
		{use: "r"},
		{get: "foreignGone", expect: true, why: "and goes only when its own owner is stopped"},
	]
}
cases: "a member that ignores TERM is KILLed and the run still ends": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{mode: "orphan", ignore: true}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "code", expect: 0, why: "the run passes"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the sleeper that ignored TERM is gone after the 5 s and a KILL"},
		{use: "r"},
		{get: "named", expect: true, why: "and is said"},
	]
}
cases: "a claim inside a run does not own, and the outer owner stops what it left": {
	suite: "machine"
	steps: [
		{call: "machine.ownProbe", args: [{nested: true}]},
		{keep: "r"},
		{get: "launched", expect: true, why: "the root and its detached sleeper started"},
		{use: "r"},
		{get: "code", expect: 0, why: "the run passes"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "the outer owner stopped the sleeper the inner claim's command left"},
		{use: "r"},
		{get: "named", expect: true, why: "as the outer run's"},
		{use: "r"},
		{get: "innerNamed", expect: false, why: "the inner one owned nothing, so it names nothing"},
	]
}
cases: "the responsibility calls exist and are inherited across setsid": {
	suite: "machine"
	steps: [
		{call: "machine.ownSpi"},
		{keep: "r"},
		{get: "symbols", expect: true, why: "the library and its calls (on macOS the responsibility SPI) open: an OS update that breaks them turns this red the same day"},
		{use: "r"},
		{get: "inherited", expect: true, why: "a process detached by a double fork and setsid has the root's responsible pid (Linux: it is the root's descendant)"},
		{use: "r"},
		{get: "selfNotRoots", expect: true, why: "this process, which started the root, is not attributed to it"},
	]
}
cases: "a keeper killed leaves no run: the command it ran is stopped and the run fails": {
	suite: "machine"
	steps: [
		{call: "machine.ownKeeperKilled"},
		{keep: "r"},
		{get: "launched", expect: true, why: "the run started"},
		{use: "r"},
		{get: "nonzero", expect: true, why: "the run fails, with the cause"},
		{use: "r"},
		{get: "cmdGone", expect: true, why: "the command is told TERM and KILL directly, its keeper gone"},
		{use: "r"},
		{get: "recordGone", expect: true, why: "the ledger is clean"},
	]
}
cases: "a SIGKILLed supervisor's run is ended by its keeper": {
	suite: "machine"
	steps: [
		{call: "machine.ownSupervisorKilled"},
		{keep: "r"},
		{get: "launched", expect: true, why: "the run started and its sleeper was detached"},
		{use: "r"},
		{get: "cmdGone", expect: true, why: "the keeper sees its supervisor gone and stops the command"},
		{use: "r"},
		{get: "sleepGone", expect: true, why: "and what the run left"},
		{use: "r"},
		{get: "keeperGone", expect: true, why: "and ends itself, not 12 h later"},
		{use: "r"},
		{get: "recordGone", expect: true, why: "removing the run's record and folder"},
	]
}
cases: "a child killed by SIGKILL reads as signal 9, as the memory watchdog's retry needs": {
	suite: "machine"
	steps: [
		{call: "machine.ownSignals"},
		{keep: "r"},
		{get: "killed", expect: 9, why: "SIGKILL is 9, not 1"},
		{use: "r"},
		{get: "term", expect: 15, why: "TERM is 15"},
		{use: "r"},
		{get: "hup", expect: 1, why: "HUP is 1"},
		{use: "r"},
		{get: "none", expect: 0, why: "no signal is 0"},
	]
}
cases: "an owned command gets its stdin and gives its stdout, stderr and exit code as a plain child does": {
	suite: "machine"
	steps: [
		{call: "machine.ownPlain"},
		{keep: "r"},
		{get: "code", expect: 3, why: "its exit code"},
		{use: "r"},
		{get: "stdout", expect: "in\n", why: "its stdin reached it, and its stdout came back"},
		{use: "r"},
		{get: "stderr", expect: true, why: "and its stderr"},
	]
}
cases: "a run with no label is named by its executable, never by an argument; own is refused off macOS": {
	suite: "machine"
	steps: [
		{call: "machine.ownLabel"},
		{keep: "r"},
		{get: "clean", expect: true, why: "neither the derived label nor the record text carries the token"},
		{use: "r"},
		{get: "what", expect: "curl", why: "the label is the executable's basename"},
		{use: "r"},
		{get: "record", expect: "1 prio=normal curl", why: "the ledger's record text has the label alone"},
		{use: "r"},
		{get: "empty", expect: "command", why: "an empty argv still has a label"},
		{use: "r"},
		{get: "gate", expect: "saytw integrate@local", why: "a sayt run keeps its target, a fixed verb the machine's lanes read (a gate is integrate@local)"},
		{use: "r"},
		{get: "gateArg", expect: "saytw", why: "but never an argument that is not a target"},
		{use: "r"},
		{get: "linux", expect: "slot: own needs macOS; on Linux a run's descendants are not owned", why: "the own verb says why it refuses on Linux"},
		{use: "r"},
		{get: "mac", expect: "ok", why: "and does not refuse on macOS"},
	]
}
cases: "a leftover is named by its executable, pid and age, never by an argument": {
	suite: "machine"
	steps: [
		{call: "machine.ownNames"},
		{keep: "r"},
		{get: "noArgs", expect: true, why: "the description of a process whose command line carries a token has no argument text"},
		{use: "r"},
		{get: "text", expect: "pid 42 (age 1m, curl)", why: "the pid, the age and the executable's basename"},
		{use: "r"},
		{get: "exe", expect: "tool", why: "a path is cut to its basename"},
		{use: "r"},
		{get: "realNoSecret", expect: true, why: "the real read of a live process gives its executable only, one word, no token"},
		{use: "r"},
		{get: "real", expect: "sleep", why: "the sleep a shell exec'd into"},
	]
}
cases: "a stop that never returns still ends the run in the kill, within the grace": {
	suite: "machine"
	steps: [
		{call: "machine.ownStopHangs"},
		{keep: "r"},
		{get: "ended", expect: true, why: "the run ends though its stop callback never resolves"},
		{use: "r"},
		{get: "code", expect: 124, why: "as a timeout"},
		{use: "r"},
		{get: "withinGrace", expect: true, why: "within the grace plus the teardown, not 20 s"},
	]
}
cases: "the ledger is read only from a folder and regular files that are ours, never a link or a FIFO": {
	suite: "machine"
	steps: [
		{call: "machine.ownLedger"},
		{keep: "r"},
		{get: "entries", expect: [10], why: "the regular file is read; the symlink to it and the FIFO are ignored, the FIFO without blocking"},
		{use: "r"},
		{get: "otherUidDir", expect: [], why: "a runs folder that is another uid's is ignored whole"},
		{use: "r"},
		{get: "openDir", expect: [], why: "so is one others can write, though its entry is ours"},
		{use: "r"},
		{get: "fileOurs", expect: true, why: "our regular file is usable"},
		{use: "r"},
		{get: "fileOther", expect: false, why: "another uid's file is not"},
		{use: "r"},
		{get: "link", expect: false, why: "a link is not"},
		{use: "r"},
		{get: "fifo", expect: false, why: "neither is a FIFO or any other non-regular file"},
	]
}
cases: "the keeper keeps polling while its supervisor is alive, however long, and ends the run once it is gone": {
	suite: "machine"
	steps: [
		{call: "machine.keeperDecides"},
		{keep: "r"},
		{get: "alive", expect: "keep", why: "a live supervisor is kept: the keeper has no 12 h exit"},
		{use: "r"},
		{get: "gone", expect: "exit", why: "no such pid"},
		{use: "r"},
		{get: "reused", expect: "exit", why: "another process at the pid"},
		{use: "r"},
		{get: "zombie", expect: "exit", why: "a zombie supervisor is gone"},
		{use: "r"},
		{get: "unreadable", expect: "keep", why: "a read that failed says nothing"},
	]
}
cases: "two owned runs begun at once in one process keep ledger entries of their own": {
	suite: "machine"
	steps: [
		{call: "machine.ownConcurrent"},
		{get: "codes", expect: "0,0", why: "neither run fails removing the other's pending file (PRONTO-1199)"},
	]
}
cases: "a holder's unreadable pid file is an error, only a missing one is nobody": {
	suite: "machine"
	steps: [
		{call: "machine.holderRead"},
		{get: "held", expect: "0,error,4242,error", why: "missing is 0, unreadable or not a pid fails loudly, a pid is read"},
	]
}
cases: "the pool's lock is retried only while another chooser holds it": {
	suite: "machine"
	steps: [
		{call: "machine.choosingLock"},
		{keep: "r"},
		{get: "broken", expect: "error", why: "a lock that cannot be made fails, it does not retry for ever"},
		{use: "r"},
		{get: "free", expect: "ran", why: "a free lock runs the function"},
	]
}

// PRONTO-892 (Codex on bsoneca/pronto#1520, slot.ts).
cases: "a job whose reservation cannot be rewritten fails, stopping its command before it gives its claim back": {
	suite: "machine"
	steps: [
		{call: "machine.samplerFails"},
		{keep: "r"},
		{get: "code", expect: 125, why: "the sampler's failure is the job's, not swallowed as a released record"},
		{use: "r"},
		{get: "said", expect: true},
		{use: "r"},
		{get: "stoppedEarly", expect: true, why: "the command, which sleeps 25 s, was stopped"},
		{use: "r"},
		{get: "childGone", expect: true},
	]
}
cases: "a claim reaps only the run folders runDir made: directories of this account, named whole, with a dead pid": {
	suite: "machine"
	steps: [
		{call: "machine.runFoldersReaped"},
		{keep: "r"},
		{get: "dir", expect: "reaped"},
		{use: "r"},
		{get: "gate", expect: "reaped"},
		{use: "r"},
		{get: "backup", expect: "kept", why: "gate.backup.<pid> is no run folder: a pid is read from its one place only"},
		{use: "r"},
		{get: "extra", expect: "kept"},
		{use: "r"},
		{get: "short", expect: "kept"},
		{use: "r"},
		{get: "live", expect: "kept", why: "its pid lives"},
		{use: "r"},
		{get: "file", expect: "kept", why: "a file named like a run folder is not one"},
		{use: "r"},
		{get: "link", expect: "kept", why: "nor is a link"},
	]
}
cases: "a run folder's pid is read from its one place in a name in runDir's format": {
	suite: "machine"
	steps: [
		{call: "machine.runPids"},
		{keep: "r"},
		{get: "slot_123_0123456789abcdef", expect: 123},
		{use: "r"},
		{get: "gate_9_abcdef", expect: 9},
		{use: "r"},
		{get: "rehearse_55_89abcdef01", expect: 55},
		{use: "r"},
		{get: "gate_backup_123", expect: null},
		{use: "r"},
		{get: "slot_123", expect: null},
		{use: "r"},
		{get: "slot_123_x_y", expect: null},
		{use: "r"},
		{get: "slot_123_abc", expect: null},
		{use: "r"},
		{get: "x_slot_123_abcdef", expect: null},
		{use: "r"},
		{get: "slot_12a_abcdef", expect: null},
		{use: "r"},
		{get: "slot_123_ABCDEF", expect: null},
	]
}
cases: "a top-level cue claim reserves behind a weighted ticket blocked on stack weight; only a nested claim passes it": {
	suite: "machine"
	steps: [
		{call: "machine.cueReserved"},
		{keep: "r"},
		{get: "topLevel", expect: ["blocked", "plain"], why: "an unrelated job must not take the memory reserved for the older evaluation"},
		{use: "r"},
		{get: "nested", expect: ["plain"], why: "the work a holder above it needs to finish: the exception"},
		{use: "r"},
		{get: "topLevelRelease", expect: ["plain"], why: "a release claim never waits behind an ordinary weighted ticket"},
		{use: "r"},
		{get: "topLevelAdmitted", expect: false, why: "40 GB beside the blocked ticket's 30 and the plain one's 4 does not fit 64"},
		{use: "r"},
		{get: "nestedAdmitted", expect: true},
	]
}
cases: "the cue memory budget defaults to half the machine's memory, and to one evaluation at a time where that cannot be read": {
	suite: "machine"
	steps: [
		{call: "machine.cueMemDefaults"},
		{keep: "r"},
		{get: "g128", expect: 64},
		{use: "r"},
		{get: "g36", expect: 18},
		{use: "r"},
		{get: "g8", expect: 4},
		{use: "r"},
		{get: "unknown", expect: 0.001, why: "a budget only the oldest claim fits in"},
		{use: "r"},
		{get: "zero", expect: 0.001},
		{use: "r"},
		{get: "nan", expect: 0.001},
	]
}
cases: "the pool's lock a minute old is reclaimed only once its owner is gone": {
	suite: "machine"
	steps: [
		{call: "machine.choosingStale"},
		{keep: "r"},
		{get: "live", expect: "held", why: "a chooser slow on a long queue still holds it: the wait is bounded here, the lock is not taken"},
		{use: "r"},
		{get: "dead", expect: "ran"},
		{use: "r"},
		{get: "none", expect: "ran", why: "no owner to verify (an older copy made it): by age, as before"},
	]
}

// PRONTO-892, round 2 (Codex on bsoneca/pronto#1673, slot.ts).
cases: "a gate's nested evaluation reserves behind neither the weighted ticket waiting for the gate nor the zero-weight one queued behind it": {
	suite: "machine"
	steps: [
		{call: "machine.gateNested"},
		{keep: "r"},
		{get: "kept", expect: ["002-2"], why: "olderKeeps leaves the weighted ticket out, the zero-weight one stays"},
		{use: "r"},
		{get: "blocked", expect: ["001-1-w", "002-2"], why: "the zero-weight ticket waits behind the weighted one, which waits for weight the gate owns"},
		{use: "r"},
		{get: "nestedReserves", expect: []},
		{use: "r"},
		{get: "nestedAdmitted", expect: true},
		{use: "r"},
		{get: "withoutTheFix", expect: ["002-2"], why: "its reservation of the whole budget blocks the nested work: all three wait until a timeout"},
		{use: "r"},
		{get: "withoutTheFixAdmitted", expect: false},
		{use: "r"},
		{get: "topLevelReserves", expect: ["001-1-w", "002-2"], why: "FIFO holds for top-level claims"},
		{use: "r"},
		{get: "unrelatedKept", expect: ["001-1-w"], why: "a ticket that fits beside it does not wait for it"},
		{use: "r"},
		{get: "siblingKept", expect: ["001-1-w"], why: "the holder's own nested work is never excluded"},
	]
}
cases: "the chooser lock names a process by its pid and start time, so a reused pid is not the chooser": {
	suite: "machine"
	steps: [
		{call: "machine.chooserIdentity"},
		{keep: "r"},
		{get: "both", expect: {pid: 123, start: 1700000000000}},
		{use: "r"},
		{get: "pidOnly", expect: {pid: 123, start: 0}, why: "an older copy's file: the pid alone"},
		{use: "r"},
		{get: "none", expect: {pid: 0, start: 0}},
		{use: "r"},
		{get: "junk", expect: {pid: 0, start: 0}},
		{use: "r"},
		{get: "same", expect: true, why: "ps reads whole seconds"},
		{use: "r"},
		{get: "reused", expect: false},
		{use: "r"},
		{get: "unwritten", expect: true, why: "fail closed: no start to compare"},
		{use: "r"},
		{get: "unreadable", expect: true},
	]
}
cases: "a pid reused by an unrelated process does not hold the pool's lock; the same process does": {
	suite: "machine"
	steps: [
		{call: "machine.choosingReused"},
		{keep: "r"},
		{get: "same", expect: "held"},
		{use: "r"},
		{get: "reused", expect: "ran", why: "the pid lives but it is another process: the lock is reclaimed after a minute"},
	]
}
cases: "the memory sampler never overlaps itself: a tick while one runs starts nothing, and the claim waits for the one in flight": {
	suite: "machine"
	steps: [
		{call: "machine.noOverlap"},
		{keep: "r"},
		{get: "whileRunning", expect: 1, why: "three ticks while the first writes: one sample"},
		{use: "r"},
		{get: "second", expect: 2},
		{use: "r"},
		{get: "started", expect: 3},
		{use: "r"},
		{get: "finished", expect: 3},
		{use: "r"},
		{get: "errors", expect: 1, why: "a genuine failure still reaches the owner"},
	]
}
