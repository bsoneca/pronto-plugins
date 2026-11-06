// release-cron's rules, apart from what they act on (release-cron.ts runs git, the rehearsal, the
// release and curl): whether a run is due, whether a change is the app's, which commit is serving,
// when the rehearsal got its slot, what a probe's answer means, where a run's time went,
// the run's log line and the launchd job. Pure, so the cases (tests/unit/*.cue) hold them.

// Whether a wake starts a run: the gap (minutes) is over since the last run that released or
// failed, `last` its end (ms since the epoch, or null when none has). Skipped runs leave no gap:
// a new merge is not held back.
export const due = (now, last, gap) => last === null || now >= last + gap * 60_000;

// A time a person reads (the run's log line, its log's name, the pause file), in the operator's
// zone with its offset, to the second: 2026-11-03T17:28:12-03:00. `ms` is since the epoch. What the
// code compares with other tools' records (detail's `since`) stays in UTC.
export const zone = "America/Sao_Paulo";
export const local = (ms, tz = zone) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(ms).map((x) => [x.type, x.value]));
  const off = Math.round((Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - Math.floor(ms / 1000) * 1000) / 60_000);
  const a = Math.abs(off), pad = (n) => String(n).padStart(2, "0");
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}${off < 0 ? "-" : "+"}${pad(Math.floor(a / 60))}:${pad(a % 60)}`;
};

// The release-active file's line: the app, the run's pid, when it started and its phase (slot,
// rehearse, release or confirm). One line of JSON, written whole and renamed into place.
export const activeLine = (app, pid, started, phase) => JSON.stringify({ app, pid, started, phase }) + "\n";

// The outcomes after which the next run waits the gap.
export const spaced = (outcome) => outcome === "released" || outcome === "failed";

// A failed run's gap is waived once main has moved past the commit it failed on (`failed`; `head`
// main now, null when it could not be read): the fix may be in, and an hour's wait on top of the
// failed run's own would leave the app unreleased past its period. The same commit waits the gap.
export const retry = (failed, head) => !!failed && !!head && head !== failed;

// Whether a run's commit `ref` is a strict ancestor of `last`, the commit the last run (released or
// failed) tried (`isAncestor`: git merge-base --is-ancestor ref last): the run skips, for a ref
// older than that would meet again what main has since fixed. The same commit is not behind.
export const behind = (isAncestor, ref, last) => !!isAncestor && !!last && ref !== last;

// The files of a diff (`git diff --name-only`) under the watched paths: a path is watched when it
// is one of them or lies beneath one.
export const changed = (files, watch) =>
  files.filter((f) => watch.some((w) => { const d = w.replace(/\/+$/, ""); return f === d || f.startsWith(`${d}/`); }));

// The commit serving: the newest live production release record (pronto's release records,
// ~/.cache/pronto/releases/<name>.jsonl) whose revision is the one taking all the traffic. null
// when no record names it (released from another machine) or it was released from a dirty tree:
// then the run cannot tell, and releases.
export const serving = (records, revision) => {
  const live = records.filter((r) => r.outcome === "live" && (r.preview ?? "") === "" && r.revision === revision);
  // A release from a dirty tree served more than its commit: what serves is not known.
  return live.length && !live.at(-1).dirty ? live.at(-1).commit : null;
};

// The revision taking every request, from `gcloud run services describe --format=json`'s
// status.traffic; null while traffic is split.
export const whole = (traffic) => {
  const all = (traffic ?? []).filter((t) => (t.percent ?? 0) === 100);
  return all.length ? all[0].revisionName ?? null : null;
};

// The commit a run compares main with: that of the newest run that released (runs.jsonl), while
// the revision it confirmed still takes every request (`now`); else null, and the run releases. A
// failed run is never the base, though its release record may say live: a change whose deploy or
// confirm failed is released again, not skipped from then on. A revision that changed since (a
// rollback, a release from elsewhere) is not known to serve it either.
export const base = (runs, now) => {
  const r = runs.filter((x) => x.outcome === "released").at(-1);
  return r && now && r.revision === now ? r.commit ?? null : null;
};

// What is wrong with production after a release of `head`: the revision taking every request
// (`now`, null while traffic is split) must be the one the newest live record of `head` names. A
// release that changes nothing Cloud Run runs (a test, a doc) makes no new revision: its record
// names the revision already serving, which then serves `head` as much as a new one would.
export const served = (now, records, head) => {
  if (!now) return ["traffic split: no revision takes every request"];
  return serving(records, now) === head ? [] : [`${now} takes every request, but no live record of ${head.slice(0, 8)} names it`];
};

// Whether a slot's owner line (tests/slot.ts writes "<pid> <ISO> <app dir> <what> (weight <w>)" to
// <pool>/slot-<n>/owner) is the rehearsal of the app at `dir`: its main slot (`what`, the app's `holder`), not a lane. A slot's
// owner is how the run learns the rehearsal got its slot, since ./saytw keeps its output to itself.
export const holds = (owner, dir, what = "verify@local") => {
  const m = owner.trim().match(/^\d+ \S+ (\S+) (.*) \(weight \d+\)$/);
  return !!m && m[1].replace(/\/+$/, "") === dir.replace(/\/+$/, "") && m[2] === what;
};

// A probe's verdict: null when the answer is what it expects, else what was wrong.
export const probe = (spec, status, body) => {
  if (status !== (spec.status ?? 200)) return `${spec.path}: ${status}, expected ${spec.status ?? 200}`;
  const missing = (spec.has ?? []).filter((h) => !body.includes(h));
  return missing.length ? `${spec.path}: ${status} without ${missing.map((m) => JSON.stringify(m)).join(", ")}` : null;
};

// The run's log line: when, the app, the outcome, the commit, then each step's minutes, one decimal,
// in the order run, and the total. `steps` holds the steps that ran, in seconds.
export const line = (run) => {
  const min = (s) => (Math.round(s / 6) / 10).toFixed(1);
  const total = Object.values(run.steps).reduce((a, b) => a + b, 0);
  const steps = Object.entries(run.steps).map(([k, s]) => `${k} ${min(s)}`).join(", ");
  const what = [run.commit?.slice(0, 8), run.revision].filter(Boolean).join(" ");
  const cloud = run.rehearsal ? `; cloud rehearsal ${min(run.rehearsal.seconds)} min, $${run.rehearsal.usd.toFixed(4)}` : "";
  return `${run.started} ${run.app} ${run.outcome}${run.newFailing?.length ? `; new-feature scenarios failing: ${run.newFailing.join(", ")}` : ""}${run.flaked?.length ? `; flaked: ${run.flaked.join(", ")}` : ""}${what ? ` ${what}` : ""}${run.why ? ` (${run.why})` : ""}: ${min(total)} min${steps ? ` = ${steps}` : ""}${cloud}`;
};

// Where a run's time went inside its steps, from the records the rehearsal and the release write
// for the run's commit (~/.cache/pronto/rehearsals/<app>.jsonl, ~/.cache/pronto/releases/<name>.jsonl):
// seconds by phase, flat, the rehearsal's prefixed "rehearse.", the release's "release.". The
// newest record of the commit that started after `since` (ISO) counts; a phase not run is left out.
// A release with a cloud rehearsal (GCP.rehearsal) carries it in its record: ok, seconds and usd.
export const detail = (rehearsals, releases, commit, since) => {
  const newest = (rs, at) => rs.filter((r) => r.commit === commit && (r[at] ?? "") >= since).at(-1);
  const out = {};
  const r = newest(rehearsals, "queued");
  if (r) {
    out["rehearse.queue"] = r.waited;
    for (const [k, c] of Object.entries(r.checks ?? {})) if (!c.cached) out[`rehearse.${k}`] = c.s;
  }
  const g = newest(releases, "started");
  if (g) for (const [k, v] of Object.entries(g.phases ?? {})) if (typeof v === "number" && k !== "total") out[`release.${k}`] = Math.round(v);
  const flaked = Object.entries(r?.checks ?? {}).flatMap(([k, c]) => (c.flaked ?? []).map((f) => `${f} (${k})`));
  return { phases: out, flaked, rc: g?.rc ?? null, ...(g?.rehearsal ? { rehearsal: g.rehearsal } : {}) };
};

// The released runs side by side, the newest last: each one's total and steps in minutes, then for
// the newest, every phase against the median of those before it, the slowest first, so the next
// change goes where the time is.
export const perDay = 16;
export const report = (runs) => {
  const min = (s) => (Math.round(s / 6) / 10).toFixed(1);
  const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length ? (s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null; };
  const released = runs.filter((r) => r.outcome === "released");
  // The bisects of failed runs (runs.jsonl lines of their own), after the releases.
  const bisected = runs.filter((r) => r.outcome === "bisect" && r.detail?.bisect).map((r) => `bisect ${bisectLine(r.detail.bisect)}`);
  if (!released.length) return ["no released run yet", ...bisected].join("\n");
  const total = (r) => Object.values(r.steps).reduce((a, b) => a + b, 0);
  const rows = released.map((r) => `${r.started} ${r.commit?.slice(0, 8) ?? ""} ${min(total(r))} min = ${Object.entries(r.steps).map(([k, s]) => `${k} ${min(s)}`).join(", ")}${r.newFailing?.length ? `; new-feature scenarios failing: ${r.newFailing.join(", ")}` : ""}`);
  const last = released.at(-1), before = released.slice(0, -1);
  const phases = Object.entries(last.detail?.phases ?? {}).sort((a, b) => b[1] - a[1]).map(([k, s]) => {
    const m = median(before.map((r) => r.detail?.phases?.[k]).filter((x) => typeof x === "number"));
    return `  ${k} ${min(s)} min${m === null ? "" : ` (median before ${min(m)}, ${s - m >= 0 ? "+" : ""}${min(s - m)})`}`;
  });
  const m = median(before.map(total));
  // The cloud rehearsal's cost: every run that ran one, failed too, since each was paid for.
  const paid = runs.map((r) => r.detail?.rehearsal ?? r.rehearsal).filter((x) => x && typeof x.usd === "number");
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const cost = paid.length ? [`cloud rehearsal: ${paid.length} runs, mean ${min(mean(paid.map((x) => x.seconds)))} min and $${mean(paid.map((x) => x.usd)).toFixed(4)}, $${paid.reduce((a, x) => a + x.usd, 0).toFixed(2)} in all; at ${perDay} a day, $${(mean(paid.map((x) => x.usd)) * perDay * 30).toFixed(2)} a month`] : [];
  return [...rows, `newest: ${min(total(last))} min${m === null ? "" : `, median before ${min(m)}`}; its phases, slowest first:`, ...phases,
    ...(last.detail?.flaked?.length ? [`  flaked, passed on retry: ${last.detail.flaked.join(", ")}`] : []), ...cost, ...bisected].join("\n");
};

// The launchd job (a LaunchAgent's plist): `program` with `args`, every `poll` minutes (launchd
// never starts it while it runs, and after a sleep runs it once), its output appended to `log`,
// with PATH and the variables in `env`.
export const plist = ({ label, program, args, poll, log, env }) => {
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const str = (s) => `<string>${esc(s)}</string>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>${str(label)}
	<key>ProgramArguments</key>
	<array>${[program, ...args].map(str).join("")}</array>
	<key>StartInterval</key><integer>${poll * 60}</integer>
	<key>EnvironmentVariables</key>
	<dict>${Object.entries(env).map(([k, v]) => `<key>${esc(k)}</key>${str(v)}`).join("")}</dict>
	<key>StandardOutPath</key>${str(log)}
	<key>StandardErrorPath</key>${str(log)}
	<key>ProcessType</key><string>Standard</string>
