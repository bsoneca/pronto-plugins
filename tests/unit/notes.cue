// release-notes' rules (../../release-notes/notes.js) on the inputs they were written for.
package unit

_rec: {
	outcome: *"live" | string
	preview: *"" | string
	pronto:  *"0.24.1-gcp.83" | string
	started: string
	ended:   string
	commit:  string
	revision: string | null
	dirty:   *false | bool
}

_a: _rec & {commit: "aaaaaaaa11111111", revision: "app-00063-f6c", started: "2026-11-03T04:03:40Z", ended: "2026-11-03T04:21:59Z"}
_b: _rec & {commit: "bbbbbbbb22222222", revision: "app-00063-f6c", started: "2026-11-03T06:57:39Z", ended: "2026-11-03T07:14:57Z"}
_c: _rec & {commit: "cccccccc33333333", revision: "app-00064-xx9", started: "2026-11-03T07:18:11Z", ended: "2026-11-03T07:27:30Z"}
_d: _rec & {commit: "dddddddd44444444", revision: "app-00064-xx9", started: "2026-11-03T09:43:01Z", ended: "2026-11-03T09:45:11Z"}
_e: _rec & {commit: "1d2956aa6f8c76f6f4629e3d6f84d131aa2b2646", revision: "bonk-chess-00066-c5h", started: "2026-11-04T11:15:57Z", ended: "2026-11-04T11:51:14Z"}
_failed: _rec & {outcome: "failed", commit: "ffffffff", revision: null, started: "2026-11-03T05:00:00Z", ended: "2026-11-03T05:10:00Z"}
_rc: _rec & {preview: "rc", commit: "99999999", revision: "app-rc-1", started: "2026-11-03T05:20:00Z", ended: "2026-11-03T05:30:00Z"}

