import { causes, outcomes } from "./causes.js"; // releaseCron.causes and .outcomes, emitted from release-cron/schema.cue (host.cue)

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
// rehearse, android, preview, release or confirm). One line of JSON, written whole and renamed into place.
export const activeLine = (app, pid, started, phase) => JSON.stringify({ app, pid, started, phase }) + "\n";

// ssh exits 255 for its own failure (a dropped connection, a connect that timed out), or when the remote command exits
// 255; either way, what the node serves decides (landed)
// (PRONTO-758: two such drops on 2026-11-18, 07:05 and 11:34 BRT, the path to the node losing packets for minutes).
export const sshDropped = (code) => code === 255;
// A release whose ssh dropped has landed when the node serves the commit it was releasing (`serving`, read after the
// drop): the release ran to its end on the node, its update-ref too, and only the session died. That holds only when
// `serving` reads what is written after the release finished (`afterRelease`, the target's servingAfterRelease); a
// worktree's HEAD moves before the release runs, so for it a 255 stays a failure (PRONTO-870).
export const landed = (code, serving, head, afterRelease) => afterRelease === true && sshDropped(code) && !!serving && !!head && serving === head;
// Whether a 255 is worth reading `serving` for at all.
export const rescuable = (code, afterRelease) => afterRelease === true && sshDropped(code);

// The outcomes after which the next run waits the gap.
export const spaced = (outcome) => outcome === outcomes.released || outcome === outcomes.failed;

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
  const r = runs.filter((x) => x.outcome === outcomes.released).at(-1);
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
    for (const [k, c] of Object.entries(r.checks ?? {})) if (!c.cached && !c.skipped) out[`rehearse.${k}`] = c.s;
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
  const released = runs.filter((r) => r.outcome === outcomes.released);
  // The bisects of failed runs (runs.jsonl lines of their own), after the releases.
  const bisected = runs.filter((r) => r.outcome === outcomes.bisect && r.detail?.bisect).map((r) => `bisect ${bisectLine(r.detail.bisect)}`);
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

// --- The android step: the phone's scenarios on an emulator, on a Mac, after the rehearsal. ---

// Whether the android step runs: declared (releaseCron.android) and on a Mac (`os` is Deno.build.os).
export const androidRuns = (android, os) => !!android && os === "darwin";

// What the log says where a declared android step cannot run, or null when it runs or none is declared.
export const androidSkip = (android, os) => !android || androidRuns(android, os) ? null
  : `android: skipped, release-cron runs on ${os} and the emulator needs a Mac; the release goes on without the phone's scenarios`;

// The environment the android step runs in: PATH, HOME and the rest of a shell's basics, plus what ./saytw integrate@android
// demonstrably reads (the Android SDK and Java, gradle, mise, sayt, the slot pool's STACK_*, the scenarios' PRONTO_*, SLOW, SHOTS, ADB).
// Nothing else passes, so GH_TOKEN, the Google credentials and a Cloudflare token never reach it. A name matching a secret's
// is dropped even where its prefix is let through. Used with clearEnv: the parent's env is not inherited.
const ANDROID_ENV = new Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "TMPDIR", "TZ", "JAVA_HOME", "SLOW", "SHOTS", "ADB", "SDKMAN_DIR", "NO_COLOR", "CI", "GOMAXPROCS", "INTEGRATE_LOCAL_DRIVERS", "PRONTO_ANDROID_BUILD", "PRONTO_BASE", "PRONTO_ANDROID_EMULATOR", "PRONTO_ANDROID_PIN", "MISE_TRUSTED_CONFIG_PATHS"]);
const ANDROID_ENV_PREFIXES = ["ANDROID_", "STACK_", "LC_", "XDG_", "CUE_"];
// A name that says it is a secret, or a value that carries a password in a URL (user:pass@host), never passes, whichever list let it in.
const SECRET_NAME = /TOKEN|SECRET|PASS(WORD|PHRASE)?|PWD|CREDENTIAL|AUTH|KEY|_SK$|_DSN$/i;
const SECRET_VALUE = /:\/\/[^/@\s]+:[^/@\s]+@/;
export const androidEnv = (env) => Object.fromEntries(Object.entries(env).filter(([k, v]) =>
  (ANDROID_ENV.has(k) || ANDROID_ENV_PREFIXES.some((p) => k.startsWith(p))) && !SECRET_NAME.test(k) && !SECRET_VALUE.test(v)));

