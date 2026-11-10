# release-notes

After a pronto app's release goes live, a GitHub Release on the app's repo, tagged
`<app>/<revision>` (Bonk Chess: `brawl-chess/bonk-chess-00066-c5h`) on the released commit. The
repo's Releases tab, filtered by the tag prefix, is the app's dashboard of what shipped and when.
Nothing is committed to the app's repo.

A Release says, in plain words, what changed since the release before it, then the facts:

```
## What players see
- Players can now see who is around in the lobby ([#636](https://github.com/bsoneca/pronto/pull/636))

## Behind the scenes
- The release cron no longer stops a long step ([#657](https://github.com/bsoneca/pronto/pull/657))

## The release
| Revision | `bonk-chess-00066-c5h` |  Commit | Pronto version | Went live (BRT) | Release took |
```

Titles read `brawl-chess · 2026-11-04 08:51 BRT · bonk-chess-00066-c5h`. A section with nothing in
it is left out; a release with no pull request says `No changes to <app> since the last release.`;
the first release recorded lists none.

## What it adds

- `release-notes/release-notes.ts`, the driver (Deno), and `release-notes/notes.js`, its rules, pure
  and held by the cases in [`tests/unit/notes.cue`](../tests/unit/notes.cue). Both regenerated; the
  app keeps nothing of its own.
- `release_notes_plugin.cue`, the schema ([`schema.cue`](schema.cue), `#Notes` with its defaults),
  regenerated in the app's own CUE package (the one its `program.cue` names), as release-cron's
  `release_cron_plugin.cue` is. The app's own `release_notes.cue` is optional and never written.

The app needs the `gh` CLI signed in to its repo and to be inside a git checkout whose `origin` is
that repo. With no `release_notes.cue` it needs `GCP.name` in its `release.cue` too (its release
records are `~/.cache/pronto/releases/<name>.jsonl`).

## Configure

An app that says nothing gets what Bonk Chess has always had. To say something, add
`release_notes.cue` to the app, in its package:

```cue
package myapp

releaseNotes: {
	// Where the live releases come from: release-cron's records (default; name defaults to
	// release.cue's GCP.name, read only for this kind), git tags, or GitHub deployments.
	source: {kind: "tags", prefix: "v"}
	// source: {kind: "deployments", environment: "production"}
	timeZone:  "Europe/Lisbon" // default "America/Sao_Paulo"
	zoneLabel: "WET"           // default "BRT"
	// The words of each pull request: Ollama (default; name "qwen3-coder:30b", url
	// "http://localhost:11434"), Claude, or none.
	model: {kind: "claude", name: "claude-haiku-4-5"}
	// model: {kind: "none"}
	audience: "customer" // default "player": the section is "What customers see"
}
```

- `source` `release-cron`: `{kind: "release-cron", name?: string}`, today's records.
- `source` `tags`: git tags `<prefix>*`. The version is the tag minus the prefix, the commit the
  tag's own commit, and the time its tagger's (else committer's) date, so a release started when it
  ended. No Pronto version is known.
- `source` `deployments`: GitHub deployments of the environment whose latest status is `success`
  (`gh api`). The version is the deployment's `ref`, else its `sha` (deployments of one `ref`, a
  branch name, fold into one Release), the commit its `sha`, the end the success status's time and
  the start the deployment's.
- `model` `claude`: the Messages API, with `ANTHROPIC_API_KEY` from the environment (never
  printed); with no key the rules answer. `none`: only `notes.js`'s rules, and nothing is read from
  or kept in the cache. `RELEASE_NOTES_MODEL` in the environment overrides the model's name.
- `audience` is the word the model is asked to write for ("a customer or product reader
  understands") and heads the first section. The model's answers are kept per pull request, whoever
  they were written for.

The driver reads the two files (`release_notes.cue` and `release_notes_plugin.cue`) with the app's
own `cue`, found through `mise` (the shell's, else the newest `mise-v*` under
`~/Library/Caches/sayt` or `~/.cache/sayt`; without any, `cue` on the PATH).

## Use

From a pronto app:

```sh
<this repo>/bin/pronto-release-notes .
deno run -A release-notes/release-notes.ts <app> publish [<revision>]   # the newest live revision, or the named one
deno run -A release-notes/release-notes.ts <app> backfill               # every live revision, oldest first
```

`--dry` prints each Release's title and body and touches nothing on GitHub. A re-run is safe: a
tag that has a Release has it edited (`gh release edit`), else it is made (`gh release create
--target <commit> --latest=false`). A tag or a Release is never deleted or moved. A Release that
cannot be made (its commit is not on GitHub) is said and skipped; `publish` then exits 1, and
`backfill` ends with a count of created, updated and skipped.

## Which Releases

The records that count are `outcome: live`, no `preview`, with a `revision`. A release that kept the
same image makes another record of the same revision: they are one Release, whose facts (commit,
Pronto version, when it went live, how long it took) are the first record's. Its changes are the
pull requests merged to the app's folder (`git log --first-parent base..commit -- <app folder>`)
from `base`, the commit of the record live just before, to the commit of the last record of the
revision. Pull requests are found by their commit subjects: `Merge pull request #N from …` and a
squash's `… (#N)`.

## How the summaries are made

Each pull request (`gh pr view`: title, description, files) goes to the app's model (by default the
local one, through Ollama: `http://localhost:11434`, `qwen3-coder:30b`, or `RELEASE_NOTES_MODEL`),
which answers with one plain line a player or product reader understands and whether a player could
see the change (`notes.js`'s `prompt`; "player" is the configured audience). When it
cannot (not running, bad answer), `notes.js`'s rules do: the title without its conventional prefix
(`feat(x):`, `fix:`, `brawl-chess:`), and "Behind the scenes" when every changed file in the app's
folder is tests, docs, release tools, CI, markdown or toolchain, else "What players see". The model's
answers are kept in `~/.cache/pronto/release-notes/<app>/prs.json` by pull request number, so a
re-run says the same and does not ask again; the rules' are not kept, so the model gets another
try. Times are in the configured zone (default Brasília's, BRT).

## The hook

[release-cron](../release-cron/README.md) runs `publish <revision>` as the last step of a run that
released a new revision, when the app has `release-notes/release-notes.ts`, and records `notes` in
its run. Its failure never changes the run's outcome.

`gh` needs a login that may read the app's pull requests and write its Releases. Run by launchd or
by hand, that is the machine owner's gh login. Under a CI/CD job it is the job's `GH_TOKEN`, which
the hook passes on: a runner started with `SessionCreate` (a launchd service) cannot reach the
owner's login in the keychain. So the job's token needs `contents: write` and `pull-requests: read`
(bsoneca/pronto's `cd.yml`). The repository itself is read from origin's URL.