cases: {
	"only a live production release with a revision counts, oldest end first": {suite: "notes", steps: [
		{call: "notes.live", args: [[_d, _failed, _a, _rc, (_rec & {commit: "n", revision: null, started: "2026-11-03T08:00:00Z", ended: "2026-11-03T08:10:00Z"})]]},
		{pick: ["0.commit", "1.commit", "length"], expect: ["aaaaaaaa11111111", "dddddddd44444444", 2]},
		{call: "notes.live", args: [[(_a & {preview: ""})]]},
		{get: "length", expect: 1, why: "an empty preview is production"},
		{call: "notes.live", args: [[]], expect: []},
	]}
	"records of one revision fold into one release, its facts the first record's, its range from the record live before it": {suite: "notes", steps: [
		{call: "notes.releases", args: [[_a, _b, _c, _d]]},
		{keep: "r"},
		{get: "length", expect: 2},
		{use: "r"},
		{get: "0", holds: {revision: "app-00063-f6c", base: null, first: {commit: "aaaaaaaa11111111"}, last: {commit: "bbbbbbbb22222222"}}, why: "the first release recorded has no base"},
		{use: "r"},
		{get: "1", holds: {revision: "app-00064-xx9", base: "bbbbbbbb22222222", first: {commit: "cccccccc33333333"}, last: {commit: "dddddddd44444444"}}, why: "the base is the last record of the revision before"},
	]}
	"records given out of order, with failures between them, make the same releases": {suite: "notes", steps: [
		{call: "notes.releases", args: [[_d, _failed, _c, _rc, _b, _a]]},
		{pick: ["0.revision", "1.revision", "1.base", "length"], expect: ["app-00063-f6c", "app-00064-xx9", "bbbbbbbb22222222", 2]},
	]}
	"a release is tagged by its app and revision": {suite: "notes", steps: [
		{call: "notes.tag", args: ["brawl-chess", "bonk-chess-00066-c5h"], expect: "brawl-chess/bonk-chess-00066-c5h"},
	]}
	"pull requests are found in first-parent subjects, once each, ascending": {suite: "notes", steps: [
		{call: "notes.prNumbers", args: [["Merge pull request #637 from bsoneca/feat/bonk-bot-while-waiting", "Merge remote-tracking branch 'origin/main' into tmp-merge-637", "Merge pull request #636 from bsoneca/feat/x", "Fix the lobby (#640)", "Merge pull request #637 from bsoneca/again"]], expect: [636, 637, 640]},
		{call: "notes.prNumbers", args: [["Direct commit to main", "Mentions #12 in the middle (see #13) of it"]], expect: [], why: "only the two merge shapes count"},
		{call: "notes.prNumbers", args: [[]], expect: []},
	]}
	"a pull request is behind the scenes when every file it changes in the app is tests, docs, release tools, CI, markdown or toolchain": {suite: "notes", steps: [
		{call: "notes.players", args: [["apps/brawl-chess/tests/unit/a.cue", "apps/brawl-chess/docs/x.md", "apps/brawl-chess/release-cron/cron.js", "apps/brawl-chess/release-notes/notes.js", "apps/brawl-chess/.github/w.yml", "apps/brawl-chess/README.md", "apps/brawl-chess/mise.lock"], "apps/brawl-chess"], expect: false},
		{call: "notes.players", args: [["apps/brawl-chess/tests/unit/a.cue", "apps/brawl-chess/hatch-src/src/lobby.js"], "apps/brawl-chess"], expect: true, why: "one served file is enough"},
		{call: "notes.players", args: [["apps/brawl-chess/services/database/migrations/1.sql"], "apps/brawl-chess"], expect: true},
		{call: "notes.players", args: [["apps/brawl-chess-x/hatch/a.js", "docs/readme.txt"], "apps/brawl-chess"], expect: false, why: "files outside the app's folder do not count; a sibling sharing the prefix is not it"},
		{call: "notes.players", args: [["apps/brawl-chess/hatch/docs/a.js"], "apps/brawl-chess"], expect: true, why: "only the top-level tests/docs folders are hidden"},
	]}
	"the summary without a model is the title without its prefixes, capitalised": {suite: "notes", steps: [
		{call: "notes.plain", args: ["feat(bonk): lobby shows who is around"], expect: "Lobby shows who is around"},
		{call: "notes.plain", args: ["fix: stop the release timing out (#657)"], expect: "Stop the release timing out"},
		{call: "notes.plain", args: ["brawl-chess: feat(lobby): bots fill in while waiting"], expect: "Bots fill in while waiting"},
		{call: "notes.plain", args: ["Bonk Chess: new board"], expect: "Bonk Chess: new board", why: "a capitalised lead is a title, not a prefix"},
		{call: "notes.plain", args: ["Add a lobby"], expect: "Add a lobby"},
	]}
	"the rules sum a pull request up from its title and files": {suite: "notes", steps: [
		{call: "notes.fallback", args: [{title: "fix(release-cron): no step limits", files: [{path: "apps/brawl-chess/release-cron/cron.js"}]}, "apps/brawl-chess"], expect: {summary: "No step limits", players: false}},
		{call: "notes.fallback", args: [{title: "feat: bots while waiting", files: [{path: "apps/brawl-chess/hatch-src/src/bot.js"}]}, "apps/brawl-chess"], expect: {summary: "Bots while waiting", players: true}},
	]}
	"a time is read in Brasília, to the minute": {suite: "notes", steps: [
		{call: "notes.brt", args: ["2026-11-04T11:51:14Z"], expect: "2026-11-04 08:51 BRT"},
		{call: "notes.brt", args: ["2026-11-04T02:30:00Z"], expect: "2026-11-03 23:30 BRT", why: "the date follows the zone"},
	]}
	"the minutes a release took, one decimal": {suite: "notes", steps: [
		{call: "notes.minutes", args: ["2026-11-04T11:15:57Z", "2026-11-04T11:51:14Z"], expect: "35.3"},
		{call: "notes.minutes", args: ["2026-11-03T09:43:01Z", "2026-11-03T09:45:11Z"], expect: "2.2"},
		{call: "notes.minutes", args: ["2026-11-03T09:00:00Z", "2026-11-03T09:10:00Z"], expect: "10.0"},
	]}
	"a release is titled by its app, when it went live and its revision": {suite: "notes", steps: [
		{call: "notes.title", args: ["brawl-chess", {revision: "bonk-chess-00066-c5h", first: _e}], expect: "brawl-chess · 2026-11-04 08:51 BRT · bonk-chess-00066-c5h"},
	]}
	"the body lists what players see, then behind the scenes, then the release": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "brawl-chess", repo: "bsoneca/pronto", release: {revision: "bonk-chess-00066-c5h", first: _e, last: _e, base: "bbbbbbbb"}, prs: [
			{number: 636, summary: "Players can see who is around in the lobby", players: true},
			{number: 657, summary: "The release no longer stops a long step", players: false},
			{number: 660, summary: "Bots fill in while a table waits", players: true},
		]}], expect: """
			## What players see

			- Players can see who is around in the lobby ([#636](https://github.com/bsoneca/pronto/pull/636))
			- Bots fill in while a table waits ([#660](https://github.com/bsoneca/pronto/pull/660))

			## Behind the scenes

			- The release no longer stops a long step ([#657](https://github.com/bsoneca/pronto/pull/657))

			## The release

			| | |
			|---|---|
			| Revision | `bonk-chess-00066-c5h` |
			| Commit | [`1d2956aa`](https://github.com/bsoneca/pronto/commit/1d2956aa6f8c76f6f4629e3d6f84d131aa2b2646) |
			| Pronto version | 0.24.1-gcp.83 |
			| Went live | 2026-11-04 08:51 BRT |
			| Release took | 35.3 min |

			<!-- release-notes app=brawl-chess revision=bonk-chess-00066-c5h commit=1d2956aa6f8c76f6f4629e3d6f84d131aa2b2646 -->

			"""},
	]}
	"a section with nothing in it is left out": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 1, summary: "Only inside", players: false}]}], matches: "^## Behind the scenes\n\n- Only inside \\(\\[#1\\]\\(https://github.com/o/r/pull/1\\)\\)\n\n## The release"},
	]}
	"a release with no pull request says so, and the first release recorded lists none": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "brawl-chess", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: []}], matches: "^No changes to brawl-chess since the last release.\n\n## The release"},
		{call: "notes.body", args: [{app: "brawl-chess", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: null}, prs: []}], matches: "^This is the first release recorded; the changes before it are not listed.\n\n## The release"},
	]}
	"the same input makes the same body": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 2, summary: "x", players: true}]}]},
		{keep: "one"},
		{call: "notes.body", args: [{app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 2, summary: "x", players: true}]}], expect: "$one"},
	]}
}
