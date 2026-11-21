// release-cron's decisions of the fourth Codex round (PRONTO-870): the patch-id check, the backport check on every deploying run, NUL-separated paths,
// the abandon lock, the rehearsal's environment, the flags bookkeeping, a held release's resume and its trusted checkout, linear branches, the
// preview's `up` during a signal and the outcome names (../../release-cron/cron.js).
package unit

import "github.com/bsoneca/pronto-plugins/release-cron:releasecron"

_outcomes: releasecron.#Cron.outcomes

cases: {
	"the patch ids of a range count only when both git processes succeeded; a failure stops the backport check": {suite: "cron", steps: [
		{call: "cron.patchIdsOf", args: [{ok: true, code: 0, out: "", err: ""}, {ok: true, code: 0, out: "p1 aaa\np2 bbb\n", err: ""}], expect: {ids: {aaa: "p1", bbb: "p2"}}},
		{call: "cron.patchIdsOf", args: [{ok: false, code: 142, out: "", err: ""}, {ok: true, code: 0, out: "p1 aaa\n", err: ""}], expect: {error: "git log -p failed (exit 142): no output"}, why: "a timed-out log leaves a partial list: never read as empty commits"},
		{call: "cron.patchIdsOf", args: [{ok: true, code: 0, out: "", err: ""}, {ok: false, code: 128, out: "", err: "fatal: bad object\nmore"}], expect: {error: "git patch-id failed (exit 128): fatal: bad object"}},
	]}
	"a commit with no patch id is empty only when it has no tree change": {suite: "cron", steps: [
		{call: "cron.patchOf", args: ["aaaaaaaaaaaa", "p1", {ok: true, out: ""}], expect: {patch: "p1"}},
		{call: "cron.patchOf", args: ["aaaaaaaaaaaa", null, {ok: true, out: ""}], expect: {patch: null}, why: "an empty commit: nothing to carry"},
		{call: "cron.patchOf", args: ["aaaaaaaaaaaa", null, {ok: true, out: ":100644 100644 a b M\tf.js\n"}], expect: {error: "aaaaaaaa changes the tree but has no patch id"}, why: "a truncated patch-id output must not make a fix empty"},
		{call: "cron.patchOf", args: ["aaaaaaaaaaaa", null, {ok: false, out: "", err: "fatal: bad object x"}], expect: {error: "aaaaaaaa has no patch id and its tree change could not be read: fatal: bad object x"}},
	]}
	"the released branch's backport check runs on every run that can deploy main, a ref override too": {suite: "cron", steps: [
		{call: "cron.backportCheck", args: [null, {branch: "release/x/1", tip: "t"}], expect: true, why: "RELEASE_CRON_REF=origin/main is still checked against the commit it releases"},
		{call: "cron.backportCheck", args: [null, null], expect: false, why: "no record"},
		{call: "cron.backportCheck", args: [{branch: "release/x/1"}, {branch: "release/x/1", tip: "t"}], expect: false, why: "a held run is the branch's own"},
	]}
	"changed paths are read NUL-separated, so a path git would quote still starts with its folder": {suite: "cron", steps: [
		{call: "cron.heldDiffArgs", args: ["b", "h"], expect: ["diff", "--no-renames", "--name-only", "-z", "b", "h"]},
		{call: "cron.nulPaths", args: ["apps/studio/services/database/migrations/m\u00e9.sql\u0000apps/studio/a.js\u0000"], expect: ["apps/studio/services/database/migrations/m\u00e9.sql", "apps/studio/a.js"], why: "non-ASCII, unquoted"},
		{call: "cron.nulPaths", args: ["a\nb.js\u0000c.js\u0000"], expect: ["a\nb.js", "c.js"], why: "a newline is part of a name"},
		{call: "cron.nulPaths", args: [""], expect: []},
		{call: "cron.migrationFiles", args: [["apps/studio/services/database/migrations/m\u00e9.sql"], "apps/studio"], expect: ["apps/studio/services/database/migrations/m\u00e9.sql"]},
	]}
	"abandon and a run take the lock the same way": {suite: "cron", steps: [
		{call: "cron.lockStep", args: [true, 0, false], expect: "take"},
		{call: "cron.lockStep", args: [false, 4242, true], expect: "busy", why: "a live holder: a run skips, abandon refuses, neither reads or changes anything"},
		{call: "cron.lockStep", args: [false, 4242, false], expect: "takeover", why: "a dead holder's lock"},
		{call: "cron.lockStep", args: [false, 0, false], expect: "takeover", why: "no pid written"},
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
	"a held release resumes at confirmation only on a post-deployment marker, else runs again": {suite: "cron", steps: [
		{call: "cron.servingPlan", args: [{branch: "release/x/1"}, "c1", "c1", true], expect: "resume"},
		{call: "cron.servingPlan", args: [{branch: "release/x/1"}, "c1", "c1", false], expect: "rerun", why: "the node's worktree HEAD moved before release@k8s ran: live === head proves nothing"},
		{call: "cron.servingPlan", args: [{branch: "release/x/1"}, "c1", "c1", null], expect: "rerun"},
		{call: "cron.servingPlan", args: [null, "c1", "c1", false], expect: "skip", why: "main already serving"},
		{call: "cron.servingPlan", args: [{branch: "release/x/1"}, "c0", "c1", true], expect: "proceed"},
		{call: "cron.servingPlan", args: [null, null, "c1", false], expect: "proceed"},
		{call: "cron.rerunWhy", args: ["release/x/1", _sha1], matches: "release/x/1 at 11111111 is what the node's worktree reads, but its serving command has no post-deployment marker"},
	]}
	"a held release is refused when the scheduler runs from the run's own checkout": {suite: "cron", steps: [
		{call: "cron.heldTrusted", args: ["/h/.cache/pronto/release-cron/studio/wt", "/h/.cache/pronto/release-cron/studio/wt"], matches: "^the scheduler runs from the run's own checkout \\(/h/.cache/pronto/release-cron/studio/wt\\)"},
		{call: "cron.heldTrusted", args: ["/h/.cache/pronto/release-cron/studio/wt/", "/h/.cache/pronto/release-cron/studio/wt"], matches: "separate trusted checkout", why: "a trailing slash is the same checkout"},
		{call: "cron.heldTrusted", args: ["/h/code/pronto-release", "/h/.cache/pronto/release-cron/studio/wt"], expect: null, why: "a separate trusted checkout"},
	]}
	"a merge with a nonempty combined diff refuses the tip: release branches stay linear": {suite: "cron", steps: [
		{call: "cron.resolvedMerges", args: [[{sha: _sha1, cc: "diff --cc a.js\n+x\n"}, {sha: _sha2, cc: ""}, {sha: "3333333333333333333333333333333333333333", cc: "\n"}]], expect: [_sha1], why: "a clean merge (an empty combined diff) is fine"},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: [], migrations: [], resolved: [_sha1]}], expect: "1 merge with a nonempty combined diff (a conflict resolution): 11111111; release branches stay linear: rebase the branch or cherry-pick onto it instead (`abandon --force` is the way out)"},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: [], migrations: [], resolved: []}], expect: null},
		{call: "cron.refusedTip", args: [{descends: true, unmerged: [], migrations: []}], expect: null, why: "no merges read"},
	]}
	"a signal waits for the preview's up, stops its group only past its own limit, and down runs after": {suite: "cron", steps: [
		{call: "cron.signalStops", args: ["rehearsal"], expect: true},
		{call: "cron.signalStops", args: ["preview"], expect: false, why: "up is not stopped at the signal: stopping it ends only the local ssh while the remote release goes on"},
		{call: "cron.signalStops", args: ["down"], expect: false},
		{call: "cron.previewUpStep", args: [true, 600000, 7200000, 60000], expect: "wait", why: "a signal 10 min into up"},
		{call: "cron.previewUpStep", args: [true, 7199999, 7200000, 60000], expect: "wait"},
		{call: "cron.previewUpStep", args: [true, 7200000, 7200000, 60000], expect: "term", why: "its own limit is over: its process group (the recorded pid) is stopped"},
		{call: "cron.previewUpStep", args: [true, 7260000, 7200000, 60000], expect: "kill", why: "still there past the grace"},
		{call: "cron.previewUpStep", args: [false, 900000, 7200000, 60000], expect: "gone", why: "up ended by itself: down runs"},
		{call: "cron.upExtra", args: [600000, 7200000, 60000], expect: 6660000, why: "the lock waits at most the rest of up's limit and the grace, beside the teardown"},
		{call: "cron.upExtra", args: [8000000, 7200000, 60000], expect: 60000},
		{call: "cron.signalStep", args: [false, 1, 61000, 60000, 300000 + 6660000], expect: "wait", why: "up has ended but down still runs: the lock is held"},
	]}
	"release-cron's outcome names come from releaseCron.outcomes": {suite: "cron", steps: [
		{call: "cron.branchOutcome", args: ["held", "release/x/1"], expect: "\(_outcomes.held) release/x/1"},
		{call: "cron.branchOutcome", args: ["abandoned", "release/x/1"], expect: "\(_outcomes.abandoned) release/x/1"},
		{call: "cron.branchOutcome", args: ["heldRefused", "release/x/1"], expect: "\(_outcomes.heldRefused) release/x/1"},
		{call: "cron.branchOutcome", args: ["heldBackport", "release/x/1"], expect: "\(_outcomes.heldBackport) release/x/1"},
		{call: "cron.spaced", args: [_outcomes.released], expect: true},
		{call: "cron.spaced", args: [_outcomes.failed], expect: true},
		{call: "cron.spaced", args: ["\(_outcomes.abandoned) release/x/1"], expect: true},
		{call: "cron.spaced", args: ["\(_outcomes.heldRefused) release/x/1"], expect: false},
		{call: "cron.endWhenInterrupted", args: [true, _outcomes.failed], expect: _outcomes.stopped},
		{call: "cron.endWhenInterrupted", args: [true, _outcomes.released], expect: _outcomes.released},
	]}
	"a run whose tree moved under the rehearsal has the cause treeMoved and gives no verdict": {suite: "cron", steps: [
		{call: "cron.failureOf", args: ["treeMoved", {from: "aaaaaaaa", to: "bbbbbbbb"}], expect: {why: "\(releasecron.#Cron.causes.treeMoved) from aaaaaaaa to bbbbbbbb while the rehearsal and the preview ran: nothing released", cause: "treeMoved"}},
		{call: "cron.noVerdictRun", args: ["x", "treeMoved"], expect: true, why: "infrastructure, not a failed rehearsal"},
		{call: "cron.noVerdictRun", args: ["the run's tree moved from a to b while the rehearsal and the preview ran: nothing released", null], expect: true, why: "an older record, read by its why"},
	]}
}
