// release-cron: an app released to production on a schedule, by launchd on this Mac, from main.
// pronto-plugins' release-cron/README.md says more. Run from the app's folder, where it is written:
//   deno run -A release-cron/release-cron.ts <app> run         one run now (what launchd runs)
//   deno run -A release-cron/release-cron.ts <app> install     the run's worktree and the launchd job
//   deno run -A release-cron/release-cron.ts <app> uninstall   the launchd job gone (the worktree kept)
//   deno run -A release-cron/release-cron.ts <app> pause|resume  runs skip while paused
//   deno run -A release-cron/release-cron.ts <app> status      the job, the pause, the last runs
//   deno run -A release-cron/release-cron.ts <app> report      every release measured, the newest's phases against those before
// RELEASE_CRON_REF names the ref a run takes in place of origin/main (a branch's, to try a change to
// this script); RELEASE_CRON_DRY=1 ends a run once it knows whether it would rehearse.
// launchd wakes it every few minutes; a wake starts a run only once the gap since the last run
// that released or failed is over (release, wait an hour, release again). A run: main fetched into the run's own worktree; skipped when nothing the app's releaseCron
// watches changed since the last run that released; else `./saytw verify@local`, then `./saytw release@gcp`
// on that tree, then production confirmed; one line in the log. An app whose release.cue names
// GCP.rehearsal has its rehearsal in the cloud, inside release@gcp (a Cloud Run job against the rc
// preview): the run then takes no slot and runs nothing heavy here, and records the job's minutes and cost. Each step has its limit and the run
// a limit (#Cron, release_cron_plugin.cue) against a wedge; a lock keeps two from overlapping. Every run is measured: its
// steps, and inside them the rehearsal's and the release's phases, for `report`.
// A run holds the machine while it works: ~/.cache/pronto/release-active (RELEASE_ACTIVE names another),
// one line of JSON {"app","pid","started","phase"} with phase slot, rehearse, release or confirm, written
// as the run enters its slot, updated at each step and removed when the run ends, on every outcome and
// on a signal. A file whose pid is gone (kill -0) is stale: readers ignore it and may delete it. A reader
// (an app's tests/slot.ts) starts no new heavy work while it is live and polls every 30 s.
// Its state is ~/.cache/pronto/release-cron/<app>/: the worktree (wt), the lock, the pause, the
// log (release-cron.log, a line a run), last (when the last spaced run ended), runs.jsonl (the same as JSON) and each run's output (runs/).
import { activeLine, base, changed, detail, due, holds, line, local, plist, probe, report, served, spaced, retry, whole } from "./cron.js";

const here = new URL("./", import.meta.url).pathname;
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
// The app's folder from the repository's root (apps/brawl-chess): the one this script was written
// into, the same in every checkout, the run's worktree too.
const top = decode(new Deno.Command("git", { args: ["rev-parse", "--show-toplevel"], cwd: here, stdout: "piped" }).outputSync().stdout).trim();
const appRel = Deno.realPathSync(`${here}..`).slice(Deno.realPathSync(top).length + 1);
const [app, verb = "run"] = Deno.args;
if (!app) throw new Error("name the app: release-cron.ts <app> [run|install|uninstall|pause|resume|status]");
const home = Deno.env.get("HOME")!;
const state = `${home}/.cache/pronto/release-cron/${app}`;
const wt = `${state}/wt`;
const label = `dev.pronto.release-cron.${app}`;
const agent = `${home}/Library/LaunchAgents/${label}.plist`;
const uid = decode(new Deno.Command("id", { args: ["-u"], stdout: "piped" }).outputSync().stdout).trim();
Deno.mkdirSync(`${state}/runs`, { recursive: true });