// How the android step is spawned: the allowlisted env (plus the slot wait) and no inheritance of the parent's.
export const androidSpawn = (env) => ({ env: { ...androidEnv(env), STACK_WAIT_MINUTES: "525600" }, clearEnv: true });

// The scenarios the step's output marks failed: scenarios.ts prints `FAIL  <name>  <seconds> s  <why>`.
export const androidFailed = (text) => [...new Set([...(text ?? "").matchAll(/^FAIL {2}(\S+) {2}/gm)].map((m) => m[1]))];

// Why a failed android step ended the run: the exit and the scenarios named, led by releaseCron.causes.androidFailed (the cause key
// `androidFailed` is written on the run; an older record is read by that phrase, `signature`).
export const androidWhy = (code, names) => `${causes.androidFailed} (exit ${code}): ${names.length ? `${names.join(", ")}: ` : ""}nothing released`;


// --- Bisect: a failed run names the commit that broke it. ---

// A rehearsal that ended without judging the tree: exit 3 (a verdict or record it could not read or write), 124 (its wrapper's
// timeout) or 128 and above (a signal, the machine's doing). Such a run is never bisected.
export const noVerdictExit = (code) => code === 3 || code === 124 || code >= 128;

// Whether a run says its rehearsal gave no verdict, or was stopped because the preview failed first (preview `when: "beside"`):
// the bisect skips it, as it does a run a signal stopped. A record with a `cause` is read by that key; an older one by its `why`.
export const noVerdictRun = (why, cause) =>
  cause ? ["noVerdict", "rehearsalStopped", "signal", "treeMoved"].includes(cause) : (why ?? "").startsWith(causes.noVerdict) || (why ?? "").startsWith(causes.treeMoved) || (why ?? "").includes(`; ${causes.rehearsalStopped}`);

// A run's reason and its cause key, for the failures the driver names itself (releaseCron.causes): `beforeSlot` (the rehearsal
// ended before its slot: `command` its text, `code` its exit, `noVerdict` whether that is no verdict), `noVerdict`, `rehearsalFailed`
// (`code`) and `previewFailed` (`bad` what the preview's checks found, `stopped` whether the beside rehearsal was stopped for it).
// `downFailed` is a failed `down` appended to the reason. The reason is what the records on disk carry.
export const failureOf = (kind, a) => {
  const down = a.downFailed ?? "";
  if (kind === "beforeSlot") return { why: `${a.noVerdict ? `${causes.noVerdict}: ` : ""}${a.command} ${causes.endedBeforeSlot} (exit ${a.code}): nothing released${down}`, cause: a.noVerdict ? "noVerdict" : "endedBeforeSlot" };
  if (kind === "noVerdict") return { why: `${causes.noVerdict} (exit ${a.code}): nothing released${down}`, cause: "noVerdict" };
  if (kind === "rehearsalFailed") return { why: `${causes.rehearsalFailed} (exit ${a.code}): nothing released${down}`, cause: "rehearsalFailed" };
  if (kind === "previewFailed") return { why: `${causes.previewFailed}: ${a.bad.join("; ")}${a.stopped ? `; ${causes.rehearsalStopped}` : ""}: nothing released`, cause: a.stopped ? "rehearsalStopped" : "previewFailed" };
  // The tree the run checked out moved while the rehearsal and the preview ran (`from`, `to`): an infrastructure failure, no verdict of the tree.
  if (kind === "treeMoved") return { why: `${causes.treeMoved} from ${a.from} to ${a.to} while the rehearsal and the preview ran: nothing released`, cause: "treeMoved" };
  throw new Error(`no failure of kind ${kind}`);
};

