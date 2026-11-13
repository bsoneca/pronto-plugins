# harness

The test files every pronto app holds byte for byte the same: the one copy of what each app used to
copy by hand from `apps/brawl-chess` (bsoneca/pronto's AGENTS.md, "Tests are data"; PRONTO-480).

| file | what it is |
| --- | --- |
| `tests/slot.ts` | the machine's slots and weight budget: ports for a local stack, cores and memory for a job |
| `tests/unit.ts` | runs an app's unit cases (`tests/unit/*.cue`) as Deno tests, a suite at a time |
| `tests/unit/select.js` | which suites are cached: their inputs as at their last green run |
| `tests/unit/schema.cue` | what a unit case may say |
| `tests/browser.ts` | the browsers a run launches, shut down however it ends |
| `tests/lint.ts` | the release guards `test` runs: generated files, the image's files, the schema |
| `tests/scenarios/select.ts` | which scenarios the runner runs; only in an app with `tests/scenarios.ts` |

An app keeps only its own: `tests/unit/suites.cue`, `tests/unit/registry.js`, `tests/unit/probes.js`,
its cases and its scenarios.

## Use

```sh
<this repo>/bin/pronto-harness <app-dir>...
```

Each file is regenerated, never seeded: an app's copy is never its own, so a change to one is made
here, in `files/`, and written into every app. The files carry no header, so an app's copy, another
app's and this one compare with `cmp`.

bsoneca/pronto pins the commit its apps' copies come from (`.github/harness.pin`), and its ci holds
apps/brawl-chess's copies to that commit; `.github/ci-shared` holds every other app's to
brawl-chess's. To change the harness: change `files/` here and merge; then in pronto move the pin
to that merge and run `bin/pronto-harness` on every app, in one pull request.

This repository's own `tests/unit.ts`, `tests/unit/select.js` and `tests/unit/schema.cue` are the
same files, held to `files/` by ci.

## Tests

`cue vet -c ./harness` holds the host to [`tests.cue`](tests.cue): the six files every app gets,
the scenarios' selector only with scenarios, none seeded, no header. ci writes the harness into a
scratch app and compares each file with `cmp`.