// A command and its output, killed (SIGALRM, which survives exec) past `seconds`: a hung fetch or
// gcloud must not hold the run, and its lock, forever.
const sh = (cmd: string, args: string[], cwd?: string, env: Record<string, string> = {}, seconds = 300) => {
  const o = new Deno.Command("perl", { args: ["-e", "alarm shift; exec @ARGV or die $!", String(seconds), cmd, ...args], cwd, env, stdout: "piped", stderr: "piped" }).outputSync();
  return { ok: o.success, out: decode(o.stdout).trim(), err: decode(o.stderr).trim() };
};
const must = (cmd: string, args: string[], cwd?: string, env: Record<string, string> = {}, seconds = 300) => {
  const r = sh(cmd, args, cwd, env, seconds);
  if (!r.ok) throw new Error(`${cmd} ${args.join(" ")}${cwd ? ` (in ${cwd})` : ""}: ${r.err || r.out}`);
  return r.out;
};

// mise, as the shell finds it or sayt's own (which ./saytw installs): a shell or launchd without it on
// the PATH still finds the app's tools through it.
const mise = sh("sh", ["-c", "command -v mise"]).out || `${home}/Library/Caches/sayt/mise-v2026.8.11/mise`;

if (verb === "pause") { Deno.writeTextFileSync(`${state}/paused`, local(Date.now()) + "\n"); console.log(`${app}: paused; runs skip until \`resume\``); Deno.exit(0); }
if (verb === "resume") { Deno.removeSync(`${state}/paused`); console.log(`${app}: resumed`); Deno.exit(0); }
if (verb === "status") {
  const job = sh("launchctl", ["print", `gui/${uid}/${label}`]);
  console.log(`job ${label}: ${job.ok ? "installed" : "not installed"}${exists(`${state}/paused`) ? ", paused" : ""}`);
  console.log(sh("tail", ["-n", "12", `${state}/release-cron.log`]).out);
  Deno.exit(0);
}
const jsonl = (f: string) => { try { return Deno.readTextFileSync(f).split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
if (verb === "report") { console.log(report(jsonl(`${state}/runs.jsonl`))); Deno.exit(0); }
if (verb === "uninstall") {
  sh("launchctl", ["bootout", `gui/${uid}/${label}`]);
  Deno.removeSync(agent);
  console.log(`${label}: removed (the worktree ${wt} kept)`);
  Deno.exit(0);
}

// The run's worktree, at main: its own checkout, never one a person or a session works in.
const ref = Deno.env.get("RELEASE_CRON_REF") ?? "origin/main";
function worktree() {
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], exists(wt) ? wt : here);
  must("git", ["--git-dir", repo, "fetch", "-q", "origin"]);
  if (!exists(`${wt}/.git`)) must("git", ["--git-dir", repo, "worktree", "add", "-q", "--detach", wt, ref]);
  must("git", ["checkout", "-q", "--detach", "-f", ref], wt);
  // Clean as main is; what git ignores (builds, caches) is kept, as in any checkout.
  must("git", ["clean", "-ffdq"], wt);
  sh(mise, ["trust", "-q", `${wt}/${appRel}/.mise.toml`]);
  return must("git", ["rev-parse", "HEAD"], wt);
}

// The app's release and opt-in, read from CUE as prod-watch reads them, held to #Cron with its defaults
// (release_cron_plugin.cue): the three files alone, as the whole package takes a minute to export.
function config(dir: string) {
  const appDir = `${dir}/${appRel}`;
  // The app's own cue, as mise finds it there: a shim run from elsewhere finds no version.
  const cue = Deno.env.get("CUE") || sh(mise, ["which", "cue"], appDir, {}, 60).out || "cue";
  const registry = Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1];
  const { gcp, cron } = JSON.parse(must(cue, ["export", "release.cue", "release_cron.cue", "release_cron_plugin.cue", "-e", "{gcp: GCP, cron: releaseCron}", "--out", "json"], appDir, registry ? { CUE_REGISTRY: registry } : {}));
  return { gcp, cron: { ...cron, watch: cron.watch?.length ? cron.watch : [appRel] } };
}

