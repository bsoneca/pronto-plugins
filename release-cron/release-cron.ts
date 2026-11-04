// release-cron: an app released to production on a schedule, by launchd on this Mac, from main.
// pronto-plugins' release-cron/README.md says more. Run from the app's folder, where it is written:
//   deno run -A release-cron/release-cron.ts <app> run         one run now (what launchd runs)
//   deno run -A release-cron/release-cron.ts <app> install     the run's worktree and the launchd job
//   deno run -A release-cron/release-cron.ts <app> uninstall   the launchd job gone (the worktree kept)
//   deno run -A release-cron/release-cron.ts <app> pause|resume  runs skip while paused
//   deno run -A release-cron/release-cron.ts <app> status      the job, the pause, the last runs
//   deno run -A release-cron/release-cron.ts <app> report      every release measured, the newest's phases against those before
//   deno run -A release-cron/release-cron.ts <app> bisect [--dry|--no-notify]  the commit that broke the last failed run (a failed run starts it as it ends)
// RELEASE_CRON_REF names the ref a run takes in place of origin/main (a branch's, to try a change to
// this script); RELEASE_CRON_DRY=1 ends a run once it knows whether it would rehearse;
// RELEASE_CRON_NOW=1 starts the run without waiting the gap (a CD job's run for the commit it was pushed for).
// launchd wakes it every few minutes; a wake starts a run only once the gap since the last run
// that released or failed is over (release, wait an hour, release again). A run: main fetched into the run's own worktree; skipped when nothing the app's releaseCron
// watches changed since the last run that released; else `./saytw verify@local`, then `./saytw release@gcp`
// on that tree, then production confirmed; one line in the log. An app whose release.cue names
// GCP.rehearsal has its rehearsal in the cloud, inside release@gcp (a Cloud Run job against the rc
// preview): the run then takes no slot and runs nothing heavy here, and records the job's minutes and cost. No step has a time limit: a stuck one
// is seen in the log (a line every 5 min while it runs), never killed; a lock keeps two from overlapping. Every run is measured: its
// steps, and inside them the rehearsal's and the release's phases, for `report`.
// A run holds the machine while it works: ~/.cache/pronto/release-active (RELEASE_ACTIVE names another),
// one line of JSON {"app","pid","started","phase"} with phase slot, rehearse, release or confirm, written
// as the run enters its slot, updated at each step and removed when the run ends, on every outcome and
// on a signal. A file whose pid is gone (kill -0) is stale: readers ignore it and may delete it. A reader
// (an app's tests/slot.ts) starts no new heavy work while it is live and polls every 30 s.
// Its state is ~/.cache/pronto/release-cron/<app>/: the worktree (wt), the lock, the pause, the
// log (release-cron.log, a line a run), last (when the last spaced run ended), runs.jsonl (the same as JSON) and each run's output (runs/).
import { activeLine, base, bisectLine, changed, detail, due, holds, line, local, merges, next, plist, newFeatureNames, introducedBy, untold, probe, report, served, sessionOf, signature, spaced, retry, verdict, whole } from "./cron.js";

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

// Telling a pull request's author: the PR (a comment), a notes file for a session (the author's when the PR
// body names one and its notes folder exists, else the lead's) and a macOS notification, `gh` with the
// machine owner's own login (no GH_TOKEN, GITHUB_TOKEN: under CD the CI job's expiring token). Bisect and the
// new-feature notice both use it.
type Bisect = { lead: string; notes: string };
const prInfo = (slug: string, pr: number) => { try { return JSON.parse(must("env", ["-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", "gh", "pr", "view", String(pr), "-R", slug, "--json", "body,url,title"], undefined, {}, 120)); } catch { return { body: "", url: "", title: "" }; } };
const tellPr = (slug: string, b: Bisect, pr: number, info: { body: string }, msg: string, note: string, toast: string) => {
  const sess = sessionOf(info.body) ?? b.lead;
  const folder = `${home}/${b.notes}/${exists(`${home}/${b.notes}/${sess}`) ? sess : b.lead}`;
  const told: string[] = [];
  if (sh("env", ["-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", "gh", "pr", "comment", String(pr), "--body", `${msg}\n\nPosted by release-cron.`, "-R", slug], undefined, {}, 120).ok) told.push(`PR #${pr} comment`);
  try {
    Deno.mkdirSync(folder, { recursive: true });
    Deno.writeTextFileSync(`${folder}/${note}`, `# release-cron\n\n${msg}\n`);
    told.push(`notes of ${folder.split("/").at(-1)}`);
  } catch { /* a folder that cannot be written is one channel less */ }
  sh("osascript", ["-e", `display notification ${JSON.stringify(toast)} with title "release-cron"`], undefined, {}, 10);
  return told.join(", ");
};

