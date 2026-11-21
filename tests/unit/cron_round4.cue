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
}