</dict>
</plist>
`;
};

// --- Bisect: a failed run names the commit that broke it. ---

// What a failed run failed on, from its `why` and its output: the kind ("release" when release@gcp,
// a target's release command (`release (cmd)`) or the confirm failed, else "rehearsal") and the scenarios the output marks failed (`✗ <name> (12s) at step`).
export const signature = (why, text) => ({
  kind: /^release@gcp|^release \(|^released, production/.test(why ?? "") ? "release" : "rehearsal",
  names: [...new Set([...(text ?? "").matchAll(/✗ (\S+) \(\d+s\) at step/g)].map((m) => m[1]))],
});

// The merges of `git log --first-parent --format='%H %s'` lines, oldest first, each with its pull
// request and branch when the subject is a GitHub merge ("Merge pull request #1 from o/b"); other
// commits (squashes, direct pushes) have pr null.
export const merges = (lines) => lines.filter(Boolean).map((l) => {
  const [sha, ...s] = l.split(" "), subject = s.join(" "), m = subject.match(/^Merge pull request #(\d+) from [^/\s]+\/(\S+)/);
  return { sha, subject, pr: m ? Number(m[1]) : null, branch: m ? m[2] : null };
}).reverse();

// What the records already say of `commit` for this failure: "good", "bad" or "unknown". A release
// failure reads the release records (pronto's, per name): live is good, a failed rc test run is bad.
// A rehearsal failure reads the rehearsal records (passed good, failed bad). The records do not name the scenarios that failed, so a failure counts as bad only when the failed run named none. A dirty tree proves
// nothing. `ledger` holds the verdicts earlier bisects ran themselves ({commit, kind, names, verdict, at});
// the newest evidence counts.
export const verdict = (commit, sig, ev) => {
  const rehearsals = ev.rehearsals ?? [], releases = ev.releases ?? [], ledger = ev.ledger ?? [];
  const from = sig.kind === "release"
    ? releases.filter((r) => r.commit === commit && !r.dirty).map((r) => [r.started, r.outcome === "live" ? "good" : r.outcome === "failed" && !sig.names.length && /^the tests failed against/.test(r.failure ?? "") ? "bad" : "unknown"])
    : rehearsals.filter((r) => r.commit === commit && !r.dirty).map((r) => [r.queued, r.outcome === "passed" ? "good" : r.outcome === "failed" && !sig.names.length ? "bad" : "unknown"]);
  const own = ledger.filter((r) => r.commit === commit && r.kind === sig.kind && (r.names ?? []).join(",") === (sig.names ?? []).join(",")).map((r) => [r.at, r.verdict]);
  const seen = [...from, ...own].filter(([, v]) => v !== "unknown").sort((a, b) => String(a[0]).localeCompare(String(b[0])));
  return seen.length ? seen.at(-1)[1] : "unknown";
};

// The next step of the search over `commits` (oldest first; the commit before them is good, the
// last is bad), given each one's verdict (`known`: sha -> good|bad|unknown). Done: the first bad
// commit after the last good one before it, when they are adjacent; else the commit in the middle
// of those whose verdict is unknown; `range` when none is left to test.
export const next = (commits, known) => {
  const v = (i) => known[commits[i].sha] ?? "unknown";
  let bad = commits.findIndex((_, i) => v(i) === "bad");
  if (bad < 0) bad = commits.length - 1;
  let good = -1;
  for (let i = 0; i < bad; i++) if (v(i) === "good") good = i;
  if (good + 1 === bad) return { culprit: commits[bad] };
  const open = [];
  for (let i = good + 1; i < bad; i++) if (v(i) === "unknown") open.push(i);
  if (!open.length) return { range: commits.slice(good + 1, bad + 1) };
  return { test: commits[open[Math.floor((open.length - 1) / 2)]] };
};

// Whether a bisect may name a commit, from the failing commit's own check: "bad" reproduced the run's
// failure, and the search goes on; anything else did not, and the why says so. A release failure the
// check passes showed only in the cloud (the rc preview). A rehearsal failure the check passes came
// from the run's conditions, not its tree: on 2026-11-06 every flagd on the machine was killed from
// outside mid-rehearsal, and the bisect, assuming the failing commit bad, blamed the last PR merged.
export const unreproduced = (kind, v) => v === "bad" ? null :
  `the check ${v === "good" ? "passes" : "did not finish"} here on the failing commit: ${kind === "release" ? "a failure only the cloud shows" : "a failure of the run's conditions (a service stopped from outside, the machine), not of a commit"}, not bisected`;

// The author session a pull request names in its body: a Claude Desktop session id (local_<uuid>).
export const sessionOf = (body) => (body ?? "").match(/local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?.[0] ?? null;

// The bisect's one line, for the run's detail and `report`.
export const bisectLine = (b) =>
  `${b.of}: ${b.culprit ? `culprit ${b.culprit.slice(0, 8)}${b.pr ? ` (PR #${b.pr}, ${b.branch})` : ""}` : b.range ? `narrowed to ${b.range.map((s) => s.slice(0, 8)).join(" ")}` : b.why ?? "undecided"}; checks run ${b.ran ?? 0}, from records ${b.fromRecords ?? 0}${b.notified ? `; told ${b.notified}` : ""}`;

// --- New-feature scenarios: pronto's gcp release ships when only they fail. ---

// The scenarios a release's output line names: `released on stable features; new-feature scenarios
// failed: a, b (absent from <commit8>, live release)`, or the same rule's older line (gcp.85-87)
// `new-feature scenarios failed, released anyway: a, b (absent from ...)`; none for any other text.
export const newFeatureNames = (text) => {
  const m = (text ?? "").match(/(?:released on stable features; new-feature scenarios failed|new-feature scenarios failed, released anyway): (.+?)(?: \(absent from|$)/m);
  return m ? [...new Set(m[1].split(",").map((x) => x.trim()).filter(Boolean))] : [];
};

// The merge that added a scenario: the first of `list` (merges(), oldest first, since the last released
// run) whose tree has its file (`has`: sha -> bool); none when the last released run's tree already had it.
export const introducedBy = (list, has, hadBefore) => hadBefore ? null : list.find((c) => has[c.sha]) ?? null;

// The {scenario, pr} found that the ledger of those told does not hold yet: each is told once.
export const untold = (found, told) => found.filter((f) => !told.some((t) => t.scenario === f.scenario && t.pr === f.pr));

// The scenarios the rehearsal's output names as flaked: `(flaked, passed on its one retry: a, b)` in its
// per-check line, or `⚠ flaked, passed on its one retry: a, b (scenarios)` in its summary; and release@gcp's cloud
// tests' `⚠ online flaked, passed on its one retry`, one name per line; none for other text.
export const flakedNames = (text) => {
  const t = text ?? "";
  const names = [...t.matchAll(/flaked, passed on its one retry: ([^()\n]+)/g)].flatMap((m) => m[1].split(",").map((x) => x.trim()).filter(Boolean));
  const cloud = [...t.matchAll(/^\s*⚠ (\S+) flaked, passed on its one retry\s*$/gm)].map((m) => m[1]);
  return [...new Set([...names, ...cloud])];
};

// The merge that last changed a scenario's file: the newest of `list` (merges(), oldest first) whose diff
// touched it (`touched`: sha -> bool); none when no merge of the list did.
export const changedBy = (list, touched) => [...list].reverse().find((c) => touched[c.sha]) ?? null;
