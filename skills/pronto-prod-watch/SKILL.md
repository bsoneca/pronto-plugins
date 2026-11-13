---
name: pronto-prod-watch
description: "Watch a pronto app's production logs for bugs and fix them on a loop: run prod-watch from the app's folder each pass, mark each new, regressed or rising fingerprint as noise with a reason or fix it in a pull request, confirm after the release that it stopped, and take the loudest noise rule out at its source. Use when the user wants an app's production watched, or to triage what production logged."
---

# pronto-prod-watch

The loop that runs [prod-watch](../../prod-watch/README.md) on an app. `<app>` is the app's folder
name under `apps/`. Turn it on first: `bin/pronto-prod-watch apps/<app>` from a pronto-plugins clone.

Run it self-paced with /loop, about 30 minutes when idle. Each pass:

1. From `apps/<app>`, run `deno run -A prod-watch/prod-watch.ts <app>`. Read the header's
   `released`: `release-cron` or `by hand`. An app on the node (release@k8s) also has `node` in the
   header, with its pod count and, from release-cron's log, its last release (commit and time in BRT).
2. For each **new**, **regressed** or **rising** fingerprint, decide:
   - Not a bug: `mark <fp> noise --reason "<why>"`. A line that will recur gets a rule (`prodWatch.noise`
     in `prod_watch.cue`, with a case proving it) instead of a mark.
   - A bug: reproduce it as a test case (tests are data: a case in the app's `tests/unit/*.cue`), in
     its own worktree and branch, run the app's AGENTS.md gate, open the PR and merge it yourself.
     Then `mark <fp> watching --pr N`.
3. Releasing: when `released` is `release-cron`, never release; release-cron does, and you wait until
   the report's revision changes (on the node: the header's release commit and time change, and a
   fingerprint's revisions are the pods' new ReplicaSet hashes). Otherwise follow the app's own release rule.
4. After the release (the revision changed; on the node, the header's release time), confirm the fingerprint
   stopped (its `last` is before that time, or the new revision never has it), then
   `mark <fp> fixed --pr N`. If it is still there, it is regressed: fix it again.
5. After the bugs, take the loudest noise rule and remove it at its source: fix what emits the line.
   Delete the rule once its fix is live and it matched nothing for a day.
6. Append one line to `.omc/prod-watch/<app>/log.md` with the time in BRT (America/Sao_Paulo), like
   `12:31 BRT pass 86: 2 new, 1 fixed, 4 watching`.

Never paste secrets, emails or player names into a PR. Samples are redacted; quote only what the
PR needs.
