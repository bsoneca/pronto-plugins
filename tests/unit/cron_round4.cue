// release-cron's decisions of the fourth Codex round (PRONTO-870) that main's runs use: NUL-separated paths, the rehearsal's environment, the
// flags bookkeeping, the lock a flock version left, the outcome names and a signal's stop (../../release-cron/cron.js).
package unit

import "github.com/bsoneca/pronto-plugins/release-cron:releasecron"

_outcomes: releasecron.#Cron.outcomes

cases: {
	"changed paths are read NUL-separated, so a path git would quote still starts with its folder": {suite: "cron", steps: [
		{call: "cron.nulPaths", args: ["apps/studio/services/database/migrations/m\u00e9.sql\u0000apps/studio/a.js\u0000"], expect: ["apps/studio/services/database/migrations/m\u00e9.sql", "apps/studio/a.js"], why: "non-ASCII, unquoted"},
		{call: "cron.nulPaths", args: ["a\nb.js\u0000c.js\u0000"], expect: ["a\nb.js", "c.js"], why: "a newline is part of a name"},
		{call: "cron.nulPaths", args: [""], expect: []},
	]}
	"the rehearsal child gets the whole environment and inherits nothing else": {suite: "cron", steps: [
		{call: "cron.rehearsalSpawn", args: [{A: "1", REHEARSE_LIVE: "stale"}, null, true, "def456"], expect: {env: {A: "1", REHEARSE_COMMIT: "def456", STACK_WAIT_MINUTES: "525600", STACK_PRIORITY: "release"}, clearEnv: true}, why: "a removed REHEARSE_LIVE is not inherited from the parent"},
		{call: "cron.rehearsalSpawn", args: [{A: "1"}, "abc123", true, "def456"], expect: {env: {A: "1", REHEARSE_LIVE: "abc123", REHEARSE_COMMIT: "def456", STACK_WAIT_MINUTES: "525600", STACK_PRIORITY: "release"}, clearEnv: true}},
	]}
	"a flags-released marker that cannot be written is the bookkeeping's failure, with its path": {suite: "cron", steps: [
		{call: "cron.flagsBookkeeping", args: ["ok", "/s/flags-released", null], expect: "ok"},
		{call: "cron.flagsBookkeeping", args: ["ok", "/s/flags-released", "EACCES: permission denied\nat x"], expect: "failed (the marker /s/flags-released was not written: EACCES: permission denied)"},
		{call: "cron.flagsBookkeeping", args: ["failed (exit 1)", "/s/flags-released", null], expect: "failed (exit 1)", why: "the recorder's own failure stands"},
		{call: "cron.flagsBookkeeping", args: ["failed (exit 1)", "/s/flags-released", "x"], expect: "failed (exit 1)", why: "no marker is written after a failed record"},
	]}
	"release-cron's outcome names come from releaseCron.outcomes": {suite: "cron", steps: [
		{call: "cron.spaced", args: [_outcomes.released], expect: true},
		{call: "cron.spaced", args: [_outcomes.failed], expect: true},
		{call: "cron.endWhenInterrupted", args: [true, _outcomes.failed], expect: _outcomes.stopped},
		{call: "cron.endWhenInterrupted", args: [true, _outcomes.released], expect: _outcomes.released},
	]}
	"a run whose tree moved under the rehearsal has the cause treeMoved and gives no verdict": {suite: "cron", steps: [
		{call: "cron.failureOf", args: ["treeMoved", {from: "aaaaaaaa", to: "bbbbbbbb"}], expect: {why: "\(releasecron.#Cron.causes.treeMoved) from aaaaaaaa to bbbbbbbb while the rehearsal and the preview ran: nothing released", cause: "treeMoved"}},
		{call: "cron.noVerdictRun", args: ["x", "treeMoved"], expect: true, why: "infrastructure, not a failed rehearsal"},
		{call: "cron.noVerdictRun", args: ["the run's tree moved from a to b while the rehearsal and the preview ran: nothing released", null], expect: true, why: "an older record, read by its why"},
	]}
	"a lock left as a plain file by the flock version keeps its live holder and is removed when dead": {suite: "cron", steps: [
		{call: "cron.legacyFileLock", args: [true, 4242, true], expect: "busy"},
		{call: "cron.legacyFileLock", args: [true, 4242, false], expect: "remove"},
		{call: "cron.legacyFileLock", args: [true, 0, false], expect: "remove", why: "empty or unreadable content"},
		{call: "cron.legacyFileLock", args: [false, 4242, true], expect: "none", why: "a directory: the mkdir lock decides"},
	]}
	"a throw after the run's reason was set appends to it": {suite: "cron", steps: [
		{call: "cron.appendWhy", args: [null, "boom"], expect: "boom"},
		{call: "cron.appendWhy", args: ["the rehearsal failed (exit 1)", "a write failed"], expect: "the rehearsal failed (exit 1); a write failed"},
	]}

	// PRONTO-1032: the lock (cron.js lockAcquire and lockRelease, on tests/unit/cronlock.js's in-memory file system with links).
	"a lock is a symlink to a staging directory that already holds the pid: never a directory made empty, never linked to one without its pid": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{}], expect: {got: true, pid_file: "500", lock_kind: "link", linkedWhole: true, madeLockDir: false}, why: "the base driver's mkdir fails on the link and its reader sees the pid through it from the first instant"},
	]}
	"an empty directory at the lock, made by a base driver, is never replaced: the claim fails and waits for its pid": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}, after: {files: {"state/lock/pid": "4242"}}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "found before the claim"},
		{call: "cronlock.run", args: [{after: {emptyDirFirst: true, files: {"state/lock/pid": "4242"}}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "made between this run's staging and its symlink: symlink refuses it, rename would have replaced it"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}, files: {"state/lock/pid": ""}, after: {files: {"state/lock/pid": "4242"}}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "its write has begun and is still empty"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (absent); not taken, not removed", pid_file: null, lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "no pid after the bounded wait: its maker may only be paused, so it is never taken over silently"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (absent); not taken, not removed", pid_file: null, lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "a pid-less directory an older version left: a person removes it"},
	]}
	"a failure to stage, link or verify is an error naming the operation and path, never a skip behind a holder 0": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{fail: [{op: "writeFile", code: "ENOSPC"}]}], expect: {threw: "release-cron lock: stage pid in state/lock.new.500.u1: ENOSPC: ENOSPC: writeFile state/lock.new.500.u1/pid", pid_file: null, lock_kind: null, linkedWhole: true, madeLockDir: false}, why: "the staging directory is removed too"},
		{call: "cronlock.run", args: [{fail: [{op: "mkdir", code: "EACCES"}]}], expect: {threw: "release-cron lock: stage pid in state/lock.new.500.u1: EACCES: EACCES: mkdir state/lock.new.500.u1", pid_file: null, lock_kind: null, linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{fail: [{op: "symlink", code: "EIO"}]}], expect: {threw: "release-cron lock: symlink state/lock.new.500.u1 to state/lock: EIO: EIO: symlink state/lock", pid_file: null, lock_kind: null, linkedWhole: true, madeLockDir: false}, why: "a symlink that is not EEXIST is not contention"},
		{call: "cron.claimError", args: ["EEXIST"], expect: "contention"},
		{call: "cron.claimError", args: ["ENOTEMPTY"], expect: "error", why: "no rename is left to meet it"},
		{call: "cron.claimError", args: ["EACCES"], expect: "error"},
		{call: "cron.claimError", args: [null], expect: "error"},
	]}
	"a holder whose pid file cannot be read is an unknown owner: the lock is neither taken nor removed": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, alive: [4242], fail: [{op: "readFile", path: "state/lock/pid", code: "EACCES"}]}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (unreadable EACCES); not taken, not removed", pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "not a pid"}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (malformed \"not a pid\"); not taken, not removed", pid_file: "not a pid", lock_kind: "dir", linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{files: {"state/lock": "x1"}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (malformed \"x1\"); not taken, not removed", pid_file: null, lock_kind: "file", linkedWhole: true, madeLockDir: false}, why: "the flock version's file, unreadable as a pid"},
	]}
	"a live holder is busy; a verified dead one is taken over only on a symlink lock, never on an older driver's directory or file": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{links: {"state/lock": "lock.new.4242.a"}, dirs: {"state/lock.new.4242.a": 600000}, files: {"state/lock.new.4242.a/pid": "4242"}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "link", linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{links: {"state/lock": "lock.new.4242.a"}, dirs: {"state/lock.new.4242.a": 600000}, files: {"state/lock.new.4242.a/pid": "4242"}}], expect: {got: true, pid_file: "500", lock_kind: "link", linkedWhole: true, madeLockDir: false}, why: "4242 is gone: its link and staging directory go, this run's link stands"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}}], expect: {threw: "release-cron lock: state/lock is a stale lock of an older driver (holder 4242 is gone): not removed; stop every old launcher of this app, then remove state/lock by hand", pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "an old driver may have read 4242 as dead and be about to write its pid through whatever stands here: only a person clears it"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, after: {files: {"state/lock/pid": "4243"}}, alive: [4243]}], expect: {threw: "release-cron lock: state/lock is a stale lock of an older driver (holder 4242 is gone): not removed; stop every old launcher of this app, then remove state/lock by hand", pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "the delayed write of that old driver finds the lock as it was: no symlink was published over it"},
		{call: "cronlock.run", args: [{files: {"state/lock": "4242\n"}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: null, lock_kind: "file", linkedWhole: true, madeLockDir: false}},
		{call: "cronlock.run", args: [{files: {"state/lock": "4242\n"}}], expect: {threw: "release-cron lock: state/lock is a stale lock of an older driver (holder 4242 is gone): not removed; stop every old launcher of this app, then remove state/lock by hand", pid_file: null, lock_kind: "file", linkedWhole: true, madeLockDir: false}},
	]}
	"recovery removes only the lock it observed: one recovered meanwhile by another run, now held by a live run, is left": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{links: {"state/lock": "lock.new.4242.a"}, dirs: {"state/lock.new.4242.a": 600000}, files: {"state/lock.new.4242.a/pid": "4242"}, after: {inRecovery: {pid: "7000"}}, alive: [7000]}], expect: {got: false, pid: 7000, pid_file: "7000", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "the stale lock this run judged is gone; a live run's lock stands in its place"},
		{call: "cronlock.run", args: [{links: {"state/lock": "lock.new.4242.a"}, dirs: {"state/lock.new.4242.a": 600000}, files: {"state/lock.new.4242.a/pid": "4242"}, after: {inRecovery: {pid: "7000"}}}], expect: {threw: "release-cron lock: state/lock is a stale lock of an older driver (holder 7000 is gone): not removed; stop every old launcher of this app, then remove state/lock by hand", pid_file: "7000", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "a holder that took the lock meanwhile and is itself dead is judged again on its own: here a legacy directory, refused"},
	]}
	"a lock renamed away for removal that is not the observed one is put back, and the run stops": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{links: {"state/lock": "lock.new.4242.a"}, dirs: {"state/lock.new.4242.a": 600000}, files: {"state/lock.new.4242.a/pid": "4242"}, after: {renameSwaps: "7000"}}], expect: {threw: "release-cron lock: state/lock changed while it was being removed; put back, not taken", pid_file: "7000", lock_kind: "link", linkedWhole: true, madeLockDir: false}},
	]}
	"the lock's holder is read as the platform gives it: no file, empty, a pid, nonsense, or an error": {suite: "cron", steps: [
		{call: "cron.holderOf", args: ["ENOENT", ""], expect: {kind: "absent"}},
		{call: "cron.holderOf", args: [null, "\n"], expect: {kind: "empty"}},
		{call: "cron.holderOf", args: [null, "4242\n"], expect: {kind: "pid", pid: 4242}},
		{call: "cron.holderOf", args: [null, "0"], expect: {kind: "malformed", text: "0"}},
		{call: "cron.holderOf", args: ["EACCES", ""], expect: {kind: "unreadable", err: "EACCES"}},
		{call: "cron.lockVerdict", args: [{kind: "pid", pid: 4242}, true, 0, 10000, false], expect: "busy"},
		{call: "cron.lockVerdict", args: [{kind: "pid", pid: 4242}, false, 0, 10000, false], expect: "stale"},
		{call: "cron.lockVerdict", args: [{kind: "empty"}, false, 9999, 10000, false], expect: "pending"},
		{call: "cron.lockVerdict", args: [{kind: "empty"}, false, 10000, 10000, false], expect: "unknown", why: "an acquisition that has lasted the grace is unresolved, not dead"},
		{call: "cron.lockVerdict", args: [{kind: "unreadable"}, false, 99999, 10000, false], expect: "unknown"},
	]}
	"a holder is alive unless kill -0 confirms it missing; a probe that cannot tell fails closed": {suite: "cron", steps: [
		{call: "cron.aliveFromKill", args: [null], expect: true},
		{call: "cron.aliveFromKill", args: ["EPERM"], expect: true, why: "a live process of another user"},
		{call: "cron.aliveFromKill", args: ["ESRCH"], expect: false, why: "the only way a lock is reclaimed"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, kill: {"4242": "EPERM"}}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}, why: "a release of another uid is not evicted"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, kill: {"4242": "EINVAL"}}], expect: {threw: "release-cron lock: cannot tell whether the holder is alive (kill -0: EINVAL); not taken, not removed", pid_file: "4242", lock_kind: "dir", linkedWhole: true, madeLockDir: false}},
	]}
	"giving the lock back unlinks this run's own link and staging directory, and a lock it holds but cannot remove is an error": {suite: "cron", steps: [
		{call: "cronlock.release", args: [{links: {"state/lock": "lock.new.500.a"}, dirs: {"state/lock.new.500.a": 0}, files: {"state/lock.new.500.a/pid": "500"}, stage: "lock.new.500.a"}], expect: {result: "released", lock_kind: null, staging_left: false}},
		{call: "cronlock.release", args: [{links: {"state/lock": "lock.new.500.b"}, dirs: {"state/lock.new.500.b": 0}, files: {"state/lock.new.500.b/pid": "500"}, stage: "lock.new.500.a"}], expect: {result: "not ours", lock_kind: "link", staging_left: true}, why: "the link no longer points at this run's staging directory"},
		{call: "cronlock.release", args: [{links: {"state/lock": "lock.new.7000.a"}, dirs: {"state/lock.new.7000.a": 0}, files: {"state/lock.new.7000.a/pid": "7000"}}], expect: {result: "not ours", lock_kind: "link", staging_left: true}},
		{call: "cronlock.release", args: [{}], expect: {result: "none", lock_kind: null, staging_left: false}},
		{call: "cronlock.release", args: [{links: {"state/lock": "lock.new.500.a"}, dirs: {"state/lock.new.500.a": 0}, files: {"state/lock.new.500.a/pid": "500"}, fail: [{op: "readFile", code: "EACCES"}]}], expect: {threw: "release-cron lock: read pid in state/lock: EACCES: EACCES: readFile state/lock/pid", lock_kind: "link", staging_left: true}, why: "an unreadable pid file is not 'not ours'"},
		{call: "cronlock.release", args: [{links: {"state/lock": "lock.new.500.a"}, dirs: {"state/lock.new.500.a": 0}, files: {"state/lock.new.500.a/pid": "500"}, fail: [{op: "rename", code: "EBUSY"}]}], expect: {threw: "release-cron lock: give back state/lock: EBUSY: EBUSY: rename state/lock", lock_kind: "link", staging_left: true}, why: "a replacement would find a live holder and skip, silently"},
	]}
	"a previous preview's record stops the run, readable or not, naming the record and the cleanup; no record lets it go on": {suite: "cron", steps: [
		{call: "cronlock.preview", args: ["ENOENT", ""], expect: null},
		{call: "cronlock.preview", args: [null, "{\"down\":[\"mise\",\"run\",\"down\"],\"dir\":\"/w/app\"}"], expect: "release-cron: state/lock.preview exists: a preview may be left running; not started. Run `mise run down` in /w/app, then delete state/lock.preview"},
		{call: "cronlock.preview", args: [null, "{\"down\":[\"x\"]}"], expect: "release-cron: state/lock.preview exists: a preview may be left running; not started. Run `x` in its directory, then delete state/lock.preview"},
		{call: "cronlock.preview", args: ["EACCES", ""], expect: "release-cron: state/lock.preview exists but could not be read (EACCES): a preview may be left running; not started. Read the record, run its `down` in its directory, then delete state/lock.preview"},
		{call: "cronlock.preview", args: [null, "not json"], expect: "release-cron: state/lock.preview exists but is not a record this version reads: a preview may be left running; not started. Read it, stop the preview it names, then delete state/lock.preview"},
	]}
	"a serving read after a dropped ssh fails at once on any exit but ssh's own": {suite: "cron", steps: [
		{call: "cron.rescueReadStep", args: [255], expect: "wait", why: "the node may still be finishing"},
		{call: "cron.rescueReadStep", args: [1], expect: "fail", why: "the serving command ran and failed: said at once, not retried for 15 minutes"},
		{call: "cron.rescueReadStep", args: [127], expect: "fail"},
	]}
}