// The rehearsal and the preview run side by side (preview `when: "beside"`): what to do with them once one of them
// has ended. Each is null while it runs. `rehearsal`: {code, at}, its exit and when it ended (ms into the race);
// `preview`: {bad, at}, the reasons it failed (none: it passed). Returns `stop`, the one still running that is no
// longer worth finishing ("rehearsal" or "preview", else null), `failed` (the one whose failure ends the run: the
// earlier when both failed) and `why`. `stopped`: the driver stopped the rehearsal (it was still running when the
// preview failed) and it ended without passing. A stopped rehearsal is no verdict of the tree, so the run's reason
// says so (noVerdictRun), also when the call is made once it has ended.
export const besideOutcome = (rehearsal, preview, stopped = false) => {
  const r = !!rehearsal && rehearsal.code !== 0, p = !!preview && preview.bad.length > 0;
  if (p && (!r || preview.at < rehearsal.at)) {
    return { stop: rehearsal ? null : "rehearsal", failed: "preview", why: `${causes.previewFailed}: ${preview.bad.join("; ")}${!rehearsal || stopped ? `; ${causes.rehearsalStopped}` : ""}` };
  }
  if (r) return { stop: preview ? null : "preview", failed: "rehearsal", why: `${causes.rehearsalFailed} (exit ${rehearsal.code})${preview ? "" : `; ${causes.previewStopped}`}` };
  return { stop: null, failed: null, why: "" };
};

// A beside run's rehearsal times, in seconds (`run.beside.slot` and `.rehearse`): the slot wait, from the moment the rehearsal
// began to claim to its admission, and the run time, from admission to its end. All three are ms stamps; `admitted` is null when
// the rehearsal ended before it had a slot (all of it was waiting, none run). Step() writes nothing while the two overlap, so
// the wait is kept here, as the `slot` step is for a run that is not beside.
export const besideTimes = (began, admitted, ended) => {
  const at = admitted ?? ended;
  return { slot: Math.max(0, Math.round((at - began) / 1000)), rehearse: Math.max(0, Math.round((ended - at) / 1000)) };
};

// A bisect check that ended without judging its commit: no verdict (3), its timeout (124), a shell that could not run it (126, 127)
// or a signal (128 and above). The run stays open for the next bisect.
export const inconclusiveExit = (code) => noVerdictExit(code) || code === 126 || code === 127;

