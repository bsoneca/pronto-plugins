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
| `tests/scenarios.ts` | runs an app's scenarios (`tests/scenarios/*.cue`) in browsers against its door |
| `tests/scenarios/schema.cue` | what a scenario may say, and the facts the runner reads beside the scenarios |
| `tests/scenarios/select.ts` | which scenarios the runner runs: their inputs as at their last green run |
| `tests/scenarios/early.ts` | a promise the runner starts before the step that awaits it, marked handled |
| `tests/slow.ts` | the throttling a slowed scenario's pages get, as a preview's |

The last five go only to an app that runs scenarios (it has `tests/scenarios.ts`).

An app keeps only its own: `tests/unit/suites.cue`, `tests/unit/registry.js`, `tests/unit/probes.js`,
its cases and its scenarios, and, where its scenarios need them:

- `tests/scenarios/app.cue`: the facts `schema.cue` names with a default the app does not share (the
  screen and locale its actors read it on, its messages, how its pages load, the sources the selection
  judges by bytes, its database, its passkey sign-in, `parallel`), the fields its actors have besides a
  name (`#Actor`), its own step kinds (`#Gestures`) and those a production scenario may not take
  (`#barred`). It is CUE of the scenarios' package: one place, held by the schema.
- `tests/scenarios/app.ts`: what its own step kinds do, and the moments it adds to (a browser's first
  script, a page's load, a sign-up, a payment, a failure's report), as `tests/unit/registry.js` is to
  unit cases. Its default export is the runner's `Hooks`; it imports only the runner's types, since
  the runner imports it.

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
the scenarios' five only with scenarios, none seeded, no header. ci writes the harness into a
scratch app and compares each file with `cmp`.