if (verb === "install") {
  const head = worktree();
  const { cron } = config(wt);
  // launchd's environment is bare: the tools the run calls by name are found as the app's mise finds
  // them, and sayt's own mise (which ./saytw installs) is on its PATH for `mise trust`.
  const appDir = `${wt}/${appRel}`;
  const which = (t: string) => sh(mise, ["which", t], appDir).out;
  const path = [...new Set([mise.replace(/\/mise$/, ""), `${home}/.local/share/mise/shims`, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])].join(":");
  // The job's cue by its path: a bare name would leave launchd's runs to whichever cue a shim finds.
  const cue = which("cue") || Deno.env.get("CUE") || "";
  if (!cue.startsWith("/")) throw new Error(`install: no path for cue (mise which cue in ${appDir} found none): set CUE to it`);
  const env = { PATH: path, HOME: home, CUE: cue, CLOUDSDK_PYTHON: Deno.env.get("CLOUDSDK_PYTHON") ?? "/opt/homebrew/bin/python3.13" };
  Deno.mkdirSync(`${home}/Library/LaunchAgents`, { recursive: true });
  Deno.writeTextFileSync(agent, plist({ label, program: Deno.execPath(), args: ["run", "-A", `${wt}/${appRel}/release-cron/release-cron.ts`, app, "run"], poll: cron.poll, log: `${state}/launchd.log`, env }));
  sh("launchctl", ["bootout", `gui/${uid}/${label}`]);
  must("launchctl", ["bootstrap", `gui/${uid}`, agent]);
  console.log(`${label}: a run ${cron.gap} min after the last release, checked every ${cron.poll} min, from ${wt} (main ${head.slice(0, 8)}); steps limited to ${Object.entries(cron.minutes).map(([k, m]) => `${k} ${m}`).join(", ")} min`);
  Deno.exit(0);
}
if (verb !== "run") throw new Error(`${verb}: run, install, uninstall, pause, resume or status`);

