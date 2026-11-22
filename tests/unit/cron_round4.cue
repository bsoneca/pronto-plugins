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

	// PRONTO-1032: the three Codex P1s on the lock of #433 (cron.js lockAcquire, on tests/unit/cronlock.js's in-memory file system).
	"a lock is taken with mkdir and a whole pid file; a free lock is ours": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{}], expect: {got: true, pid_file: "500", lock_kind: "dir"}},
	]}
	"a write the file system refuses is an error naming the operation and path, never a skip behind a holder 0": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{fail: [{op: "writeFile", code: "ENOSPC"}]}], expect: {threw: "release-cron lock: write pid in state/lock: ENOSPC: ENOSPC: writeFile state/lock/pid.500.u1.tmp", pid_file: null, lock_kind: null}, why: "the half lock this run made is removed too"},
		{call: "cronlock.run", args: [{fail: [{op: "mkdir", code: "EACCES"}]}], expect: {threw: "release-cron lock: mkdir state/lock: EACCES: EACCES: mkdir state/lock", pid_file: null, lock_kind: null}, why: "a mkdir that is not an existing lock is not contention"},
		{call: "cronlock.run", args: [{fail: [{op: "rename", path: "pid.", code: "EIO"}]}], expect: {threw: "release-cron lock: write pid in state/lock: EIO: EIO: rename state/lock/pid.500.u1.tmp", pid_file: null, lock_kind: null}},
		{call: "cron.claimError", args: ["EEXIST"], expect: "contention"},
		{call: "cron.claimError", args: ["ENOTEMPTY"], expect: "contention"},
		{call: "cron.claimError", args: ["EACCES"], expect: "error"},
		{call: "cron.claimError", args: [null], expect: "error"},
	]}
	"a holder whose pid file cannot be read is an unknown owner: the lock is neither taken nor removed": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, alive: [4242], fail: [{op: "readFile", path: "state/lock/pid", code: "EACCES"}]}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (unreadable EACCES); not taken, not removed", pid_file: "4242", lock_kind: "dir"}, why: "a run that lives behind a pid file this one cannot read"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "not a pid"}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (malformed \"not a pid\"); not taken, not removed", pid_file: "not a pid", lock_kind: "dir"}},
		{call: "cronlock.run", args: [{files: {"state/lock": "x1"}}], expect: {threw: "release-cron lock: state/lock has a holder that cannot be told (malformed \"x1\"); not taken, not removed", pid_file: null, lock_kind: "file"}, why: "the flock version's file, unreadable as a pid"},
	]}
	"a live holder is busy, a verified dead one is taken over, in the directory form and the flock version's file": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir"}},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}, files: {"state/lock/pid": "4242"}}], expect: {got: true, pid_file: "500", lock_kind: "dir"}, why: "4242 is gone"},
		{call: "cronlock.run", args: [{files: {"state/lock": "4242\n"}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: null, lock_kind: "file"}},
		{call: "cronlock.run", args: [{files: {"state/lock": "4242\n"}}], expect: {got: true, pid_file: "500", lock_kind: "dir"}},
	]}
	"a recovery held by a live run leaves the stale lock to it; a recovery whose run died is cleared": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000, "state/lock.recover": 600000}, files: {"state/lock/pid": "4242", "state/lock.recover/pid": "7000"}, alive: [7000]}], expect: {got: false, pid: 7000, pid_file: "4242", lock_kind: "dir"}},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000, "state/lock.recover": 600000}, files: {"state/lock/pid": "4242", "state/lock.recover/pid": "7000"}}], expect: {got: false, pid: 7000, pid_file: "4242", lock_kind: "dir"}, why: "cleared now, taken by the next wake"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000, "state/lock.recover": 600000}, files: {"state/lock/pid": "4242", "state/lock.recover/pid": "7000"}, alive: [7000]}], expect: {got: false, pid: 7000, pid_file: "4242", lock_kind: "dir"}},
	]}
	"the older driver's mkdir-then-write gap: an empty directory is an acquisition in progress, never replaced, and its holder wins": {suite: "cron", steps: [
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}, after: {files: {"state/lock/pid": "4242"}}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir"}, why: "the old run writes its pid after this one looked: both must not proceed"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}, files: {"state/lock/pid": ""}, after: {files: {"state/lock/pid": "4242"}}, alive: [4242]}], expect: {got: false, pid: 4242, pid_file: "4242", lock_kind: "dir"}, why: "its write has begun and is still empty"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 100}}], expect: {got: true, pid_file: "500", lock_kind: "dir"}, why: "no pid ever came: stale after the bounded wait"},
		{call: "cronlock.run", args: [{dirs: {"state/lock": 600000}}], expect: {got: true, pid_file: "500", lock_kind: "dir"}, why: "a pid-less directory an older version left"},
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
		{call: "cron.lockVerdict", args: [{kind: "empty"}, false, 10000, 10000, false], expect: "stale"},
		{call: "cron.lockVerdict", args: [{kind: "unreadable"}, false, 99999, 10000, false], expect: "unknown"},
	]}
}
