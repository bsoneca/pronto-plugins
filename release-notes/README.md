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

The app needs `GCP.name` in its `release.cue` (its release records are
`~/.cache/pronto/releases/<name>.jsonl`), the `gh` CLI signed in to its repo, and the app inside a
git checkout whose `origin` is that repo.

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

Each pull request (`gh pr view`: title, description, files) goes to the local model through Ollama
(`http://localhost:11434`, `qwen3-coder:30b`, or `RELEASE_NOTES_MODEL`), which answers with one
plain line a player or product reader understands and whether a player could see the change. When it
cannot (not running, bad answer), `notes.js`'s rules do: the title without its conventional prefix
(`feat(x):`, `fix:`, `brawl-chess:`), and "Behind the scenes" when every changed file in the app's
folder is tests, docs, release tools, CI, markdown or toolchain, else "What players see". The model's
answers are kept in `~/.cache/pronto/release-notes/<app>/prs.json` by pull request number, so a
re-run says the same and does not ask again; the rules' are not kept, so the model gets another
try. Times are Brasília's.

## The hook

[release-cron](../release-cron/README.md) runs `publish <revision>` as the last step of a run that
released a new revision, when the app has `release-notes/release-notes.ts`, and records `notes` in
its run. Its failure never changes the run's outcome.
