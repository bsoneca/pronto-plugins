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
// main now, null when it could not be read) by a change that concerns what failed (concerns, below):
// the fix may be in, and an hour's wait on top of the failed run's own would leave the app unreleased
// past its period. The same commit waits the gap.
export const retry = (failed, head) => !!failed && !!head && head !== failed;

// The checks a failed rehearsal's summary marks failed: its `  ✗ <check>` lines (integrate@local,
// premium, `scenarios, pass 1: …`), not a scenario's own `✗ <name> (12s) at step`.
export const failedRehearsal = (text) =>
  [...new Set([...(text ?? "").matchAll(/^ {2}✗ ([^:\n(]+?)\s*(?::.*)?$/gm)].map((m) => m[1].trim()))];

// Whether a change since a failed run concerns what its failed checks read, so the next run retries
// without the gap: the first file that does, with why, or null, and the run waits the gap (2026-11-07:
// 17:56 failed integrate@local's visual lint; main moved by tools/metrics and .github alone, and 18:16
// ran the same rehearsal to the same failure 8 minutes later, most of the machine for both). `files`:
// what the change touched, from the repository's top; `app`: the app's folder there; `sig`: the failure
// (signature); `checks`: failedRehearsal's; `sqlHot(file)`: whether a SQL file matters to the failed
// scenarios by what their last green runs touched (tests/scenarios/select.ts's touched and hotSql), null
// when no record says. What the scenario selection (docs/test-selection.md) knows no check reads, none
// does here: documentation, the unit cases, and a file outside the app but the tool pins above it (and,
// for a release, infra/). A runner concerns its own check: tests/premium.ts premium, a scenario's CUE
// the scenarios. Anything else in the app concerns every check (fail open: the served files, which the
// visual lint and the scenarios load, the server, the app's CUE, the rehearsal's runners, release-cron),
// but SQL that no failed scenario touched. A failure whose checks cannot be read concerns everything.
/** @param {(file: string) => boolean | null} sqlHot */
export const concerns = (files, app, sig, checks, sqlHot = () => null) => {
  const all = sig.kind === "release" || !checks.length;
  const scenarios = all || checks.some((c) => c.startsWith("scenarios")) || sig.names.length > 0;
  const premium = all || checks.includes("premium");
  const onlyScenarios = !all && checks.every((c) => c.startsWith("scenarios")) && sig.names.length > 0;
  for (const f of files) {
    if (f !== app && !f.startsWith(`${app}/`)) {
      const dir = f.includes("/") ? f.slice(0, f.lastIndexOf("/")) : "";
      if (/(^|\/)(mise\.lock|\.?mise\.toml)$/.test(f) && (dir === "" || app.startsWith(`${dir}/`))) return { file: f, why: "a tool pin above the app" };
      if (sig.kind === "release" && f.startsWith("infra/")) return { file: f, why: "the cloud's configuration, which a release reads" };
      continue;
    }
    const rel = f.slice(app.length + 1);
    if (/\.md$/.test(rel) || /^journal\//.test(rel) || /^tests\/unit(\/|\.ts$)/.test(rel)) continue;
    if (rel === "tests/premium.ts") { if (premium) return { file: f, why: "premium's runner, and premium failed" }; continue; }
    if (/^tests\/scenarios\/[^/]+\.cue$/.test(rel) && rel !== "tests/scenarios/schema.cue") { if (scenarios) return { file: f, why: "a scenario's steps, and scenarios failed" }; continue; }
    if (rel.endsWith(".sql") && onlyScenarios && sqlHot(f) === false) continue;
    return { file: f, why: rel.endsWith(".sql") ? "SQL a failed scenario may touch" : `read by ${all ? "every check" : checks.join(", ")}` };
  }
  return null;
};

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

// A probe's verdict: null when the answer is what it expects, else what was wrong. A probe with a
// `location` is asked without following its redirect, and answers one to an address that starts so.
/** @param {string | null} [location] */
export const probe = (spec, status, body, location = null) => {
  if (status !== (spec.status ?? 200)) return `${spec.path}: ${status}, expected ${spec.status ?? 200}`;
  if (spec.location && !(location ?? "").startsWith(spec.location)) return `${spec.path}: to ${location ?? "nowhere"}, expected ${spec.location}`;
  const missing = (spec.has ?? []).filter((h) => !body.includes(h));
  return missing.length ? `${spec.path}: ${status} without ${missing.map((m) => JSON.stringify(m)).join(", ")}` : null;
};

// The probes the release preview (releaseCron.target.preview) is asked: every one but those that say `preview: false`
// (a probe of a row only production holds, say). Name and spec, in the probes' order.
export const previewProbes = (probes) => Object.entries(probes).filter(([, p]) => p.preview !== false);

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

// The systemd user units of the same job (~/.config/systemd/user/<label>.service and .timer), the Linux
// scheduler's: the service runs `program` with `args` once and its output is appended to `log`, with the
// variables in `env`; the timer starts it `poll` minutes after the last start (OnUnitActiveSec; systemd never
// starts a service while it runs) and once a minute after boot, so a run follows a restart.
export const systemdUnits = ({ label, program, args, poll, log, env }) => {
  // A word of a unit file in double quotes: \ and " escaped, and % and $ doubled (specifiers, variables).
  const q = (s) => `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/%/g, "%%").replace(/\$/g, "$$$$")}"`;
  const service = `[Unit]
Description=release-cron ${label}

[Service]
Type=oneshot
ExecStart=${[program, ...args].map(q).join(" ")}
${Object.entries(env).map(([k, v]) => `Environment=${q(`${k}=${v}`)}\n`).join("")}StandardOutput=append:${log}
StandardError=append:${log}
`;
  const timer = `[Unit]
Description=release-cron ${label}, every ${poll} min

[Timer]
OnBootSec=1min
OnUnitActiveSec=${poll}min
Unit=${label}.service

[Install]
WantedBy=timers.target
`;
  return { service, timer };
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

// Whether a failed run's failure is one a bisect cannot decide, whatever it names: a failure that
// depends on a flag (the scenario's `flags`), on time (a scenario marked `slow`, the menu budget) or on
// the machine's load says nothing about the commit it ran on. On 2026-11-06 the bisect blamed #773 for
// #771's flag-off menu path, and a check run while the machine sat at load 185 fails by itself.
// `specs` is [{id, flags, slow}] of the scenarios; `load` the 1-minute load average and `cores` the machine's.
export const undecidable = (sig, text, specs, load, cores, flaked = []) => {
  // A release's failure is the cloud's (its rc preview), so the machine's load now says nothing of it;
  // one whose only failed checks are the menu budget's timing is not the commit's either (2026-11-07
  // 10:11 BRT: "menu time 9327 ms > 6000 ms" on the rc, and its bisect ran a whole local check to say so).
  // Nor is one with nothing a local check can run: no scenario named and no failed check read, or only
  // scenarios the run itself saw flake (they passed on a retry). Of 15 bisects to 2026-11-07, 7 ended "a
  // failure only the cloud shows" after a whole local check on the failing commit; this decides it before.
  if (sig.kind === "release") {
    const checks = failedChecks(text);
    if (checks.length && checks.every((c) => /menu[- ]budget/i.test(c))) return "the menu budget is a timing check, not bisected";
    if (!sig.names.length && !checks.length) return "a release failure that names no scenario and no check: a failure only the cloud shows, not bisected";
    if (sig.names.length && sig.names.every((n) => (flaked ?? []).includes(n))) return `${sig.names.join(", ")} flaked in the run itself: a failure only the cloud shows, not bisected`;
    return null;
  }
  if (load > cores) return `the machine is under load (${load.toFixed(0)} on ${cores} cores): a timing check would fail by itself, not bisected`;
  const dependent = (specs ?? []).filter((x) => sig.names.includes(x.id) && (x.flags || x.slow));
  if (dependent.length) return `${dependent.map((x) => x.id).join(", ")} depend${dependent.length > 1 ? "" : "s"} on ${dependent.some((x) => x.flags) ? "a flag" : "time"} (flags or slow in its CUE), which the commit under test does not decide, not bisected`;
  if (!sig.names.length && /menu[- ]budget/i.test(text ?? "")) return "the menu budget is a timing check, not bisected";
  return null;
};

// A bisect's check in the background: `nice -n 19` under macOS's background QoS (`taskpolicy -b`: the
// lowest CPU, disk and network priority), so a gate or a release always outranks it. Every process the
// check starts inherits both.
export const lowPriority = (argv) => ["taskpolicy", "-b", "nice", "-n", "19", ...argv];

// The checks the last verify line names as failed ("verify: failed: check-menu-budget check-online").
export const failedChecks = (text) => {
  const m = [...(text ?? "").matchAll(/^verify: failed: (.+)$/gm)].at(-1);
  return m ? m[1].trim().split(/\s+/) : [];
};

// Whether a bisect stops before its next check, and why (null: go on). It never holds a release up:
// it yields to a release-cron run that holds the run's lock (`holder`, alive; not the run that started
// it, `starter`, which lets the lock go as it ends), and it is moot once a run after the failed one
// released (`releasedAfter`) or a commit on main after the failed one is green for this failure in the
// records (`fixedBy`, its sha). On 2026-11-07 a bisect of the 11:29 BRT failure held the release runner,
// waiting 11th in line for its check, until it was stopped at 15:12: no release ran from 14:12.
export const stopsBisect = (holder, starter, alive, releasedAfter, fixedBy) =>
  holder > 0 && alive && holder !== starter ? `a release-cron run (${holder}) is going: the bisect yields to it, its verdicts kept`
  : releasedAfter ? `a run since released ${releasedAfter.slice(0, 8)}: nothing to bisect`
  : fixedBy ? `main is green for this failure at ${fixedBy.slice(0, 8)}: fixed, not bisected`
  : null;

// The first of `commits` (main after the failed commit, oldest first) the records find good for this
// failure; null when none.
export const fixedBy = (commits, sig, ev) => commits.find((c) => verdict(c, sig, ev) === "good") ?? null;

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

// A hook of releaseCron.hooks as the command run: its own argv, then the run's worktree, the app and the commit
// released (the dev flow's `released` hook, devflow/hook.ts, takes exactly those). The hooks of one event, in order.
export const hookArgv = (hook, wt, app, commit) => [...hook.command, wt, app, commit];
export const hooksOf = (hooks, on) => (hooks ?? []).filter((h) => h.on === on);

// Who a finding reaches, by the app's `notify`: the log always when nobody else is (`none`); `github-comment` the pull
// request's comment; `claude-session` that, a notes file in a session's folder and, on a Mac (`platform`, Deno.build.os),
// a notification.
export const channels = (notify, platform) =>
  notify.kind === "claude-session" ? ["comment", "notes", ...(platform === "darwin" ? ["toast"] : [])]
  : notify.kind === "github-comment" ? ["comment"]
  : ["log"];

// The releaseCron the driver reads, whole: what the schema (release_cron_plugin.cue) normalizes, and what a configuration
// exported by an older schema lacks filled in the same way: no target is Cloud Run's, a target without a kind is a
// command's, the rehearsal runs verify@local in a slot of `holder`, a `bisect.lead` is a claude-session notify, nobody
// is told otherwise, no hooks, launchd. A configuration the schema normalized is returned as it is.
export const resolve = (c) => ({
  ...c,
  scheduler: c.scheduler ?? { kind: "launchd" },
  target: c.target ? { kind: "command", ...c.target } : { kind: "cloud-run" },
  rehearsal: { command: ["./saytw", "verify@local"], slot: true, holder: c.holder ?? "verify@local", ...(c.rehearsal ?? {}) },
  notify: c.notify ?? (c.bisect?.lead
    ? { kind: "claude-session", lead: c.bisect.lead, notes: c.bisect.notes ?? "Library/Application Support/Claude/side-session-notes" }
    : { kind: "none" }),
  hooks: c.hooks ?? [],
});

// The hook reads the repository's devflow.cue with `cue` (pronto-plugins' devflow/spec.ts: $CUE, else PATH's),
// and launchd's PATH has no mise, so every run's board step failed "Failed to spawn 'cue'" (PRONTO-77,
// 2026-11-08 21:18 BRT). It is handed mise's newest cue, as .github/workflows/plane.yml hands its own; a CUE
// already set is kept, and with no cue installed the environment is unchanged.
export const boardEnv = (env, home, cues) => {
  if (env.CUE) return env;
  const n = (s) => s.split(".").map(Number);
  const v = cues.filter((c) => /^\d+\.\d+\.\d+$/.test(c)).sort((a, b) => {
    const [x, y] = [n(a), n(b)];
    return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
  }).pop();
  return v ? { ...env, CUE: `${home}/.local/share/mise/installs/github-cue-lang-cue/${v}/cue` } : env;
};