// --- A run. ---
// The script as this process loaded it: a run that finds it changed on main runs main's (below).
const here_ = (f: string) => { try { return Deno.readTextFileSync(`${here}${f}`); } catch { return ""; } };
const loaded = ["release-cron.ts", "cron.js"].map(here_).join("\0");
const t0 = Date.now();
const started = local(t0);
let out: Deno.FsFile | undefined;
const log = (b: Uint8Array) => (out ??= Deno.openSync(`${state}/runs/${started}.log`, { write: true, create: true, append: true })).writeSync(b);
const enc = new TextEncoder();
const say = (s: string) => { const l = `release-cron: ${Math.round((Date.now() - t0) / 1000)}s ${s}\n`; log(enc.encode(l)); Deno.stdout.writeSync(enc.encode(l)); };
let head = "";
let gcp: { name: string; service: string; project: string; region: string; domain?: string; rehearsal?: { job: string } } | undefined;
let cron: { gap: number; poll: number; watch: string[]; ready: string[]; holder: string; minutes: Record<string, number>; probes: Record<string, { path: string; agent?: string; status: number; has: string[] }> };
let before: string | null = null;
const steps: Record<string, number> = {};
let mark = Date.now();
const step = (name: string) => { steps[name] = Math.round((Date.now() - mark) / 1000); mark = Date.now(); };
const run: Record<string, unknown> = { app, started, steps };
// The release-active file: written whole to a temporary file then renamed, so a reader never sees half.
const activePath = Deno.env.get("RELEASE_ACTIVE") ?? `${home}/.cache/pronto/release-active`;
const active = (phase: string) => {
  try {
    // One file for the machine: another app's live run keeps it (releases of different apps run in
    // parallel); this run takes it at its next phase once that run is gone.
    const other = (() => { try { return Number(JSON.parse(Deno.readTextFileSync(activePath)).pid); } catch { return 0; } })();
    if (other > 0 && other !== Deno.pid && sh("kill", ["-0", String(other)]).ok) return;
    Deno.mkdirSync(activePath.replace(/\/[^/]*$/, ""), { recursive: true });
    Deno.writeTextFileSync(`${activePath}.${Deno.pid}.tmp`, activeLine(app, Deno.pid, started, phase));
    Deno.renameSync(`${activePath}.${Deno.pid}.tmp`, activePath);
  } catch (e) { say(`release-active not written: ${(e as Error).message}`); }
};
const end = (outcome: string, why = "", code = 0) => {
  // The machine is given back first, whatever the outcome; only a file this run wrote is removed.
  try { if (JSON.parse(Deno.readTextFileSync(activePath)).pid === Deno.pid) Deno.removeSync(activePath); } catch { /* none, or not ours */ }
  Object.assign(run, { outcome, why: why || undefined, ended: local(Date.now()) });
  // Inside the steps: the rehearsal's and the release's own records of this commit, since this run began.
  if (run.commit && ("rehearse" in steps || "release" in steps) && gcp) {
    const d = detail(jsonl(`${home}/.cache/pronto/rehearsals/${app}.jsonl`), jsonl(`${home}/.cache/pronto/releases/${gcp.name}.jsonl`), run.commit, new Date(t0).toISOString());
    run.detail = d;
    if (d.rehearsal) run.rehearsal = d.rehearsal;
  }
  const l = line(run);
  Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
  Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify(run) + "\n", { append: true });
  // `last`: the end, the gap, and for a failed run the commit it failed on (retry, cron.js).
  if (spaced(outcome)) Deno.writeTextFileSync(`${state}/last`, `${Date.now()} ${(run.gap as number | undefined) ?? 60}${outcome === "failed" && run.commit ? ` ${run.commit}` : ""}`);
  say(l);
  // The last 50 runs' output kept.
  const logs = [...Deno.readDirSync(`${state}/runs`)].map((e) => e.name).sort();
  for (const old of logs.slice(0, -50)) Deno.removeSync(`${state}/runs/${old}`);
  try { if (Deno.readTextFileSync(`${state}/lock/pid`) === String(Deno.pid)) Deno.removeSync(`${state}/lock`, { recursive: true }); } catch { /* none, or not ours */ }
  Deno.exit(code);
};

if (exists(`${state}/paused`)) end("skipped", "paused");

// The lock: a directory (made or not, atomically) holding the run's pid. A lock whose run is gone is
// taken over; one whose run lives means this run skips: launchd never overlaps its own job, and
// this keeps a run started by hand from overlapping it.
try { Deno.mkdirSync(`${state}/lock`); } catch {
  const pid = Number((() => { try { return Deno.readTextFileSync(`${state}/lock/pid`); } catch { return "0"; } })());
  if (pid && sh("kill", ["-0", String(pid)]).ok) {
    // Logged as any run, but the lock is the other run's: left alone.
    const l = line({ app, started, steps: {}, outcome: "skipped", why: `run ${pid} still going` });
    Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
    console.log(l);
    Deno.exit(0);
  }
}
Deno.writeTextFileSync(`${state}/lock/pid`, String(Deno.pid));

// Not due: the wake ends here, with no line (it was no run). The gap is the config of the tree last
// run, kept beside its end; the first run has none.
{
  const [at, gap, failed] = (() => { try { const [a, g, f] = Deno.readTextFileSync(`${state}/last`).trim().split(" "); return [Number(a), Number(g), f]; } catch { return [NaN, NaN, undefined]; } })();
  // After a failed run, main as the remote has it now (git ls-remote, no fetch): moved past the
  // failed commit, the run starts without the gap.
  const moved = () => { const r = sh("git", ["ls-remote", "origin", "refs/heads/main"], wt, {}, 60); return r.ok ? r.out.split(/\s/)[0] || null : null; };
  if (!Number.isNaN(at) && !due(Date.now(), at, Number.isNaN(gap) ? 60 : gap) && !(failed && retry(failed, moved()))) {
    try { Deno.removeSync(`${state}/lock`, { recursive: true }); } catch { /* ours, just made */ }
    Deno.exit(0);
  }
}

