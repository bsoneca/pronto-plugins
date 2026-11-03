// release-cron's rules, apart from what they act on (release-cron.ts runs git, the rehearsal, the
// release and curl): whether a run is due, whether a change is the app's, which commit is serving,
// when the rehearsal got its slot, what a probe's answer means, where a run's time went,
// the run's log line and the launchd job. Pure, so the cases (tests/unit/*.cue) hold them.

// Whether a wake starts a run: the gap (minutes) is over since the last run that released or
// failed, `last` its end (ms since the epoch, or null when none has). Skipped runs leave no gap:
// a new merge is not held back.
export const due = (now, last, gap) => last === null || now >= last + gap * 60_000;

// The outcomes after which the next run waits the gap.
export const spaced = (outcome) => outcome === "released" || outcome === "failed";

// A failed run's gap is waived once main has moved past the commit it failed on (`failed`; `head`
// main now, null when it could not be read): the fix may be in, and an hour's wait on top of the
// failed run's own would leave the app unreleased past its period. The same commit waits the gap.
export const retry = (failed, head) => !!failed && !!head && head !== failed;

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
  return `${run.started} ${run.app} ${run.outcome}${what ? ` ${what}` : ""}${run.why ? ` (${run.why})` : ""}: ${min(total)} min${steps ? ` = ${steps}` : ""}`;
};

// Where a run's time went inside its steps, from the records the rehearsal and the release write
// for the run's commit (~/.cache/pronto/rehearsals/<app>.jsonl, ~/.cache/pronto/releases/<name>.jsonl):
// seconds by phase, flat, the rehearsal's prefixed "rehearse.", the release's "release.". The
// newest record of the commit that started after `since` (ISO) counts; a phase not run is left out.
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
  return { phases: out, flaked, rc: g?.rc ?? null };
};

// The released runs side by side, the newest last: each one's total and steps in minutes, then for
// the newest, every phase against the median of those before it, the slowest first, so the next
// change goes where the time is.
export const report = (runs) => {
  const min = (s) => (Math.round(s / 6) / 10).toFixed(1);
  const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length ? (s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null; };
  const released = runs.filter((r) => r.outcome === "released");
  if (!released.length) return "no released run yet";
  const total = (r) => Object.values(r.steps).reduce((a, b) => a + b, 0);
  const rows = released.map((r) => `${r.started} ${r.commit?.slice(0, 8) ?? ""} ${min(total(r))} min = ${Object.entries(r.steps).map(([k, s]) => `${k} ${min(s)}`).join(", ")}`);
  const last = released.at(-1), before = released.slice(0, -1);
  const phases = Object.entries(last.detail?.phases ?? {}).sort((a, b) => b[1] - a[1]).map(([k, s]) => {
    const m = median(before.map((r) => r.detail?.phases?.[k]).filter((x) => typeof x === "number"));
    return `  ${k} ${min(s)} min${m === null ? "" : ` (median before ${min(m)}, ${s - m >= 0 ? "+" : ""}${min(s - m)})`}`;
  });
  const m = median(before.map(total));
  return [...rows, `newest: ${min(total(last))} min${m === null ? "" : `, median before ${min(m)}`}; its phases, slowest first:`, ...phases,
    ...(last.detail?.flaked?.length ? [`  flaked, passed on retry: ${last.detail.flaked.join(", ")}`] : [])].join("\n");
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