// --- Bisect: `bisect [--dry] [<run's start>]` names the commit that broke a failed run. ---
// Apart from the run and its hold on the machine: its own process (started by a failed run as it
// ends, or by hand), one at a time (bisect/lock), its own checkout (bisect/wt, never the run's wt).
// Each commit between the last run that released and the failed one is read from the records
// first (rehearsals, releases, and the verdicts of earlier bisects); the failing check is run only
// on a commit none of them covers, in the middle of what is left, as a plain claim on the machine's
// slots (the app's tests/slot.ts, waiting for release-active like any job). It never releases.
// `--dry` reads the records and says what it would run, running nothing and writing nothing.
if (verb === "bisect") {
  const dry = Deno.args.includes("--dry");
  const quiet = Deno.args.includes("--no-notify"); // checks run and recorded, nobody told (to try it)
  const only = Deno.args.slice(2).find((a) => !a.startsWith("--"));
  const dir = `${state}/bisect`;
  const bwt = `${dir}/wt`;
  Deno.mkdirSync(dir, { recursive: true });
  const say = (s: string) => console.log(`bisect: ${s}`);
  const runs = jsonl(`${state}/runs.jsonl`);
  const bisects = jsonl(`${dir}/bisects.jsonl`);
  // The oldest failed run since the last release not yet bisected: each failed run of a streak is
  // bisected in its turn, on the verdicts the ones before it settled, so a culprit the next run fails on too shows twice.
  const since = runs.slice(runs.findLastIndex((r) => r.outcome === "released") + 1);
  const failed = only ? runs.find((r) => r.started === only) : since.find((r) => r.outcome === "failed" && r.commit && !bisects.some((b) => b.of === r.started));
  if (!failed) { say("no failed run unbisected"); Deno.exit(0); }
  const at = runs.indexOf(failed);
  const green = runs.slice(0, at).filter((r) => r.outcome === "released" && r.commit).at(-1);
  if (runs.slice(at + 1).some((r) => r.outcome === "released")) { say(`run ${failed.started} was followed by a release: nothing to bisect`); Deno.exit(0); }
  if (!green) { say(`no run released before ${failed.started}: no good commit to start from`); Deno.exit(0); }
  // One bisect at a time: a lock directory holding the pid, a dead holder's taken over.
  if (!dry) {
    // The lock is a file holding the pid, made whole by link(2) (it exists with its content or not at
    // all). A live holder's keeps; a dead holder's is removed only if it is still that pid's, then taken.
    const lock = `${dir}/lock`, tmp = `${dir}/lock.${Deno.pid}`;
    Deno.writeTextFileSync(tmp, String(Deno.pid));
    const take = () => { try { Deno.linkSync(tmp, lock); return true; } catch { return false; } };
    const holder = () => { try { return Number(Deno.readTextFileSync(lock)); } catch { return 0; } };
    let ok = take();
    if (!ok) {
      const pid = holder();
      if (pid && sh("kill", ["-0", String(pid)]).ok) { Deno.removeSync(tmp); say(`bisect ${pid} still going`); Deno.exit(0); }
      if (holder() === pid) { try { Deno.removeSync(lock); } catch { /* another took it */ } }
      ok = take();
    }
    Deno.removeSync(tmp);
    if (!ok) { say("another bisect took the lock"); Deno.exit(0); }
  }
  const unlock = () => { try { if (Deno.readTextFileSync(`${dir}/lock`) === String(Deno.pid)) Deno.removeSync(`${dir}/lock`); } catch { /* none, or not ours */ } };
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], here);
  must("git", ["--git-dir", repo, "fetch", "-q", "origin"]);
  const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
  const { gcp: g, cron } = config(top);
  const gcpName = g.name as string;
  const b = cron.bisect;
  const text = (() => { try { return Deno.readTextFileSync(`${state}/runs/${failed.started}.log`); } catch { return ""; } })();
  const sig = signature(failed.why, text);
  type Merge = { sha: string; subject: string; pr: number | null; branch: string | null };
  const list: Merge[] = merges(must("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H %s", `${green.commit}..${failed.commit}`]).split("\n"));
  say(`${failed.started} failed on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}); last release ${green.commit.slice(0, 8)}; ${list.length} merges between`);
  const home_ = (f: string) => `${home}/.cache/pronto/${f}`;
  const evidence = () => ({ rehearsals: jsonl(home_(`rehearsals/${app}.jsonl`)), releases: jsonl(home_(`releases/${gcpName}.jsonl`)), ledger: jsonl(`${dir}/verdicts.jsonl`) });
  const known: Record<string, string> = {};
  const settle = () => { const ev = evidence(); for (const c of list) known[c.sha] ??= "unknown"; for (const c of list) if (known[c.sha] === "unknown") known[c.sha] = verdict(c.sha, sig, ev); known[list.at(-1)!.sha] = "bad"; };
  if (!list.length) { say("no merge between: nothing to bisect"); unlock(); Deno.exit(0); }
  settle();
  const fromRecords = list.filter((c) => known[c.sha] !== "unknown").length;
  let ran = 0, step = next(list, known), why = "";
  const verdicts = (sha: string, v: string) => Deno.writeTextFileSync(`${dir}/verdicts.jsonl`, JSON.stringify({ commit: sha, kind: sig.kind, names: sig.names, verdict: v, at: new Date().toISOString() }) + "\n", { append: true });
  // The failing check on a commit's tree: ONLY the failed scenarios, slowed as the rehearsal runs
  // them, in its own process group, with no time limit (a line every 5 minutes says it is still running).
  // A signal stops the check's group (TERM, then KILL after 30 s) and gives the lock back first, so a
  // later bisect never finds the checkout under a check still running.
  let group = 0;
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    Deno.addSignalListener(signal, async () => {
      if (group) {
        sh("kill", ["-TERM", "--", `-${group}`], undefined, {}, 10);
        for (const t = Date.now(); sh("kill", ["-0", "--", `-${group}`], undefined, {}, 10).ok && Date.now() - t < 30_000;) await new Promise((r) => setTimeout(r, 1000));
        sh("kill", ["-KILL", "--", `-${group}`], undefined, {}, 10);
      }
      unlock();
      Deno.exit(130);
    });
  }
  const check = async (sha: string) => {
    const repoWt = exists(`${bwt}/.git`);
    if (!repoWt) must("git", ["--git-dir", repo, "worktree", "add", "-q", "--detach", bwt, sha]);
    must("git", ["checkout", "-q", "--detach", "-f", sha], bwt);
    must("git", ["clean", "-ffdq"], bwt);
    sh(mise, ["trust", "-q", `${bwt}/${appRel}/.mise.toml`]);
    const env: Record<string, string> = { ...Deno.env.toObject(), SLOW: "1", INTEGRATE_LOCAL_DRIVERS: "all", STACK_WAIT_MINUTES: "525600", ...(sig.names.length ? { ONLY: sig.names.join(",") } : {}) };
    delete env.STACK_PRIORITY;
    const logf = `${dir}/${sha.slice(0, 8)}.log`;
    const p = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", "sh", "-c", b.command], cwd: `${bwt}/${appRel}`, env, clearEnv: true, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
    group = p.pid;
    const t0 = Date.now();
    const beat = setInterval(() => say(`${sha.slice(0, 8)}: check still running, ${Math.round((Date.now() - t0) / 60_000)} min`), 5 * 60_000);
    const f = Deno.openSync(logf, { write: true, create: true, truncate: true });
    await Promise.all([p.stdout, p.stderr].map(async (s) => { for await (const c of s) f.writeSync(c); }));
    f.close();
    const { code } = await p.status;
    clearInterval(beat);
    group = 0;
    return code === 0 ? "good" : "bad";
  };
  // A release failure shows in the cloud (the rc preview): the check must fail here on the failing
  // commit too (an explicit failure: a pass or a timeout is not), or there is nothing to bisect
  // with, and the range is told as it stands. The failing commit's own ledger verdict stands for it.
  let reproduced = true;
  if (!dry && sig.kind === "release") {
    const failing = list.at(-1)!.sha;
    const same = (r: { commit: string; kind: string; names?: string[] }) => r.commit === failing && r.kind === sig.kind && (r.names ?? []).join(",") === sig.names.join(",");
    const mine = jsonl(`${dir}/verdicts.jsonl`).filter(same).at(-1)?.verdict;
    let v = mine;
    if (!v) {
      say(`running the failing commit ${failing.slice(0, 8)} first: the check must fail here too`);
      v = await check(failing);
      ran++;
      verdicts(failing, v);
    }
    reproduced = v === "bad";
    if (!reproduced) { why = `the check ${v === "good" ? "passes" : "did not finish"} here on the failing commit: a failure only the cloud shows, not bisected`; step = { range: list }; }
  }
  if (!dry && reproduced) {
    for (; "test" in step; step = next(list, known)) {
      say(`running ${(step.test as { sha: string }).sha.slice(0, 8)} (${sig.names.length ? `ONLY=${sig.names.join(",")}` : "the whole check"})`);
      const v = await check((step.test as { sha: string }).sha);
      ran++;
      known[(step.test as { sha: string }).sha] = v;
      verdicts((step.test as { sha: string }).sha, v);
      say(`${(step.test as { sha: string }).sha.slice(0, 8)}: ${v}`);
    }
  } else if ("test" in step) {
    // What the records leave: the commits the search would test, each answered "bad" to show the bound.
    const plan: string[] = [];
    const copy = { ...known };
    for (let s = step; "test" in s && plan.length < 8; s = next(list, copy)) { const t = s.test as { sha: string; pr: number | null }; plan.push(`${t.sha.slice(0, 8)}${t.pr ? ` (#${t.pr})` : ""}`); copy[t.sha] = "bad"; }
    say(`records cover ${fromRecords} of ${list.length}; would run the check (${sig.names.length ? `ONLY=${sig.names.join(",")}` : "whole"}, SLOW=1) on ${plan[0]} first, about ${Math.ceil(Math.log2(list.length))} checks at most (if each said bad: ${plan.join(", ")})`);
  }
  const result: Record<string, unknown> = { of: failed.started, kind: sig.kind, names: sig.names, green: green.commit, failing: failed.commit, ran, fromRecords, ...(why ? { why } : {}) };
  if ("culprit" in step) {
    const c = step.culprit as { sha: string; pr: number | null; branch: string | null; subject: string };
    Object.assign(result, { culprit: c.sha, pr: c.pr, branch: c.branch, subject: c.subject });
    say(`culprit ${c.sha.slice(0, 8)} ${c.subject}`);
  } else if ("range" in step) {
    result.range = (step.range as { sha: string }[]).map((c) => c.sha);
    say(`narrowed to ${(step.range as { sha: string; pr: number | null }[]).map((c) => `${c.sha.slice(0, 8)}${c.pr ? ` (#${c.pr})` : ""}`).join(", ")}`);
  }
  if (dry) { say("dry: nothing run, told or written"); Deno.exit(0); }

  // Told, once per culprit: the pull request (a comment) and a session (a notes file the session
  // reads: the author's when the PR body names one, else the lead's), and a macOS notification.
  const prior = bisects;
  const said = prior.some((x) => x.culprit && x.culprit === result.culprit && x.notified);
  if (!result.culprit && result.range && !quiet) {
    const folder = `${home}/${b.notes}/${b.lead}`;
    try {
      Deno.mkdirSync(folder, { recursive: true });
      Deno.writeTextFileSync(`${folder}/release-cron-bisect-${failed.started.replace(/[^0-9A-Za-z-]/g, "")}.md`, `# release-cron bisect\n\nrelease-cron (${app}) failed ${failed.started} on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}). Bisect: ${why || "no commit left to test"}. The culprit is one of: ${list.filter((c) => (result.range as string[]).includes(c.sha)).map((c) => `${c.sha.slice(0, 8)}${c.pr ? ` #${c.pr} ${c.branch}` : ""}`).join(", ")}. Log: ${state}/runs/${failed.started}.log\n`);
      result.notified = `notes of ${b.lead}`;
    } catch { /* a folder that cannot be written is one channel less */ }
  }
  if (result.culprit && result.pr && !said && !quiet) {
    const info = prInfo(slug, result.pr as number);
    const msg = `release-cron (${app}) failed ${failed.started} on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}). Bisecting main since the last release ${green.commit.slice(0, 8)} names ${(result.culprit as string).slice(0, 8)}, PR #${result.pr} (${result.branch}) ${info.title}. ${ran} checks run, ${fromRecords} commits settled by records. Bisect only reports; nothing is reverted. Log: ${state}/runs/${failed.started}.log`;
    result.notified = tellPr(slug, b, result.pr as number, info, msg, `release-cron-bisect-${failed.started.replace(/[^0-9A-Za-z-]/g, "")}.md`, `PR #${result.pr} (${result.branch}) broke release-cron ${app}`);
  }
  Deno.writeTextFileSync(`${dir}/bisects.jsonl`, JSON.stringify(result) + "\n", { append: true });
  // In runs.jsonl beside the runs, for `report`; its own outcome, which no rule of the schedule reads.
  Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify({ app, started: local(Date.now()), steps: {}, outcome: "bisect", commit: failed.commit, detail: { bisect: result } }) + "\n", { append: true });
  say(bisectLine(result as Parameters<typeof bisectLine>[0]));
  unlock();
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
  console.log(`${label}: a run ${cron.gap} min after the last release, checked every ${cron.poll} min, from ${wt} (main ${head.slice(0, 8)}); no step has a time limit`);
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
let cron: { gap: number; poll: number; watch: string[]; ready: string[]; holder: string; bisect: { lead: string; notes: string }; probes: Record<string, { path: string; agent?: string; status: number; has: string[] }> };
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
  // A failed run starts its bisect as it ends: its own process in its own session (launchd stops a job's
  // process group), after the machine was given back above, so it never holds release-active.
  // Without GH_TOKEN and GITHUB_TOKEN: under CD they are the CI job's read-only token, which expires with
  // the job, and bisect outlives it; `gh` and `git push` then use the machine owner's own gh login.
  const bisectEnv = () => { const e: Record<string, string> = { ...Deno.env.toObject(), RELEASE_CRON_NO_BISECT: "1" }; delete e.GH_TOKEN; delete e.GITHUB_TOKEN; return e; };
  if (outcome === "failed" && run.commit && !Deno.env.get("RELEASE_CRON_NO_BISECT")) {
    try { new Deno.Command("perl", { args: ["-e", "use POSIX; setsid(); exec @ARGV or die $!", "--", Deno.execPath(), "run", "-A", `${here}release-cron.ts`, app, "bisect"], env: bisectEnv(), clearEnv: true, stdin: "null", stdout: "null", stderr: "null" }).spawn().unref(); } catch (e) { say(`bisect not started: ${(e as Error).message}`); }
  }
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
  // A run a CD job starts for a commit (RELEASE_CRON_NOW=1) has no gap to wait: the commit's push is its schedule.
  if (!Deno.env.get("RELEASE_CRON_NOW") && !Number.isNaN(at) && !due(Date.now(), at, Number.isNaN(gap) ? 60 : gap) && !(failed && retry(failed, moved()))) {
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

// A child and everything it started, stopped by a signal: sayt makes a process group of
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
const HEARTBEAT = 5 * 60_000;
const killers: ReturnType<typeof setTimeout>[] = [];
function stop(pgid: number) {
  send(pgid, "TERM");
  killers.push(setTimeout(() => { if (alive(pgid)) send(pgid, "KILL"); }, 60_000));
}
async function child(cmd: string, args: string[], cwd: string, env: Record<string, string>, watch: (l: string) => void = () => {}) {
  const p = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", cmd, ...args], cwd, env, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  current = { pgid: p.pid };
  // No limit: a line every few minutes says it is still running and for how long.
  const beat = setInterval(() => say(`${cmd} ${args.join(" ")}: still running, ${Math.round((Date.now() - t0) / 60_000)} min into the run`), HEARTBEAT);
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
  clearInterval(beat);
  killers.splice(0).forEach(clearTimeout);
  current = undefined;
  return { code };
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

  // 2. The rehearsal: it waits for its slot as long as it takes (the lock keeps another run from starting meanwhile), then runs to its verdict.
  const dir = `${wt}/${appRel}`;
  // With GCP.rehearsal the rehearsal is release@gcp's own, in the cloud: no slot, nothing run here.
  const cloud = !!gcp!.rehearsal;
  if (cloud) say(`GCP.rehearsal: the rehearsal runs in the cloud, job ${gcp!.rehearsal!.job}, inside release@gcp`);
  let got = cloud;
  if (!cloud) active("slot");
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
  const gate = cloud ? { code: 0 } : await child("./saytw", ["verify@local"], dir, { ...Deno.env.toObject(), STACK_WAIT_MINUTES: "525600", STACK_PRIORITY: "release" });
  clearInterval(look);
  // Every check passed already for this tree: the rehearsal took no slot and waited for none.
  if (!got && gate.code === 0) { got = true; step("slot"); active("rehearse"); }
  if (!got) { step("slot"); end("failed", `verify@local ended before its slot (exit ${gate.code}): nothing released`, 1); }
  if (!cloud) step("rehearse");
  if (gate.code !== 0) end("failed", `the rehearsal failed (exit ${gate.code}): nothing released`, 1);

  // 3. The release, on the tree the rehearsal passed.
  active("release");
  let newFailing: string[] = [];
  const rel = await child("./saytw", ["release@gcp"], dir, { ...Deno.env.toObject(), STACK_PRIORITY: "release" }, (l) => { newFailing = [...new Set([...newFailing, ...newFeatureNames(l)])]; });
  step("release");
  if (rel.code !== 0) end("failed", `release@gcp failed (exit ${rel.code})`, 1);
  // pronto's release ships when only new-feature scenarios fail: the run names them, and the PR that added each is told once.
  if (newFailing.length) {
    run.newFailing = newFailing;
    try {
      const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], wt);
      const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
      const green = jsonl(`${state}/runs.jsonl`).filter((r) => r.outcome === "released" && r.commit).at(-1)?.commit as string | undefined;
      const list = merges(must("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H %s", `${green ?? head}..${head}`]).split("\n"));
      const has = (sha: string, name: string) => sh("git", ["--git-dir", repo, "ls-tree", "--name-only", sha, `${appRel}/tests/scenarios/${name}.cue`]).out !== "" || sh("git", ["--git-dir", repo, "grep", "-q", "-F", "-e", name, sha, "--", `${appRel}/tests/scenarios`]).ok;
      const ledger = `${state}/new-feature.jsonl`;
      const found = green ? newFailing.flatMap((name) => {
        const c = introducedBy(list, Object.fromEntries(list.map((m: { sha: string }) => [m.sha, has(m.sha, name)])), has(green, name));
        return c?.pr ? [{ scenario: name, pr: c.pr, branch: c.branch }] : [];
      }) : [];
      for (const f of untold(found, jsonl(ledger))) {
        const info = prInfo(slug, f.pr);
        const msg = `release-cron (${app}) released ${head.slice(0, 8)} although the new scenario ${f.scenario} (added by PR #${f.pr}, ${f.branch}) fails: a release is not held by a new feature's own scenarios. Fix it or take it out. Log: ${state}/runs/${started}.log`;
        const told = tellPr(slug, cron.bisect, f.pr, info, msg, `release-cron-new-feature-${f.scenario.replace(/[^0-9A-Za-z-]/g, "")}.md`, `new scenario ${f.scenario} (PR #${f.pr}) fails in release-cron ${app}`);
        if (told.includes("comment")) Deno.writeTextFileSync(ledger, JSON.stringify({ ...f, told, at: local(Date.now()) }) + "\n", { append: true });
      }
    } catch (e) { say(`new-feature scenarios not told: ${(e as Error).message.split("\n")[0]}`); }
  }

  // 4. Production: the revision taking every request is the one this tree's live record names, the `ready` services are
  // ready, the probes answer. Retried until it is confirmed, as a cache or a cold start settles; no limit, a line every few minutes says what is still wrong.
  active("confirm");
  let said = 0;
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
    if (!wrong.length) break;
    if (Date.now() - said >= HEARTBEAT) { said = Date.now(); say(`confirm: still waiting on production: ${wrong.join("; ")}`); }
    await new Promise((r) => setTimeout(r, 15_000));
  }
  step("confirm");
  if (wrong.length) end("failed", `released, production not confirmed: ${wrong.join("; ")}`, 1);
  // 6. The release's notes (release-notes/release-notes.ts), when the app has them and the revision is new: a GitHub Release
  // tagged <app>/<revision>. Its output is in the run's log; whatever it does, the run's outcome stays.
  if (run.revision !== before && exists(`${dir}/release-notes/release-notes.ts`)) {
    try {
      // Without GH_TOKEN and GITHUB_TOKEN (env -u: child keeps the run's environment): under CD they are
      // the CI job's read-only token, and a Release is written with the machine owner's own gh login.
      const n = await child("env", ["-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", Deno.execPath(), "run", "-A", "release-notes/release-notes.ts", app, "publish", String(run.revision)], dir, Deno.env.toObject());
      run.notes = n.code === 0 ? "published" : `failed (exit ${n.code})`;
    } catch (e) { run.notes = `failed (${(e as Error).message.split("\n")[0]})`; }
    say(`release notes ${run.notes}`);
  }
  // A release that changed nothing Cloud Run runs (tests, config) keeps the revision: said, so it
  // does not read as a deploy that never went out.
  end("released", run.revision === before ? `same image, nothing served changed: ${before} kept` : "");
} catch (e) {
  step("error");
  end("failed", (e as Error).message.split("\n")[0], 1);
}

function exists(p: string) { try { Deno.statSync(p); return true; } catch { return false; } }
