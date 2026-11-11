# Flag rollback drill

A flag flip broke a critical journey: the probe caught it and named the flip, and `pronto-flags rollback` brought it back. This was run on 2026-11-07, on this machine alone. The pieces it used are the framework's, not the drill's:

- [pronto-probe](../probe/README.md) runs an app's journeys (`probes_spec.cue`) on a schedule and alerts at the N-th failure in a row. The alert lists the flag writes made just before the first failure, each with the `pronto-flags rollback` that undoes it. When the probe passes again, it says how long the journey was down.
- [pronto-flags](../flags/README.md) has three additions:
  - **Flip journal.** Every write (push, restore, rollback) is one JSON line: which flags changed (`changes`: from → to), the version and the one it replaced, who, and which commit. The line is printed and kept in `~/.local/state/pronto-flags/<app>.jsonl`, or wherever `PRONTO_FLAGS_JOURNAL` points. `history --json` gives the same facts per version.
  - **Target guard.** Every write prints its target first. `--expect <url>` or `PRONTO_FLAGS_EXPECT` refuses any other target, and `PRONTO_FLAGS_DRY_RUN` writes nothing. Earlier that day a "dry run" wrote Bonk Chess's production flags; this guard is the answer to that.
  - **Local store.** `flagsLive: {dir}` keeps a versioned store in a directory, with the same generations and preconditions as the bucket. A drill or a local stack can then flip and roll back without any cloud.
- [examples/hello-flags-drill](../examples/hello-flags-drill/README.md) is the stand-in for the app:
  - a shop with three steps: `/`, `/cart`, `/checkout`;
  - a flag, `drill_break_checkout`, that makes checkout answer 500;
  - a probe, `checkout`, that runs every 5 s and alerts at the second failure;
  - flagd, which reads the local store's `flags.json`.

No production or staging flag was written. Every write named its target with `--expect file://…/examples/hello-flags-drill/.flags-live/flags.json`.

## Timeline (BRT, 2026-11-07)

This is the first run, driven by hand: one terminal ran the probe, and the responder worked from the alert.

| time | what |
|---|---|
| 09:48:25 | `pronto-flags setup`: the local store's first version, `1794055705751804`, with the flag off. flagd, the shop and the probe are started. |
| 09:48:49, 09:48:54 | probe `checkout` green |
| **09:48:54** | **Flip.** `pronto-flags push … --untested "drill: the bad flip the probe must catch"` writes version `1794055734223961`. The journal line reads `"flag":"drill_break_checkout","changes":[{"from":false,"to":true}]`, by brunomaciel@gmail.com, commit `5010589+edits`. flagd logs a file WRITE within half a second. |
| **09:48:59** | **First failure.** `checkout` fails with 500 at step `checkout`. The shop's log has `"drill_break_checkout":true` on that request. |
| **09:49:04** | **Alert.** The probe raises it at the second failure. Its one suspect is `2026-11-07T12:48:54Z drill_break_checkout v1794055734223961 by brunomaciel@gmail.com`, with `undo: pronto-flags rollback …/hello-flags-drill 1794055705751804`. |
| 09:49:05–09:49:15 | **Diagnosis.** The responder confirmed the culprit three ways before acting. (1) `pronto-flags history --json`: the live version is the push of 09:48:54, which changed `drill_break_checkout` from false to true and was untested. (2) flagd's log: the store's file changed at 09:48:54.745. (3) The shop's log: the last 200 read the flag false (09:48:34), and every 500 from 09:48:59 on read it true. Nothing else changed in the window. |
| **09:49:20** | **Rollback.** `pronto-flags rollback … 1794055705751804 --expect …` writes version `1794055760264333`. Its journal line has `"stage":"rollback","note":"rolled back from 1794055734223961 to 1794055705751804"` and `changes` true → false. |
| **09:49:24** | **Recovery.** `checkout` is green again. The probe says `RESOLVED hello-flags-drill/checkout down 25s`. |

Detection took 10 s from the flip, which is the probe's two 5-second runs. The fix took 16 s from the alert, and the journey was down for 25 s in all.

After the reviewer's fixes, `drill.sh` ran the same drill unattended twice: at 09:56:09–09:56:24 and at 09:56:53–09:57:08. Each time the alert named the flip, the rollback went to the version the alert named, and the journey was down for 10 s.

## What the drill found

- The journal's default path (`~/.local/state/…`) crashed on the first real run. The tests had always set `PRONTO_FLAGS_JOURNAL`; both paths are tested now.
- `bin/pronto-probe run` found no `cue` outside mise. It now runs under the repository's pinned deno and tools, as `bin/pronto-flags` does.
- Review fixes, each now covered by a case:
  - A journal that can't be written warns; it never fails a write that already landed.
  - A targeting-only change, such as widening a rollout, names its flag as a suspect.
  - A flip's undo goes back past its own canary to the version before the flip.
  - The webhook has a 5 s timeout, so a stalled hook can't stop the probe.

## Run it again

From a pronto-plugins clone, with flagd installed by mise (the flags plugin's tests use the same one):

```sh
examples/hello-flags-drill/drill.sh
```

It refuses to start if 8013, 8016 or 8787 is already taken. It prints its timeline in BRT, leaves every log in a temporary directory (or `$DRILL_LOGS`), and stops what it started. To drive it by hand as the responder, follow the steps in the [example's README](../examples/hello-flags-drill/README.md).

On a real app, the same three pieces apply:

- `bin/pronto-probe <app>` installs the probe, and the app's journeys go in `probes_spec.cue`.
- `bin/pronto-probe run <app>` watches them.
- Every `pronto-flags push` or `rollback` is journaled. Pass `--expect gs://<bucket>/flags.json` to make each write name the target you meant.

The probe reads the journal on the machine it runs on. A flip pushed from another machine is in `pronto-flags history`, but not in that journal.