let current: { pgid: number } | undefined;
// Stopped: the child's group stopped and gone (killed after a minute) before the run ends and its
// lock goes, so the next run never starts beside what this one started.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  Deno.addSignalListener(signal, async () => {
    if (current) {
      const pgid = current.pgid;
      stop(pgid);
      for (const t = Date.now(); alive(pgid) && Date.now() - t < 60_000;) await new Promise((r) => setTimeout(r, 1000));
      if (alive(pgid)) send(pgid, "KILL");
    }
    end("stopped", signal, 130);
  });
}

// A child and everything it started, stopped by a limit or a signal: sayt makes a process group of
// its own, so the tree is read from ps (every descendant of the child) and each process and group
// in it is signalled. Its output, both streams, is kept in the run's log, each line given to `watch`.
const table = () => sh("ps", ["-axo", "pid=,ppid=,pgid="], undefined, {}, 30).out.split("\n").map((l) => l.trim().split(/\s+/).map(Number));
const tree = (root: number) => {
  const rows = table(), pids = new Set([root]);
  for (let grew = true; grew;) { grew = false; for (const [pid, ppid] of rows) if (pids.has(ppid) && !pids.has(pid)) { pids.add(pid); grew = true; } }
  const groups = new Set(rows.filter(([pid]) => pids.has(pid)).map(([, , pgid]) => pgid));
  return { pids: [...pids].filter((p) => rows.some(([q]) => q === p)), groups: [...groups] };
};
const send = (root: number, sig: string) => {
  const t = tree(root);
  for (const g of t.groups) sh("kill", [`-${sig}`, "--", `-${g}`], undefined, {}, 10);
  for (const p of t.pids) sh("kill", [`-${sig}`, String(p)], undefined, {}, 10);
};
const alive = (root: number) => tree(root).pids.length > 0;
const killers: ReturnType<typeof setTimeout>[] = [];
function stop(pgid: number) {
  send(pgid, "TERM");
  killers.push(setTimeout(() => { if (alive(pgid)) send(pgid, "KILL"); }, 60_000));
}
async function child(cmd: string, args: string[], cwd: string, env: Record<string, string>, minutes: number, watch: (l: string) => void = () => {}) {
  const p = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", cmd, ...args], cwd, env, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  current = { pgid: p.pid };
  let late = false;
  const timer = setTimeout(() => { late = true; say(`${cmd} ${args.join(" ")}: past its ${minutes} min, stopped`); stop(p.pid); }, minutes * 60_000);
  const relay = async (from: ReadableStream<Uint8Array>) => {
    const dec = new TextDecoder();
    let partial = "";
    for await (const chunk of from) {
      log(chunk);
      const lines = (partial + dec.decode(chunk, { stream: true })).split("\n");
      partial = lines.pop()!;
      lines.forEach(watch);
    }
  };
  await Promise.all([relay(p.stdout), relay(p.stderr)]);
  const { code } = await p.status;
  clearTimeout(timer);
  killers.splice(0).forEach(clearTimeout);
  current = undefined;
  return { code, late };
}

