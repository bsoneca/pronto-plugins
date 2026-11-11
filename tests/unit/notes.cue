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

// What an app that says nothing gets (release-notes/schema.cue's defaults).
_zone: {timeZone: "America/Sao_Paulo", zoneLabel: "BRT", audience: "player"}

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
	"a time is read in the zone it is given, to the minute, with the label it is given": {suite: "notes", steps: [
		{call: "notes.stamp", args: ["2026-11-04T11:51:14Z", "America/Sao_Paulo", "BRT"], expect: "2026-11-04 08:51 BRT"},
		{call: "notes.stamp", args: ["2026-11-04T02:30:00Z", "America/Sao_Paulo", "BRT"], expect: "2026-11-03 23:30 BRT", why: "the date follows the zone"},
		{call: "notes.stamp", args: ["2026-11-04T11:51:14Z", "Europe/Lisbon", "WET"], expect: "2026-11-04 11:51 WET"},
		{call: "notes.stamp", args: ["2026-07-04T23:30:00Z", "Europe/Lisbon", "WET"], expect: "2026-07-05 00:30 WET", why: "the zone's own offset (summer time) is kept, the label is the app's word"},
	]}
	"the minutes a release took, one decimal": {suite: "notes", steps: [
		{call: "notes.minutes", args: ["2026-11-04T11:15:57Z", "2026-11-04T11:51:14Z"], expect: "35.3"},
		{call: "notes.minutes", args: ["2026-11-03T09:43:01Z", "2026-11-03T09:45:11Z"], expect: "2.2"},
		{call: "notes.minutes", args: ["2026-11-03T09:00:00Z", "2026-11-03T09:10:00Z"], expect: "10.0"},
	]}
	"a release is titled by its app, when it went live and its revision": {suite: "notes", steps: [
		{call: "notes.title", args: ["brawl-chess", {revision: "bonk-chess-00066-c5h", first: _e}, "America/Sao_Paulo", "BRT"], expect: "brawl-chess · 2026-11-04 08:51 BRT · bonk-chess-00066-c5h"},
		{call: "notes.title", args: ["shop", {revision: "v1", first: _e}, "Europe/Lisbon", "WET"], expect: "shop · 2026-11-04 11:51 WET · v1", why: "the zone and its label thread through the title"},
	]}
	"the body lists what players see, then behind the scenes, then the release": {suite: "notes", steps: [
		{call: "notes.body", args: [{_zone, app: "brawl-chess", repo: "bsoneca/pronto", release: {revision: "bonk-chess-00066-c5h", first: _e, last: _e, base: "bbbbbbbb"}, prs: [
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
		{call: "notes.body", args: [{_zone, app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 1, summary: "Only inside", players: false}]}], matches: "^## Behind the scenes\n\n- Only inside \\(\\[#1\\]\\(https://github.com/o/r/pull/1\\)\\)\n\n## The release"},
	]}
	"a release with no pull request says so, and the first release recorded lists none": {suite: "notes", steps: [
		{call: "notes.body", args: [{_zone, app: "brawl-chess", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: []}], matches: "^No changes to brawl-chess since the last release.\n\n## The release"},
		{call: "notes.body", args: [{_zone, app: "brawl-chess", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: null}, prs: []}], matches: "^This is the first release recorded; the changes before it are not listed.\n\n## The release"},
	]}
	"the same input makes the same body": {suite: "notes", steps: [
		{call: "notes.body", args: [{_zone, app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 2, summary: "x", players: true}]}]},
		{keep: "one"},
		{call: "notes.body", args: [{_zone, app: "a", repo: "o/r", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 2, summary: "x", players: true}]}], expect: "$one"},
	]}
	"git tags make the live records: the version is the tag without its prefix, the commit the tag's own, the time its date in UTC": {suite: "notes", steps: [
		{call: "notes.fromTags", args: [[
			"shop/v1.0\t1111aaaa\t\t2026-11-04T08:51:14-03:00",
			"shop/v1.1\ttagobj22\tcccc2222\t2026-11-05T10:00:00+00:00",
			"shop/\t3333eeee\t\t2026-11-06T10:00:00+00:00",
			"other/v9\t4444ffff\t\t2026-11-07T10:00:00+00:00",
			"",
		], "shop/"], expect: [
			{outcome: "live", revision: "v1.0", commit: "1111aaaa", started: "2026-11-04T11:51:14Z", ended: "2026-11-04T11:51:14Z"},
			{outcome: "live", revision: "v1.1", commit: "cccc2222", started: "2026-11-05T10:00:00Z", ended: "2026-11-05T10:00:00Z"},
		], why: "an annotated tag's commit is its dereferenced object; a tag that is only the prefix, or another prefix's, is no version"},
	]}
	"tag records fold into releases like any others, the base the tag before": {suite: "notes", steps: [
		{call: "notes.fromTags", args: [["shop/v2\t2222bbbb\t\t2026-11-06T10:00:00Z", "shop/v1\t1111aaaa\t\t2026-11-04T10:00:00Z"], "shop/"]},
		{keep: "records"},
		{call: "notes.releases", args: ["$records"]},
		{pick: ["length", "0.revision", "0.base", "1.revision", "1.base"], expect: [2, "v1", null, "v2", "1111aaaa"]},
	]}
	"GitHub deployments make the live records when their latest status is success: the version its ref, else its sha": {suite: "notes", steps: [
		{call: "notes.fromDeployments", args: [[
			{sha: "s1", ref: "v1", created_at: "2026-11-01T10:00:00Z", statuses: [{state: "success", created_at: "2026-11-01T10:05:00Z"}, {state: "in_progress", created_at: "2026-11-01T10:01:00Z"}]},
			{sha: "s2", ref: "v2", created_at: "2026-11-02T10:00:00Z", statuses: [{state: "failure", created_at: "2026-11-02T10:05:00Z"}, {state: "success", created_at: "2026-11-02T10:03:00Z"}]},
			{sha: "s3", ref: "", created_at: "2026-11-03T12:00:00Z", statuses: [{state: "success", created_at: "2026-11-03T12:05:00Z"}]},
			{sha: "s4", ref: "v4", created_at: "2026-11-04T12:00:00Z", statuses: []},
			{sha: "s5", ref: "v5", created_at: "2026-11-05T13:00:00Z", statuses: [{state: "in_progress", created_at: "2026-11-05T13:01:00Z"}, {state: "success", created_at: "2026-11-05T13:05:00Z"}]},
		]], expect: [
			{outcome: "live", revision: "v1", commit: "s1", started: "2026-11-01T10:00:00Z", ended: "2026-11-01T10:05:00Z"},
			{outcome: "live", revision: "s3", commit: "s3", started: "2026-11-03T12:00:00Z", ended: "2026-11-03T12:05:00Z"},
			{outcome: "live", revision: "v5", commit: "s5", started: "2026-11-05T13:00:00Z", ended: "2026-11-05T13:05:00Z"},
		], why: "a later failure takes a deployment out; one with no status never went live; the latest status is by time, not by position"},
		{call: "notes.fromDeployments", args: [[]], expect: []},
	]}
	"deployment records fold into releases like any others": {suite: "notes", steps: [
		{call: "notes.fromDeployments", args: [[
			{sha: "s1", ref: "v1", created_at: "2026-11-01T10:00:00Z", statuses: [{state: "success", created_at: "2026-11-01T10:05:00Z"}]},
			{sha: "s2", ref: "v2", created_at: "2026-11-02T10:00:00Z", statuses: [{state: "success", created_at: "2026-11-02T10:05:00Z"}]},
		]]},
		{keep: "records"},
		{call: "notes.releases", args: ["$records"]},
		{pick: ["length", "1.revision", "1.base"], expect: [2, "v2", "s1"]},
	]}
	"with no model the words of a pull request are the rules' alone": {suite: "notes", steps: [
		{call: "notes.fallback", args: [{title: "feat(lobby): who is around", body: "ignored", files: [{path: "apps/shop/web/lobby.js"}, {path: "apps/shop/tests/unit/a.cue"}]}, "apps/shop"], expect: {summary: "Who is around", players: true}},
		{call: "notes.fallback", args: [{title: "ci: faster gate", files: [{path: "apps/shop/.github/w.yml"}]}, "apps/shop"], expect: {summary: "Faster gate", players: false}},
	]}
	"a model's answer is a summary and whether the audience would notice, or nothing": {suite: "notes", steps: [
		{call: "notes.answer", args: ["{\"summary\": \"Bots fill in while a table waits.\", \"players\": true}"], expect: {summary: "Bots fill in while a table waits", players: true}},
		{call: "notes.answer", args: ["Here it is:\n```json\n{\"summary\": \"A new\\n screen\", \"players\": false}\n```"], expect: {summary: "A new screen", players: false}, why: "a model with no JSON mode wraps its answer"},
		{call: "notes.answer", args: ["{\"summary\": \"x\", \"players\": \"yes\"}"], expect: null},
		{call: "notes.answer", args: ["{\"summary\": \"\", \"players\": true}"], expect: null},
		{call: "notes.answer", args: ["not json"], expect: null},
	]}
	"the default audience's prompt is the one release-notes has always sent": {suite: "notes", steps: [
		{call: "notes.prompt", args: [{title: "feat: lobby shows who is around", body: "Adds a roster.", files: [{path: "apps/brawl-chess/hatch-src/src/lobby.js"}, {path: "apps/brawl-chess/tests/unit/a.cue"}]}, "player"], expect: "A pull request to a game or web app. Say what it changes in ONE line of at most 20 words that a player or product reader understands: no file names, function names, PR numbers or commit jargon. Set players to true only if a person playing or using the product would notice the change on screen or in how it behaves (a new feature, a rule, a screen, a fix of something they hit, a price). Set it false for everything a player never notices: tests, docs, CI, how and when releases or deploys happen, release automation, rehearsals, analytics, tracking and telemetry, monitoring, build and test speed, flags or files the build needs, database internals and refactors. When unsure, false. Answer as JSON {\"summary\": string, \"players\": boolean}.\n\nTitle: feat: lobby shows who is around\n\nDescription:\nAdds a roster.\n\nFiles changed:\napps/brawl-chess/hatch-src/src/lobby.js\napps/brawl-chess/tests/unit/a.cue"},
	]}
	"another audience is in the prompt's wording, with its article": {suite: "notes", steps: [
		{call: "notes.prompt", args: [{title: "t", body: "b", files: []}, "operator"], matches: "of at most 20 words that an operator or product reader understands: no file names"},
		{call: "notes.prompt", args: [{title: "t", body: "b", files: []}, "shopper"], matches: "of at most 20 words that a shopper or product reader understands: no file names"},
		{call: "notes.prompt", args: [{title: "t", files: []}, "player"], matches: "Description:\n\n\nFiles changed:\n$", why: "a pull request with no description is asked about all the same"},
	]}
	"the first section of a body is headed by its audience": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "shop", repo: "o/r", timeZone: "Europe/Lisbon", zoneLabel: "WET", audience: "operator", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: [{number: 1, summary: "Shows the till", players: true}, {number: 2, summary: "Tests only", players: false}]}], matches: "^## What operators see\n\n- Shows the till \\(\\[#1\\]\\(https://github.com/o/r/pull/1\\)\\)\n\n## Behind the scenes\n\n- Tests only"},
	]}
	"a body dates the release in the app's zone, with its label": {suite: "notes", steps: [
		{call: "notes.body", args: [{app: "shop", repo: "o/r", timeZone: "Europe/Lisbon", zoneLabel: "WET", audience: "player", release: {revision: "r", first: _e, last: _e, base: "b"}, prs: []}], matches: "\\| Went live \\| 2026-11-04 11:51 WET \\|\n"},
	]}
}

// An app releasing to a command target has no pronto release records: release-cron's runs that released are its
// releases (PRONTO-205).
cases: "release-cron's released runs are the records of an app with no Cloud Run release": {suite: "notes", steps: [
	{call: "notes.fromCronRuns", args: [[
		{outcome: "failed", commit: "a", started: "s0", ended: "e0"},
		{outcome: "released", commit: "b", revision: "b", started: "s1", ended: "e1", steps: {release: 184}},
		{outcome: "skipped", commit: "c", revision: "c", started: "s2", ended: "e2"},
	]], expect: [{outcome: "live", revision: "b", commit: "b", started: "s1", ended: "e1"}]},
	{call: "notes.fromCronRuns", args: [[{outcome: "released", commit: "d", started: "s", ended: "e"}]], expect: [], why: "a run that released nothing new names no revision"},
]}