// What a failed run failed on, from its `why` and its output: the kind ("release" when release@gcp,
// a target's release command (`release (cmd)`) or the confirm failed, else "rehearsal") and the scenarios the output marks failed (`✗ <name> (12s) at step`).
export const signature = (why, text, cause) => (cause ? cause === "androidFailed" : (why ?? "").startsWith(causes.androidFailed))
  ? { kind: "android", names: androidFailed(text) }
  : {
    kind: /^release@gcp|^release \(|^released, production/.test(why ?? "") ? "release" : "rehearsal",
    // A step's failure line, or the rehearsal's own line for each id its verdicts failed (a page that threw while its
    // steps completed has no step line).
    names: [...new Set([...(text ?? "").matchAll(/✗ (\S+) \(\d+s\) at step|^rehearse: scenario failed: (\S+)$/gm)].map((m) => m[1] ?? m[2]))],
  };

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
// the newest evidence counts. Where any rehearsal record says its `mode` (an app's rehearse.ts that writes it, Bonk
// Chess's since PRONTO-683), only release-cron's own runs (`mode: "release"`) count, and not one that excused a new
// feature's failing scenario (`excused`): a hand run, a record from before modes or an excused pass proves nothing.
// `strict` (an app whose release rehearsal declares its mode, releaseModes below) applies that rule even to a history that
// holds no tagged record yet.
export const evidenceOf = (rehearsals, strict = false) => strict || rehearsals.some((r) => r.mode !== undefined) ? rehearsals.filter((r) => r.mode === "release" && !(r.excused ?? []).length) : rehearsals;
// Whether an app's configured rehearsal (releaseCron.rehearsal.command) runs in release mode, which tags its records:
// then only its tagged records are evidence, whatever the history holds.
// The rehearsal child's env: REHEARSE_LIVE names the commit that serves when the app's target is a command
// (its release leaves no release record for the classifier to read), REHEARSE_COMMIT the commit the rehearsal runs on;
// any inherited one is dropped first, so the child never reads a value another run left.
export const rehearsalEnv = (env, live, isCommandTarget, rehearsed) => {
  const { REHEARSE_LIVE: _, REHEARSE_COMMIT: __, ...rest } = env;
  return { ...rest, ...(isCommandTarget && live ? { REHEARSE_LIVE: live } : {}), ...(rehearsed ? { REHEARSE_COMMIT: rehearsed } : {}) };
};
// The rehearsal child as started: the whole environment is supplied (rehearsalEnv removed the stale keys from it), so nothing the parent has is inherited
// in its place.
export const rehearsalSpawn = (env, live, isCommandTarget, rehearsed) => ({
  env: { ...rehearsalEnv(env, live, isCommandTarget, rehearsed), STACK_WAIT_MINUTES: "525600", STACK_PRIORITY: "release" },
  clearEnv: true,
});
// The commit offered the rehearsal's selection as production's baseline: the serving commit read when the rehearsal is started, before
// its slot wait (`read`, a commit that resolved, else null), never the one read at the run's start (`earlier`): a preview run first
// leaves time for another release to land (the slot wait is not covered). Nothing reads it yet. An unread one is unknown (null, REHEARSE_LIVE omitted), not the stale one. `moved`:
// production changed since the run began. `rehearsed` is the commit the run goes on to rehearse and release.
export const rehearsalBase = (read, earlier, head) => ({ live: read || null, rehearsed: head, moved: !!read && !!earlier && read !== earlier });
export const releaseModes = (command) => (command ?? []).includes("REHEARSE_RELEASE=1");
export const verdict = (commit, sig, ev) => {
  const rehearsals = evidenceOf(ev.rehearsals ?? [], !!ev.strict), releases = ev.releases ?? [], ledger = ev.ledger ?? [];
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
  if (sig.kind === "android") return "the android step runs on an emulator, which the bisect's check (integrate@local) does not: not bisected";
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

// A bisect's check in the background: `nice -n 19`, under macOS's background QoS (`taskpolicy -b`: the
// lowest CPU, disk and network priority) where there is one, so a gate or a release always outranks it.
// Every process the check starts inherits both. `os` is Deno.build.os: Linux has no taskpolicy.
export const lowPriority = (argv, os = "darwin") => [...(os === "darwin" ? ["taskpolicy", "-b"] : []), "nice", "-n", "19", ...argv];

// The environment a scheduled run starts with, beside its PATH and HOME: gcloud's Python and config,
// each the caller's when set. Homebrew's Python is only a default on macOS; elsewhere gcloud finds its own.
export const schedulerEnv = (env, os = "darwin") => ({
  ...(env.CLOUDSDK_PYTHON ? { CLOUDSDK_PYTHON: env.CLOUDSDK_PYTHON } : os === "darwin" ? { CLOUDSDK_PYTHON: "/opt/homebrew/bin/python3.13" } : {}),
  CLOUDSDK_ACTIVE_CONFIG_NAME: env.CLOUDSDK_ACTIVE_CONFIG_NAME ?? "pronto",
});

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
// The command that records which flags the served release reads (releaseCron.flagsReleased) as run: its own argv with the app's
// folder appended; null where the app names none.
export const flagsReleasedArgv = (command, dir) => (command ? [...command, dir] : null);

// Whether a run that finds main already serving records the flags again: not when the marker (the commit the last
// successful record was written for) is the one served.
export const flagsReleasedDue = (marker, head) => (marker ?? "").trim() !== head;

// Runs that command, with a limit (`timeoutMs`, 120 s by default), and says how it went: "ok", or "failed (...)" with the exit,
// its last stderr line, or the time limit; null where the app names none. Whatever happens it returns: a record that cannot be
// written never changes a run's outcome.
export const recordFlagsReleased = async (command, dir, { cwd, env, timeoutMs = 120_000 } = {}) => {
  const argv = flagsReleasedArgv(command, dir);
  if (!argv) return null;
  try {
    const signal = AbortSignal.timeout(timeoutMs);
    const r = await new Deno.Command(argv[0] === "deno" ? Deno.execPath() : argv[0], { args: argv.slice(1), cwd, env, stdin: "null", stdout: "piped", stderr: "piped", signal }).output();
    if (signal.aborted) return `failed (timed out after ${timeoutMs / 1000}s)`;
    if (r.success) return "ok";
    const last = new TextDecoder().decode(r.stderr).trim().split("\n").pop();
    return `failed (exit ${r.code}${last ? `: ${last}` : ""})`;
  } catch (e) {
    return e?.name === "TimeoutError" ? `failed (timed out after ${timeoutMs / 1000}s)` : `failed (${String(e?.message ?? e).split("\n")[0]})`;
  }
};
export const hooksOf = (hooks, on) => (hooks ?? []).filter((h) => h.on === on);

// Who a finding reaches, by the app's `notify`: the log always when nobody else is (`none`); `github-comment` the pull
// request's comment; `claude-session` that, a notes file in a session's folder and, on a Mac (`platform`, Deno.build.os),
// a notification.
export const channels = (notify, platform) =>
  notify.kind === "claude-session" ? ["comment", "notes", ...(platform === "darwin" ? ["toast"] : [])]
  : notify.kind === "github-comment" ? ["comment"]
  : ["log"];

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

// `last`'s two commit fields for a run that ended `outcome` (spaced) on `commit`: the commit a failed run failed on (retry), and the
// commit the run tried (behind). "-" for none.
export const lastFields = (outcome, commit) => [
  outcome === outcomes.failed && commit ? commit : "-",
  commit || "-",
];

// RELEASE_CRON_DRY: any value makes the run a rehearsal of its decisions. A dry run writes no marker (flags-released) and says what it would
// have done instead.
export const mutates = (dry) => !dry;

// The paths of a `-z` listing: split on NUL, never on a newline, so a path git would quote (a non-ASCII or special name) is read as it is.
export const nulPaths = (text) => (text ?? "").split("\0").filter(Boolean);

// The lock a version before this one left: a plain file holding the holder's pid (`isFile`; its `pid`, `alive`). "busy" while that holder lives,
// "remove" when it is dead or unreadable (the mkdir lock is then made), "none" when the lock is not a file.
export const legacyFileLock = (isFile, pid, alive) => !isFile ? "none" : pid && alive ? "busy" : "remove";

// The lock's acquisition (PRONTO-1032). The lock is a directory holding the run's pid, and it is made whole before it exists: a staging directory
// holding this run's pid is renamed onto the lock, so the lock is never seen without its owner. The base driver (before #433) reads a lock
// directory with no live pid as free and writes its own pid over it, so a lock directory that ever existed empty (mkdir, then write) would be
// taken from under a new driver that is in that gap; the whole directory is what the base reader treats as a live owner from its first instant.
// What stays open, and is the rollout's rule (release-cron/README.md, "Rollout"): rename(2) replaces an EMPTY destination directory, so a base
// driver that is itself between its mkdir and its pid write (a few microseconds) can have its directory replaced by a new driver's, and then
// writes its pid over it; and two base drivers overlap likewise. No code on this side closes that: old drivers must have none running when the
// new copies land. Any pre-existing lock is looked at first, so a new driver never renames onto one it could see.
// A stale lock is removed only under an exclusive flock (`io.recovering`: the lock of an open file, which dies with its process, so no stale
// recovery state and no delayed removal by pathname can exist), after the observed holder is read again, and by renaming it to a name of its own
// whose holder is verified to be the observed one before anything is deleted. Whatever is ambiguous stops the run with an error naming the path;
// a person clears it.
// `io` is the file system and the clock (the driver's, or the fake of tests/unit/cronlock.js): mkdir, writeFile, rename, readFile, stat
// (`{ isFile, mtimeMs }`), remove, alive, recovering, now, sleep, uuid, pid. Its errors carry `code` ("EEXIST", "ENOENT", ...).

// A claim that failed: contention only where the destination already exists; anything else is an error to report, never to swallow.
export const claimError = (code) => code === "EEXIST" || code === "ENOTEMPTY" || code === "ENOTDIR" ? "contention" : "error";

// Who a holder file names, from the read's error code (`err`, null when it read) and its `text`: "absent" (no such file), "empty" (nothing
// written yet), "pid", "malformed" (not a pid) or "unreadable" (any other error): the last two are an unknown owner, never a dead one.
export const holderOf = (err, text) => {
  if (err === "ENOENT") return { kind: "absent" };
  if (err) return { kind: "unreadable", err };
  const t = String(text ?? "").trim();
  if (t === "") return { kind: "empty" };
  return /^[0-9]+$/.test(t) && Number(t) > 0 ? { kind: "pid", pid: Number(t) } : { kind: "malformed", text: t.slice(0, 40) };
};

// What a lock's holder means for a run: "busy" (a live pid), "stale" (a verified dead pid, or the flock version's file with none),
// "pending" (a directory with no pid yet, within `graceMs` of its making: the base driver's gap) or "unknown" (the holder cannot be read or is
// not a pid, or a directory has had no pid for the grace: fail closed, the lock is neither taken nor removed, and a person removes it).
// `isFile`: the plain file the flock version left. `alive`: the pid is confirmed alive (a probe that could not tell throws, see aliveFromKill).
export const lockVerdict = (holder, alive, ageMs, graceMs, isFile) =>
  holder.kind === "pid" ? (isFile ? (legacyFileLock(true, holder.pid, alive) === "busy" ? "busy" : "stale") : alive ? "busy" : "stale")
  : holder.kind === "empty" || holder.kind === "absent" ? (isFile ? "stale" : ageMs >= graceMs ? "unknown" : "pending")
  : "unknown";

// What `kill -0 pid` (process.kill(pid, 0)) says, from its error `code` (null when it succeeded): the process exists (null, EPERM: a live
// process of another user), is confirmed missing (ESRCH: only that lets a lock be reclaimed), or cannot be told (anything else throws:
// fail closed, a live release is never evicted on a probe that failed).
export const aliveFromKill = (code) => {
  if (code === null || code === undefined || code === "EPERM") return true;
  if (code === "ESRCH") return false;
  throw new Error(`release-cron lock: cannot tell whether the holder is alive (kill -0: ${code}); not taken, not removed`);
};

const lockFail = (op, path, e) => new Error(`release-cron lock: ${op} ${path}: ${e && e.code ? `${e.code}: ` : ""}${e && e.message ? e.message : e}`);

// One claim of `path`: true when this run's whole staging directory is now the lock, false when something exists there, an error (thrown, with
// the operation and path) for anything else. The staging directory is this run's alone and is removed whenever it did not become the lock.
export const lockClaim = (io, path) => {
  const stage = `${path}.new.${io.pid}.${io.uuid()}`;
  const clear = () => { try { io.remove(stage); } catch { /* a stray staging directory, harmless */ } };
  try { io.mkdir(stage); io.writeFile(`${stage}/pid`, String(io.pid)); } catch (e) { clear(); throw lockFail("stage pid in", stage, e); }
  try { io.stat(path); clear(); return false; } catch (e) { if (!e || e.code !== "ENOENT") { clear(); throw lockFail("stat", path, e); } }
  try { io.rename(stage, path); } catch (e) {
    clear();
    if (claimError(e && e.code) === "contention") return false;
    throw lockFail("rename", `${stage} to ${path}`, e);
  }
  // Ownership is the pid as it stands now.
  let owner;
  try { owner = io.readFile(`${path}/pid`).trim(); } catch (e) { throw lockFail("verify pid in", path, e); }
  if (owner !== String(io.pid)) throw new Error(`release-cron lock: ${path}/pid names ${JSON.stringify(owner.slice(0, 40))}, not this run (${io.pid}): another driver wrote over it; run not started`);
  return true;
};

// The state of a lock as found: null when there is none, else its holder, its kind and its age.
const lockLook = (io, path) => {
  let st;
  try { st = io.stat(path); } catch (e) { if (e && e.code === "ENOENT") return null; throw lockFail("stat", path, e); }
  const file = st.isFile ? path : `${path}/pid`;
  let err = null, text = "";
  try { text = io.readFile(file); } catch (e) { err = (e && e.code) || "EUNKNOWN"; }
  const holder = holderOf(err, text);
  return { isFile: st.isFile, holder, ageMs: io.now() - st.mtimeMs, pid: holder.kind === "pid" ? holder.pid : 0 };
};
const unknownHolder = (path, look) => new Error(`release-cron lock: ${path} has a holder that cannot be told (${look.holder.kind}${look.holder.err ? ` ${look.holder.err}` : ""}${look.holder.text ? ` ${JSON.stringify(look.holder.text)}` : ""}); not taken, not removed`);
const sameHolder = (a, b) => a.holder.kind === b.holder.kind && a.pid === b.pid && a.isFile === b.isFile;

// Removes the stale lock `look` (observed under the recovery flock): renamed to a name of its own, its holder read there and compared with the
// observed one, and only then deleted. A lock that is not the observed one is put back and the run stops: it is never deleted.
const lockRemoveStale = (io, path, look) => {
  const gone = `${path}.gone.${io.pid}.${io.uuid()}`;
  try { io.rename(path, gone); } catch (e) { if (e && e.code === "ENOENT") return; throw lockFail("rename", path, e); }
  const was = lockLook(io, gone);
  if (!was || !sameHolder(look, was)) {
    try { io.rename(gone, path); } catch (e) { throw new Error(`release-cron lock: ${path} was not the lock observed stale and could not be put back from ${gone} (${e && e.code ? e.code : e}); a person must restore or remove it`); }
    throw new Error(`release-cron lock: ${path} changed while it was being removed; put back, not taken`);
  }
  try { io.remove(gone); } catch { /* left for a person: it is no longer the lock */ }
};

// Takes the lock at `path`: `{ got: true }`, or `{ got: false, pid }` while another run holds it. A holder that cannot be told, a failed
// write and more attempts than `tries` throw: a run that does not hold the lock must not go on, nor report itself as skipped for a holder
// that does not exist.
export const lockAcquire = (io, path, { tries = 5, graceMs = 10000, pollMs = 250 } = {}) => {
  const deadline = io.now() + graceMs + 30000;
  for (let n = 0; n < tries && io.now() < deadline;) {
    if (lockClaim(io, path)) return { got: true };
    const look = lockLook(io, path);
    if (!look) { n++; continue; } // released between the claim and this look: claim again
    const v = lockVerdict(look.holder, look.pid > 0 && io.alive(look.pid), look.ageMs, graceMs, look.isFile);
    if (v === "busy") return { got: false, pid: look.pid };
    if (v === "unknown") throw unknownHolder(path, look);
    if (v === "pending") { io.sleep(pollMs); continue; }
    n++;
    // Stale: one run at a time recovers, and what it removes is what it observed.
    const out = io.recovering(() => {
      const again = lockLook(io, path);
      if (again) {
        const av = lockVerdict(again.holder, again.pid > 0 && io.alive(again.pid), again.ageMs, graceMs, again.isFile);
        if (av === "unknown") throw unknownHolder(path, again);
        if (av === "busy") return { got: false, pid: again.pid };
        if (av === "pending") return null;
        if (!sameHolder(look, again)) return null; // another holder than the one judged stale: judged again
        lockRemoveStale(io, path, again);
      }
      return lockClaim(io, path) ? { got: true } : null;
    });
    if (out) return out;
  }
  throw new Error(`release-cron lock: ${path}: not taken after ${tries} attempts; run not started`);
};

// Gives the lock back: the lock is removed only when it holds this run's pid, by renaming it away first so the lock is gone in one step.
// A lock that is not there or is another run's is left; a pid file that cannot be read, or a lock that cannot be removed, throws (the
// run holds a lock it cannot give back: a replacement would find a live holder and skip, silently).
export const lockRelease = (io, path) => {
  let text;
  try { text = io.readFile(`${path}/pid`); } catch (e) {
    if (e && e.code === "ENOENT") return "none";
    throw lockFail("read pid in", path, e);
  }
  if (text.trim() !== String(io.pid)) return "not ours";
  const gone = `${path}.gone.${io.pid}.${io.uuid()}`;
  try { io.rename(path, gone); } catch (e) { throw lockFail("give back", path, e); }
  try { io.remove(gone); } catch { /* litter beside a released lock */ }
  return "released";
};


// A signal's wait, each tick: "kill" the children still alive once their grace is over, "done" when the children are gone and no
// preview is left (`previews`: its `up`, which a signal never stops, and its `down`), or when `grace` + `teardown` ms have passed with no
// preview left (a stuck child is bounded; a preview's remote operation is waited for, since a lock given back under it would let the next
// run start beside it), else "wait". The lock goes at "done".
export const signalStep = (childrenAlive, previews, elapsed, grace, teardown) =>
  previews === 0 && elapsed >= grace + teardown ? "done"
  : !childrenAlive && previews === 0 ? "done"
  : childrenAlive && elapsed >= grace ? "kill"
  : "wait";

// Only an ssh transport failure (exit 255) is worth reading the serving command again: any other failure says what is wrong.
export const servingRetryable = (code) => sshDropped(code);
// While the node is read for a release whose ssh dropped: "wait" for the next read after an ssh transport failure, "fail" at once for any other exit (the serving command ran and failed).
export const rescueReadStep = (code) => servingRetryable(code) ? "wait" : "fail";

// The outcome a run ends with once a signal came: its stop, never a verdict (no gap, no bisect). A
// release that had already landed keeps its outcome.
export const endWhenInterrupted = (interrupted, outcome) => interrupted && outcome !== outcomes.released ? outcomes.stopped : outcome;

// A reason with another appended (a throw after the run's own reason was set).
export const appendWhy = (prev, why) => prev ? `${prev}; ${why}` : why;
// The flags-released bookkeeping's result (`result`: recordFlagsReleased's) once its marker was written or not (`err`: the write's error, null when it
// was): a marker that could not be written is a bookkeeping failure with its path, apart from the deploy outcome (run.flagsReleased, never `outcome`).
// The job's exit once the flags-released bookkeeping ran (`result`: flagsBookkeeping's, null where the app names none): nonzero when it failed, so CD
// sees it. The run's outcome and its confirmed revision stay what they were (a deploy that served is released or skipped); the next wake writes the
// marker again without redeploying (flagsReleasedDue).
export const flagsExit = (result) => result && result !== "ok" ? 1 : 0;
export const flagsBookkeeping = (result, path, err) => result === "ok" && err ? `failed (the marker ${path} was not written: ${String(err).split("\n")[0]})` : result;