const gcloud = (args: string[], seconds = 120) => must("gcloud", [...args, "--project", gcp!.project, "--region", gcp!.region, "--format=json"], undefined, {}, seconds);
try {
  // 1. Main, its config, the commit serving.
  head = worktree();
  // launchd runs the worktree's script, loaded before the worktree moved to main: when main changed
  // it, this run hands over to main's, which takes the lock and goes on, so a merged fix applies to
  // the next run, not the one after. RELEASE_CRON_AGAIN keeps it to one hand-over.
  if (here.startsWith(wt) && !Deno.env.get("RELEASE_CRON_AGAIN") && ["release-cron.ts", "cron.js"].map(here_).join("\0") !== loaded) {
    say("the script changed on main: running main's");
    try { Deno.removeSync(`${state}/lock`, { recursive: true }); } catch { /* ours */ }
    const again = await new Deno.Command(Deno.execPath(), { args: ["run", "-A", `${here}release-cron.ts`, ...Deno.args], env: { RELEASE_CRON_AGAIN: "1" }, stdin: "null", stdout: "inherit", stderr: "inherit" }).spawn().status;
    Deno.exit(again.code);
  }
  run.commit = head;
  ({ gcp, cron } = config(wt));
  run.gap = cron.gap;
  before = whole(JSON.parse(gcloud(["run", "services", "describe", gcp!.service])).status?.traffic);
  const live = base(jsonl(`${state}/runs.jsonl`), before);
  step("prepare");
  if (live === head) end("skipped", `main ${head.slice(0, 8)} is serving as ${before}`);
  if (live) {
    const diff = sh("git", ["diff", "--name-only", live, head], wt);
    if (diff.ok && !changed(diff.out.split("\n").filter(Boolean), cron.watch).length) end("skipped", `nothing under ${cron.watch.join(", ")} changed since ${live.slice(0, 8)}, released by a run and serving as ${before}`);
  }
  if (Deno.env.get("RELEASE_CRON_DRY")) end("dry", `would rehearse and release ${head.slice(0, 8)}: it differs from ${live?.slice(0, 8) ?? "an unknown commit"}, serving as ${before}`);
  say(`${head.slice(0, 8)} differs from what serves (${live ? live.slice(0, 8) : `unknown: no run that released confirmed ${before}`}): rehearsing`);

  // 2. The rehearsal: its slot within cron.minutes.slot, its run within cron.minutes.rehearse.
  const dir = `${wt}/${appRel}`;
  // With GCP.rehearsal the rehearsal is release@gcp's own, in the cloud: no slot, nothing run here.
  const cloud = !!gcp!.rehearsal;
  if (cloud) say(`GCP.rehearsal: the rehearsal runs in the cloud, job ${gcp!.rehearsal!.job}, inside release@gcp`);
  let got = cloud, busy = false;
  if (!cloud) active("slot");
  const queue = setTimeout(() => { if (!got && current) { busy = true; say(`no slot within ${cron.minutes.slot} min: skipping`); stop(current.pgid); } }, cron.minutes.slot * 60_000);
  // slot.ts's own wait outlasts this one, so the run's limit is the one that ends a wait.
  // The slot is taken once a live slot of the pool names this rehearsal as its owner.
  const pool = Deno.env.get("STACK_POOL") ?? "/tmp/pronto-stacks";
  const look = setInterval(() => {
    if (got) return;
    for (const e of (() => { try { return [...Deno.readDirSync(pool)]; } catch { return []; } })()) {
      if (!/^slot-\d+$/.test(e.name)) continue;
      const owner = (() => { try { return Deno.readTextFileSync(`${pool}/${e.name}/owner`); } catch { return ""; } })();
      const pid = (() => { try { return Deno.readTextFileSync(`${pool}/${e.name}/pid`).trim(); } catch { return ""; } })();
      // The holder alive and started by this run: not a slot a dead or stray rehearsal left.
      const ours = pid && current && tree(current.pgid).pids.includes(Number(pid));
      if (ours && holds(owner, dir, cron.holder) && owner.startsWith(`${pid} `)) { got = true; step("slot"); active("rehearse"); say(`slot taken: ${e.name}`); return; }
    }
  }, 5000);
  // STACK_PRIORITY=release puts its claim at the head of the pool's line, ahead of every claim a
  // pull request's gate or a launch is waiting with (tests/slot.ts).
  const gate = cloud ? { code: 0, late: false } : await child("./saytw", ["verify@local"], dir, { ...Deno.env.toObject(), STACK_WAIT_MINUTES: String(cron.minutes.slot + 5), STACK_PRIORITY: "release" }, cron.minutes.slot + cron.minutes.rehearse);
  clearTimeout(queue);
  clearInterval(look);
  // Every check passed already for this tree: the rehearsal took no slot and waited for none.
  if (!got && !busy && gate.code === 0) { got = true; step("slot"); active("rehearse"); }
  if (busy) { step("slot"); end("skipped", `the slot queue was busy for ${cron.minutes.slot} min; the next run asks again`); }
  if (!got) { step("slot"); end("failed", `verify@local ended before its slot (exit ${gate.code}): nothing released`, 1); }
  if (!cloud) step("rehearse");
  if (gate.code !== 0) end("failed", gate.late ? `the rehearsal outlasted its limit` : `the rehearsal failed (exit ${gate.code}): nothing released`, 1);

  // 3. The release, on the tree the rehearsal passed.
  active("release");
  const rel = await child("./saytw", ["release@gcp"], dir, { ...Deno.env.toObject(), STACK_PRIORITY: "release" }, cron.minutes.release);
  step("release");
  if (rel.code !== 0) end("failed", rel.late ? "release@gcp outlasted its limit" : `release@gcp failed (exit ${rel.code})`, 1);

  // 4. Production: the revision taking every request is the one this tree's live record names, the `ready` services are
  // ready, the probes answer. Retried within cron.minutes.confirm, as a cache or a cold start settles.
  active("confirm");
  const until = Date.now() + cron.minutes.confirm * 60_000;
  let wrong: string[] = [];
  let origin = gcp!.domain ? `https://${gcp!.domain}` : "";
  for (;;) {
    wrong = [];
    // A gcloud call that fails is one more thing wrong this round, retried with the rest: the release
    // has happened, and a flake must not log it failed.
    try {
      const svc = JSON.parse(gcloud(["run", "services", "describe", gcp!.service], 60));
      const now = whole(svc.status?.traffic);
      // The probes' address: the domain mapped onto the service, else its run.app one (GCP.domain absent).
      origin = gcp!.domain ? `https://${gcp!.domain}` : svc.status?.url ?? origin;
      run.revision = now;
      wrong.push(...served(now, jsonl(`${home}/.cache/pronto/releases/${gcp!.name}.jsonl`), head));
    } catch (e) { wrong.push(`traffic unread: ${(e as Error).message.split("\n")[0]}`); }
    for (const svc of cron.ready) {
      try {
        const c = JSON.parse(gcloud(["run", "services", "describe", svc], 60)).status?.conditions?.find((c: { type: string }) => c.type === "Ready");
        if (c?.status !== "True") wrong.push(`${svc} not ready`);
      } catch (e) { wrong.push(`${svc} unread: ${(e as Error).message.split("\n")[0]}`); }
    }
    for (const [name, p] of Object.entries(cron.probes)) {
      try {
        const r = await fetch(`${origin}${p.path}`, { headers: p.agent ? { "User-Agent": p.agent } : {}, signal: AbortSignal.timeout(30_000) });
        const v = probe(p, r.status, await r.text());
        if (v) wrong.push(`${name} ${v}`);
      } catch (e) { wrong.push(`${name} ${p.path}: ${(e as Error).message}`); }
    }
    if (!wrong.length || Date.now() > until) break;
    await new Promise((r) => setTimeout(r, 15_000));
  }
  step("confirm");
  if (wrong.length) end("failed", `released, production not confirmed: ${wrong.join("; ")}`, 1);
  // A release that changed nothing Cloud Run runs (tests, config) keeps the revision: said, so it
  // does not read as a deploy that never went out.
  end("released", run.revision === before ? `same image, nothing served changed: ${before} kept` : "");
} catch (e) {
  step("error");
  end("failed", (e as Error).message.split("\n")[0], 1);
}

function exists(p: string) { try { Deno.statSync(p); return true; } catch { return false; } }
