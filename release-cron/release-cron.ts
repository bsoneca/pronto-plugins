// release-cron: an app released to production on a schedule, by launchd on this Mac, from main.
// pronto-plugins' release-cron/README.md says more. Run from the app's folder, where it is written:
//   deno run -A release-cron/release-cron.ts <app> run         one run now (what launchd runs)
//   deno run -A release-cron/release-cron.ts <app> install     the run's worktree and the scheduler's job (releaseCron.scheduler: launchd, systemd or actions)
//   deno run -A release-cron/release-cron.ts <app> uninstall   the scheduler's job gone (the worktree kept)
//   deno run -A release-cron/release-cron.ts <app> pause|resume  runs skip while paused
//   deno run -A release-cron/release-cron.ts <app> status      the job, the pause, the last runs
//   deno run -A release-cron/release-cron.ts <app> report      every release measured, the newest's phases against those before
//   deno run -A release-cron/release-cron.ts <app> bisect [--dry|--no-notify]  the commit that broke the last failed run (a failed run starts it as it ends)
// RELEASE_CRON_REF names the ref a run takes in place of origin/main (a branch's, to try a change to
// this script); RELEASE_CRON_DRY=1 ends a run once it knows whether it would rehearse (RELEASE_CRON_DRY=android runs only the android step, ending dry with its exit code);
// RELEASE_CRON_NOW=1 starts the run without waiting the gap (a CD job's run for the commit it was pushed for).
// An app whose releaseCron has a `target` (aprende, on Cloudflare Pages, with no release.cue) runs
// its own release and serving commands in place of `./saytw release@gcp` and gcloud, and its probes ask the target's origin.
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
import process from "node:process";
import { causes, outcomes } from "./causes.js";
import { appendWhy, mutates, lockAcquire, lockRelease, previewRecordStop, aliveFromKill, rescueReadStep, failureOf, rehearsalSpawn, flagsBookkeeping, nulPaths, lastFields, schedulerEnv, previewProbes, boardEnv, hookArgv, hooksOf, flagsReleasedDue, recordFlagsReleased, channels, systemdUnits, lowPriority, activeLine, base, behind, bisectLine, changed, detail, due, holds, line, local, merges, next, plist, newFeatureNames, flakedNames, changedBy, introducedBy, untold, undecidable, unreproduced, probe, report, served, sessionOf, signature, spaced, retry, landed, rescuable, verdict, releaseModes, rehearsalBase, noVerdictExit, noVerdictRun, besideOutcome, besideTimes, inconclusiveExit, whole, fixedBy, stopsBisect, concerns, failedRehearsal, androidRuns, androidSkip, androidFailed, androidWhy, androidSpawn, endWhenInterrupted, signalStep, servingRetryable, flagsExit } from "./cron.js";
import { hotSql, touched } from "../tests/scenarios/select.ts";
import { readVerdict } from "../tests/scenarios/verdict.ts";

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
const units = `${home}/.config/systemd/user/${label}`;
const uid = decode(new Deno.Command("id", { args: ["-u"], stdout: "piped" }).outputSync().stdout).trim();
Deno.mkdirSync(`${state}/runs`, { recursive: true });

// A command and its output, killed (SIGALRM, which survives exec) past `seconds`: a hung fetch or
// gcloud must not hold the run, and its lock, forever.
const sh = (cmd: string, args: string[], cwd?: string, env: Record<string, string> = {}, seconds = 300) => {
  const o = new Deno.Command("perl", { args: ["-e", "alarm shift; exec @ARGV or die $!", String(seconds), cmd, ...args], cwd, env, stdout: "piped", stderr: "piped" }).outputSync();
  return { ok: o.success, code: o.code, out: decode(o.stdout).trim(), err: decode(o.stderr).trim() };
};
const must = (cmd: string, args: string[], cwd?: string, env: Record<string, string> = {}, seconds = 300) => {
  const r = sh(cmd, args, cwd, env, seconds);
  if (!r.ok) throw new Error(`${cmd} ${args.join(" ")}${cwd ? ` (in ${cwd})` : ""}: ${r.err || r.out}`);
  return r.out;
};
// git's arguments for a call that reaches origin. Under CD the job's runner has no user session, so
// the system's osxkeychain helper fails with -25308 (PRONTO-883): with GH_TOKEN set, a request to https://github.com
// asks no other helper (the scoped empty value resets the list for it, the global one included) and reads the token
// from the environment, never from argv; any other host keeps its own helpers and never receives the token, and
// launchd's run keeps the owner's.
const remote = (args: string[]) => Deno.env.get("GH_TOKEN")
  ? ["-c", "credential.https://github.com.helper=", "-c", 'credential.https://github.com.helper=!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f', ...args]
  : args;

// mise, as the shell finds it or sayt's own (which ./saytw installs): a shell or launchd without it on
// the PATH still finds the app's tools through it.
const mise = sh("sh", ["-c", "command -v mise"]).out || `${home}/Library/Caches/sayt/mise-v2026.8.11/mise`;

if (verb === "pause") { Deno.writeTextFileSync(`${state}/paused`, local(Date.now()) + "\n"); console.log(`${app}: paused; runs skip until \`resume\``); Deno.exit(0); }
if (verb === "resume") { Deno.removeSync(`${state}/paused`); console.log(`${app}: resumed`); Deno.exit(0); }
if (verb === "status") {
  const job = exists(`${units}.timer`) ? sh("systemctl", ["--user", "is-enabled", `${label}.timer`]) : sh("launchctl", ["print", `gui/${uid}/${label}`]);
  console.log(`job ${label}: ${job.ok ? "installed" : "not installed"}${exists(`${state}/paused`) ? ", paused" : ""}`);
  console.log(sh("tail", ["-n", "12", `${state}/release-cron.log`]).out);
  Deno.exit(0);
}
const jsonl = (f: string) => { try { return Deno.readTextFileSync(f).split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
// The lock: a directory (made or not, atomically) holding the run's pid, taken by a run. A lock whose holder is gone is
// taken over; one whose holder lives is busy: launchd never overlaps its own job, and this keeps a run started by hand from overlapping it.
const lockPath = `${state}/lock`;
const errCode = (e: unknown) => (e as { code?: string }).code ?? (e instanceof Deno.errors.AlreadyExists ? "EEXIST" : e instanceof Deno.errors.NotFound ? "ENOENT" : undefined);
const wrap = <T>(f: () => T): T => { try { return f(); } catch (e) { const c = errCode(e); if (c && !(e as { code?: string }).code) (e as { code?: string }).code = c; throw e; } };
const lockIo = {
  pid: Deno.pid,
  uuid: () => crypto.randomUUID(),
  now: () => Date.now(),
  sleep: (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms),
  mkdir: (p: string) => wrap(() => Deno.mkdirSync(p)),
  writeFile: (p: string, t: string) => wrap(() => Deno.writeTextFileSync(p, t)),
  rename: (a: string, b: string) => wrap(() => Deno.renameSync(a, b)),
  readFile: (p: string) => wrap(() => Deno.readTextFileSync(p)),
  stat: (p: string) => wrap(() => { const st = Deno.statSync(p); return { isFile: st.isFile, mtimeMs: st.mtime?.getTime() ?? 0 }; }),
  lstat: (p: string) => wrap(() => { const st = Deno.lstatSync(p); return { isFile: st.isFile, isLink: st.isSymlink, mtimeMs: st.mtime?.getTime() ?? 0 }; }),
  symlink: (target: string, p: string) => wrap(() => Deno.symlinkSync(target, p)),
  readlink: (p: string) => wrap(() => Deno.readLinkSync(p)),
  unlink: (p: string) => wrap(() => Deno.removeSync(p)),
  remove: (p: string) => wrap(() => Deno.removeSync(p, { recursive: true })),
  // kill(pid, 0): ESRCH is a holder that is gone, EPERM one alive under another user, any other error propagates (aliveFromKill).
  alive: (pid: number) => { try { process.kill(pid, 0); return aliveFromKill(null); } catch (e) { return aliveFromKill((e as { code?: string }).code ?? "EUNKNOWN"); } },
  // One recovering run at a time: an exclusive flock on a file of its own, which goes with the process (no stale recovery state to clear).
  recovering: <T>(f: () => T): T => {
    const file = wrap(() => Deno.openSync(`${lockPath}.recover.flock`, { create: true, write: true }));
    try { file.lockSync(true); return f(); } finally { try { file.unlockSync(); } catch { /* closed below */ } file.close(); }
  },
};
let heldStage: string | undefined;
const takeLock = (): { got: true } | { got: false; pid: number } => {
  // A preview record a dead run of the flock version left: a preview may still be running, so the run stops (nonzero) naming the record and
  // what a person does (cron.js previewRecordStop); only no record lets it go on.
  const recPath = `${state}/lock.preview`;
  let recErr: string | null = null, recText = "";
  try { recText = Deno.readTextFileSync(recPath); } catch (e) { recErr = errCode(e) ?? "EUNKNOWN"; }
  const stop = previewRecordStop(recErr, recText, recPath);
  if (stop) throw new Error(stop);
  // Taking is cron.js's lockAcquire: a symlink to a staging directory that already holds this run's pid (symlink(2) refuses anything at the
  // path, an empty directory of the base driver included, and the base driver reads lock/pid through it); a stale lock removed only under an
  // exclusive flock and only if it is still the one observed; a holder that cannot be told, a failure to take or an ambiguous state throws,
  // so the run exits nonzero and a person clears it.
  const got = lockAcquire(lockIo, lockPath);
  if (got.got) heldStage = got.stage;
  return got as { got: true } | { got: false; pid: number };
};
// Gives the lock back (cron.js lockRelease): a lock this run holds and cannot remove throws.
const dropLock = () => { lockRelease(lockIo, lockPath, heldStage); };
if (verb === "report") { console.log(report(jsonl(`${state}/runs.jsonl`))); Deno.exit(0); }
if (verb === "uninstall") {
  // Whichever scheduler installed it: its files say.
  if (exists(`${units}.timer`)) {
    must("systemctl", ["--user", "disable", "--now", `${label}.timer`]);
    for (const f of [`${units}.timer`, `${units}.service`]) { try { Deno.removeSync(f); } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; } }
    must("systemctl", ["--user", "daemon-reload"]);
  } else if (exists(agent)) {
    sh("launchctl", ["bootout", `gui/${uid}/${label}`]);
    Deno.removeSync(agent);
  } else throw new Error(`${label}: no launchd job or systemd timer installed (an app on actions installs nothing)`);
  console.log(`${label}: removed (the worktree ${wt} kept)`);
  Deno.exit(0);
}

// Telling a pull request's author, as releaseCron.notify says (cron.js channels): `none` the log alone, `github-comment` the
// PR (a comment), `claude-session` that, a notes file for a session (the author's when the PR body names one and its notes
// folder exists, else the lead's) and, on a Mac, a notification: `gh` with the run's own
// login: under CD the release job's GH_TOKEN (bsoneca/pronto's cd.yml: pull-requests write), which a runner started
// with SessionCreate needs, since it cannot reach the owner's gh login in the keychain; under launchd the owner's.
// Bisect and the new-feature and flaked notices all use it.
type Notify = { kind: "none" } | { kind: "github-comment" } | { kind: "claude-session"; lead: string; notes: string };
const prInfo = (slug: string, pr: number) => { try { return JSON.parse(must("gh", ["pr", "view", String(pr), "-R", slug, "--json", "body,url,title"], undefined, {}, 120)); } catch { return { body: "", url: "", title: "" }; } };
// A note in the lead's folder, or the session's own: the notes file's folder, the lead's when the session has none.
const writeNote = (n: { lead: string; notes: string }, sess: string, note: string, msg: string, title = "release-cron") => {
  const folder = `${home}/${n.notes}/${exists(`${home}/${n.notes}/${sess}`) ? sess : n.lead}`;
  try {
    Deno.mkdirSync(folder, { recursive: true });
    Deno.writeTextFileSync(`${folder}/${note}`, `# ${title}\n\n${msg}\n`);
    return `notes of ${folder.split("/").at(-1)}`;
  } catch { return ""; /* a folder that cannot be written is one channel less */ }
};
const tellPr = (slug: string, n: Notify, pr: number, info: { body: string }, msg: string, note: string, toast: string) => {
  const via = channels(n, Deno.build.os);
  const told: string[] = [];
  if (via.includes("log")) { console.log(`release-cron: ${msg}`); told.push("logged"); }
  if (via.includes("comment") && sh("gh", ["pr", "comment", String(pr), "--body", `${msg}\n\nPosted by release-cron.`, "-R", slug], undefined, {}, 120).ok) told.push(`PR #${pr} comment`);
  if (via.includes("notes") && n.kind === "claude-session") { const w = writeNote(n, sessionOf(info.body) ?? n.lead, note, msg); if (w) told.push(w); }
  if (via.includes("toast")) sh("osascript", ["-e", `display notification ${JSON.stringify(toast)} with title "release-cron"`], undefined, {}, 10);
  return told.join(", ");
};
// A finding with no pull request to comment on: the lead's notes file, or the log.
const tellNote = (n: Notify, msg: string, note: string, title: string) => {
  if (n.kind === "claude-session") return writeNote(n, n.lead, note, msg, title);
  console.log(`release-cron: ${msg}`);
  return "logged";
};

// --- Bisect: `bisect [--dry] [<run's start>]` names the commit that broke a failed run. ---
// Apart from the run and its hold on the machine: its own process (started by a failed run as it
// ends, or by hand), one at a time (bisect/lock), its own checkout (bisect/wt, never the run's wt).
// Each commit between the last run that released and the failed one is read from the records
// first (rehearsals, releases, and the verdicts of earlier bisects); the failing check is run only
// on a commit none of them covers, in the middle of what is left, as a plain claim on the machine's
// slots (the app's tests/slot.ts, in the pull requests' pool). It never releases, and never holds a
// release up: it runs apart from the run that started it (its own process, never a cd job's), yields to
// any release-cron run that takes the lock (stopping its check, the verdicts so far kept for the next
// bisect), and stops when a later run released or main is green for the failure (cron.js stopsBisect).
// Low priority: the process tree runs under `nice -n 19` and macOS's background QoS (`lowPriority`), so a gate or a release outranks it.
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
  const since = runs.slice(runs.findLastIndex((r) => r.outcome === outcomes.released) + 1);
  const settled = (r: { started: string }) => bisects.some((b) => b.of === r.started);
  const failed = only ? runs.find((r) => r.started === only) : since.find((r) => r.outcome === outcomes.failed && r.commit && !settled(r) && !noVerdictRun(r.why, r.cause));
  if (failed && noVerdictRun(failed.why, failed.cause)) { say(`run ${failed.started} gave no verdict: nothing to bisect`); Deno.exit(0); }
  if (!failed) { say("no failed run unbisected"); Deno.exit(0); }
  const at = runs.indexOf(failed);
  const green = runs.slice(0, at).filter((r) => r.outcome === outcomes.released && r.commit).at(-1);
  if (runs.slice(at + 1).some((r) => r.outcome === outcomes.released)) { say(`run ${failed.started} was followed by a release: nothing to bisect`); Deno.exit(0); }
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
  // The run's lock holder. The run that started this bisect (RELEASE_CRON_BISECT_BY, its pid) lets it go
  // as it ends; any other live holder is a run this bisect yields to, one by hand's too.
  const runHolder = () => { try { return Number(Deno.readTextFileSync(`${state}/lock/pid`)); } catch { return 0; } };
  const starter = Number(Deno.env.get("RELEASE_CRON_BISECT_BY") ?? 0);
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], here);
  must("git", remote(["--git-dir", repo, "fetch", "-q", "origin"]));
  const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
  const { gcp: g, cron } = config(top);
  const gcpName = g?.name as string | undefined;
  const b = cron.bisect;
  const notify = cron.notify;
  const text = (() => { try { return Deno.readTextFileSync(`${state}/runs/${failed.started}.log`); } catch { return ""; } })();
  const sig = signature(failed.why, text, failed.cause);
  type Merge = { sha: string; subject: string; pr: number | null; branch: string | null };
  const list: Merge[] = merges(must("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H %s", `${green.commit}..${failed.commit}`]).split("\n"));
  say(`${failed.started} failed on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}); last release ${green.commit.slice(0, 8)}; ${list.length} merges between`);
  const home_ = (f: string) => `${home}/.cache/pronto/${f}`;
  // The bisect's own verdict ledger is read strictly: only no file is no verdicts; a line that cannot be read stops the
  // bisect (unrecorded), rather than dropping every verdict before it.
  const ledger = () => {
    const f = `${dir}/verdicts.v2.jsonl`;
    let text = "";
    try { text = Deno.readTextFileSync(f); } catch (e) { if (e instanceof Deno.errors.NotFound) return []; say(`${f} could not be read (${e}): the bisect stops`); unlock(); Deno.exit(1); }
    return text.split("\n").filter(Boolean).map((l, i) => { try { return JSON.parse(l); } catch (e) { say(`${f}:${i + 1} could not be read (${e}): the bisect stops`); unlock(); Deno.exit(1); } });
  };
  const evidence = () => ({ strict: releaseModes(cron.rehearsal?.command), rehearsals: jsonl(home_(`rehearsals/${app}.jsonl`)), releases: gcpName ? jsonl(home_(`releases/${gcpName}.jsonl`)) : [], ledger: ledger() });
  const known: Record<string, string> = {};
  const settle = () => { const ev = evidence(); for (const c of list) known[c.sha] ??= "unknown"; for (const c of list) if (known[c.sha] === "unknown") known[c.sha] = verdict(c.sha, sig, ev); known[list.at(-1)!.sha] = "bad"; };
  if (!list.length) { say("no merge between: nothing to bisect"); unlock(); Deno.exit(0); }
  // A failure that flags, time or load decide is not the commit's: say so, bisect nothing.
  // The failed commit's scenarios as its runner reads them (the same CUE export, in the bisect's checkout at that commit),
  // asked only for a named rehearsal failure, the one case undecidable reads them for. A flag counts at any depth: the
  // scenario's flags, or a step's flag or unless. A tree whose scenarios do not export cannot say which failure a flag
  // decides: the bisect stops, recorded, so the next failed run is taken up.
  const specs = (() => {
    if (sig.kind !== "rehearsal" || !sig.names.length) return [];
    // A dry run holds no lock: it never touches the shared checkout, so it does not read the failed commit's scenarios.
    if (dry) { say(`dry run: the scenarios of ${failed.commit.slice(0, 8)} are not read (that needs the bisect's checkout), so whether a flag or time decides ${sig.names.join(", ")} is unknown: no plan, no culprit`); Deno.exit(0); }
    // Recorded and stopped: the scenarios could not be read, or do not say what the failure names.
    const unknown = (what: string): never => {
      const why = `${what}: which failures a flag decides is unknown, the bisect stops, no commit named`;
      say(why);
      Deno.writeTextFileSync(`${dir}/bisects.jsonl`, JSON.stringify({ of: failed.started, kind: sig.kind, names: sig.names, green: green.commit, failing: failed.commit, ran: 0, fromRecords: 0, why }) + "\n", { append: true });
      unlock(); Deno.exit(0);
    };
    if (!exists(`${bwt}/.git`)) must("git", ["--git-dir", repo, "worktree", "add", "-q", "--detach", bwt, failed.commit]);
    must("git", ["checkout", "-q", "--detach", "-f", failed.commit], bwt);
    must("git", ["clean", "-ffdq"], bwt);
    sh(mise, ["trust", "-q", `${bwt}/${appRel}/.mise.toml`]);
    const sdir = `${bwt}/${appRel}/tests/scenarios`;
    let files: string[] = [];
    try { files = [...Deno.readDirSync(sdir)].filter((f) => f.name.endsWith(".cue")).map((f) => `${sdir}/${f.name}`).sort(); } catch (e) { unknown(`${sdir} could not be read (${e})`); }
    if (!files.length) unknown(`${sdir} holds no scenarios`);
    const r = sh(mise, ["x", "--", "cue", "export", ...files, "--out", "json"], `${bwt}/${appRel}`, Deno.env.toObject(), 3600);
    let all: Record<string, { flags?: string[]; slow?: boolean }> | undefined;
    try { all = r.ok ? JSON.parse(r.out).scenarios : undefined; } catch { all = undefined; }
    if (!all) unknown(`the scenarios of ${failed.commit.slice(0, 8)} do not export (${(r.err || r.out).split("\n")[0]})`);
    const missing = sig.names.filter((n) => !(n in all!));
    if (missing.length) unknown(`${failed.commit.slice(0, 8)} has no scenario ${missing.join(", ")}`);
    const flagged = (v: unknown): boolean => Array.isArray(v) ? v.some(flagged) : v !== null && typeof v === "object" ? Object.entries(v).some(([k, x]) => ((k === "flag" || k === "unless" || k === "flags") && (Array.isArray(x) ? x.length > 0 : !!x)) || flagged(x)) : false;
    return Object.entries(all!).map(([id, sc]) => ({ id, flags: flagged(sc), slow: sc.slow === true }));
  })();
  const never = undecidable(sig, text, specs, Deno.loadavg()[0], navigator.hardwareConcurrency, (failed.flaked as string[] | undefined) ?? []);
  if (never) {
    say(never);
    if (!dry) Deno.writeTextFileSync(`${dir}/bisects.jsonl`, JSON.stringify({ of: failed.started, kind: sig.kind, names: sig.names, green: green.commit, failing: failed.commit, ran: 0, fromRecords: 0, why: never }) + "\n", { append: true });
    unlock(); Deno.exit(0);
  }
  settle();
  // Before each check: yield to a run, or stop when a later run released or main went green for it.
  const halt = () => {
    const h = runHolder();
    const after = jsonl(`${state}/runs.jsonl`).slice(at + 1).find((r) => r.outcome === outcomes.released && r.commit);
    sh("git", remote(["--git-dir", repo, "fetch", "-q", "origin"]), undefined, {}, 120);
    const since = (sh("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H", `${failed.commit}..origin/main`], undefined, {}, 60).out ?? "").split("\n").filter(Boolean).reverse();
    return stopsBisect(h, starter, h > 0 && sh("kill", ["-0", String(h)]).ok, after?.commit ?? null, fixedBy(since, sig, evidence()));
  };
  // A yield is not recorded: the next bisect takes the same failed run up, on the verdicts kept.
  const stop = (why: string, record: "yes" | "no" = "yes") => {
    say(why);
    if (record !== "no" && !/yields/.test(why)) Deno.writeTextFileSync(`${dir}/bisects.jsonl`, JSON.stringify({ of: failed.started, kind: sig.kind, names: sig.names, green: green.commit, failing: failed.commit, ran, fromRecords: 0, why }) + "\n", { append: true });
    unlock(); Deno.exit(0);
  };
  const fromRecords = list.filter((c) => known[c.sha] !== "unknown").length;
  let ran = 0, step = next(list, known), why = "";
  // Skipped at the start, not only before a later check: a run holds the lock, a later run released, or main is already green for the failure.
  if (!dry) { const h = halt(); if (h) stop(h); }
  const verdicts = (sha: string, v: string) => Deno.writeTextFileSync(`${dir}/verdicts.v2.jsonl`, JSON.stringify({ commit: sha, kind: sig.kind, names: sig.names, verdict: v, at: new Date().toISOString() }) + "\n", { append: true });
  // The failing check on a commit's tree: ONLY the failed scenarios, slowed as the rehearsal runs
  // them, in its own process group, with no time limit (a line every 5 minutes says it is still running).
  // A signal stops the check's group (TERM, then KILL after 30 s) and gives the lock back first, so a
  // later bisect never finds the checkout under a check still running.
  let group = 0;
  let verdictDir = "";
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    Deno.addSignalListener(signal, async () => {
      if (group) {
        sh("kill", ["-TERM", "--", `-${group}`], undefined, {}, 10);
        for (const t = Date.now(); sh("kill", ["-0", "--", `-${group}`], undefined, {}, 10).ok && Date.now() - t < 30_000;) await new Promise((r) => setTimeout(r, 1000));
        sh("kill", ["-KILL", "--", `-${group}`], undefined, {}, 10);
      }
      if (verdictDir) { try { Deno.removeSync(verdictDir, { recursive: true }); } catch { /* gone */ } }
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
    // verdicts.v2.jsonl: a check now runs its scenarios fresh (SCENARIOS_ALL) and as asked (no inherited ONLY), so a
    // verdict an earlier rule saved is never read again (PRONTO-683).
    // Nothing inherited narrows or hands off the check (ONLY, ONLY_ABSENT, a SCENARIOS_QUEUE another run claims from), and
    // it runs without INTEGRATE_LOCAL_DRIVERS=all, so integrate@local never stamps the tree for a release (tests/slot.ts
    // stamps only in that mode); SLOW=1 and SCENARIOS_ALL=1 are what that mode would have given the scenarios.
    const inherited = Deno.env.toObject();
    // Nor a slot, stack or runner it was started under (STACK_SLOT, STACK_JOB, the stack's URL, GITHUB_ACTIONS, Studio's
    // INTEGRATE_K8S_SLOTTED): the check outlives the job that started it, so tests/slot.ts claims its own weight. Nor Studio's diagnostic STUDIO_K8S_ONLY, which ends integrate@k8s before Publish, nor STUDIO_K8S_CANDIDATE_REF,
    // which would publish another revision than the one checked out.
    // Nor a flag tester's settings (FLAGS_TESTER and the rest, cleared as the rehearsal clears them): the check runs the
    // flags as the stack has them locally.
    for (const k of Object.keys(inherited)) if (/^FLAG/.test(k)) delete inherited[k];
    for (const k of ["ONLY", "ONLY_ABSENT", "SCENARIOS_QUEUE", "SCENARIOS_VERDICT", "INTEGRATE_LOCAL_DRIVERS", "STACK_SLOT", "STACK_JOB", "STACK_WEIGHT", "APP_URL", "ORIGIN", "PRONTO_GATE_DIR", "STUDIO_K8S_ONLY", "STUDIO_K8S_CANDIDATE_REF", "GITHUB_ACTIONS", "INTEGRATE_K8S_SLOTTED"]) delete inherited[k];
    // A named check is judged on the scenarios' own verdict, in a directory of its own (no other user can take its path).
    verdictDir = sig.names.length ? Deno.makeTempDirSync({ prefix: "bisect-verdict." }) : "";
    const env: Record<string, string> = { ...inherited, SLOW: "1", STACK_WAIT_MINUTES: "525600", SCENARIOS_ALL: "1", ...(sig.names.length ? { ONLY: sig.names.join(","), ONLY_ABSENT: "pass", SCENARIOS_VERDICT: `${verdictDir}/verdict.json` } : {}) };
    // SCENARIOS_ALL=1: a named scenario runs whatever an older green record of the same inputs says (release runs no
    // longer refresh the selection cache, so it can be stale for exactly the scenario that failed).
    // ONLY_ABSENT=pass: the harness (cddde28) fails a run whose ONLY names a scenario the tree lacks; an older commit
    // without the failing scenario is no evidence it caused it (PRONTO-778 carries the rest of the bisect's rules).
    delete env.STACK_PRIORITY;
    const logf = `${dir}/${sha.slice(0, 8)}.log`;
    const p = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", ...lowPriority(["sh", "-c", b.command], Deno.build.os)], cwd: `${bwt}/${appRel}`, env, clearEnv: true, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
    group = p.pid;
    const t0 = Date.now();
    const beat = setInterval(() => say(`${sha.slice(0, 8)}: check still running, ${Math.round((Date.now() - t0) / 60_000)} min`), 5 * 60_000);
    // A run that takes the lock mid-check stops the check: its group TERM, then KILL after 30 s.
    let yielded = 0;
    const watch = setInterval(() => {
      const h = runHolder();
      if (yielded || !stopsBisect(h, starter, h > 0 && sh("kill", ["-0", String(h)]).ok, null, null)) return;
      yielded = h;
      sh("kill", ["-TERM", "--", `-${p.pid}`], undefined, {}, 10);
      setTimeout(() => sh("kill", ["-KILL", "--", `-${p.pid}`], undefined, {}, 10), 30_000);
    }, 30_000);
    const f = Deno.openSync(logf, { write: true, create: true, truncate: true });
    // The runner's absence line is kept as the log streams by (a named check only), never by reading the whole log back.
    const absentRe = /scenarios: ONLY names no scenario of this tree \(ONLY_ABSENT=pass\): ([\w,. -]+)/;
    let absentLine = "";
    await Promise.all([p.stdout, p.stderr].map(async (s) => {
      const dec = new TextDecoder();
      let carry = "";
      for await (const c of s) {
        f.writeSync(c);
        if (!sig.names.length || absentLine) continue;
        const lines = (carry + dec.decode(c, { stream: true })).split("\n");
        carry = lines.pop()!.slice(-4096);
        absentLine = lines.map((l) => l.match(absentRe)?.[1]).find(Boolean) ?? "";
      }
      if (sig.names.length && !absentLine) absentLine = carry.match(absentRe)?.[1] ?? "";
    }));
    f.close();
    const { code } = await p.status;
    clearInterval(beat);
    clearInterval(watch);
    group = 0;
    // No file is no verdict; any other read error is the machine's.
    let unread = "";
    const named = sig.names.length ? await readVerdict(`${verdictDir}/verdict.json`).catch((e) => { if (!(e instanceof Deno.errors.NotFound)) unread = String(e); return undefined; }) : undefined;
    if (verdictDir) { Deno.removeSync(verdictDir, { recursive: true }); verdictDir = ""; }
    if (yielded) stop(stopsBisect(yielded, starter, true, null, null)!);
    // A check that ended without judging the commit (killed, no verdict, an unreadable one) leaves the run open for the next
    // bisect, twice; the third such check records the bisect as stopped, so one stuck run never holds back the later ones.
    const inconclusive = (why: string): never => {
      Deno.writeTextFileSync(`${dir}/inconclusive.jsonl`, JSON.stringify({ of: failed.started, commit: sha, why, at: new Date().toISOString() }) + "\n", { append: true });
      // Read strictly: a ledger that cannot be read stops the bisect, recorded, rather than counting as no attempts.
      let tries: { of?: string }[];
      try { tries = Deno.readTextFileSync(`${dir}/inconclusive.jsonl`).split("\n").filter(Boolean).map((l) => JSON.parse(l)); }
      catch (e) { return stop(`${why}; ${dir}/inconclusive.jsonl could not be read (${e}): the bisect stops, no commit named`) as never; }
      if (tries.filter((r) => r.of === failed.started).length >= 3) return stop(`${why}: the third inconclusive check of run ${failed.started}, the bisect stops, no commit named`) as never;
      say(`${why}: the bisect stops unrecorded, to be run again`); unlock(); Deno.exit(1);
    };
    if (unread) inconclusive(`the check on ${sha.slice(0, 8)} left a verdict that could not be read (${unread})`);
    // Every named scenario absent from this tree (ONLY_ABSENT=pass, the runner's line, behind any prefix a log adds): it
    // cannot have failed here.
    const absent = absentLine.split(",").map((n) => n.trim());
    // A named failure is judged by the scenarios' verdict alone: integrate@local also runs Premium and the other suites, so
    // its exit can fail on something that is not the named scenario. With no verdict (a tree older than verdict files, a
    // runner that died) the commit is not judged.
    // Good only when every named scenario this tree has ran here and passed (none skipped, cached or run by another lane).
    if (sig.names.length) {
      // A tree that writes verdicts but left none died before its scenarios ended: the run stays open for the next bisect.
      if (!named && exists(`${bwt}/${appRel}/tests/scenarios/verdict.ts`)) inconclusive(`the check on ${sha.slice(0, 8)} left no scenario verdict`);
      if (!named) stop(`the check on ${sha.slice(0, 8)} left no scenario verdict (its tree writes none): the bisect stops, no commit named`);
      return named!.failedIds.some((id) => sig.names.includes(id)) ? "bad" : named!.failed === 0 && !named!.skipped && !named!.cached && !named!.byOtherLane && named!.passed >= new Set(sig.names.filter((n) => !absent.includes(n))).size ? "good" : stop(`the check on ${sha.slice(0, 8)} did not run ${sig.names.join(", ")} to an end: the bisect stops, no commit named`) as never;
    }
    // An unnamed check killed by a signal or exiting 3 (no verdict) did not judge the commit.
    // Nor did a command the shell could not run (126, 127).
    if (inconclusiveExit(code)) inconclusive(`the check on ${sha.slice(0, 8)} ended without a verdict (exit ${code})`);
    return code === 0 ? "good" : "bad";
  };
  // The check must fail here on the failing commit too (an explicit failure: a pass or a timeout is
  // not), or there is nothing to bisect with. A release failure shows in the cloud (the rc preview),
  // and its range is told as it stands; a rehearsal failure that does not come back came from the
  // run's conditions (a service killed from outside, the machine), and no commit is named. The
  // failing commit's own ledger verdict stands for it.
  let reproduced = true;
  if (!dry) {
    const failing = list.at(-1)!.sha;
    const same = (r: { commit: string; kind: string; names?: string[] }) => r.commit === failing && r.kind === sig.kind && (r.names ?? []).join(",") === sig.names.join(",");
    const mine = ledger().filter(same).at(-1)?.verdict;
    let v = mine;
    if (!v) { const h = halt(); if (h) stop(h); }
    if (!v) {
      say(`running the failing commit ${failing.slice(0, 8)} first: the check must fail here too`);
      v = await check(failing);
      ran++;
      verdicts(failing, v);
    }
    const not = unreproduced(sig.kind, v);
    reproduced = !not;
    if (not) { why = not; step = { range: sig.kind === "release" ? list : [] }; }
  }
  if (!dry && reproduced) {
    for (; "test" in step; step = next(list, known)) {
      { const h = halt(); if (h) stop(h); }
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
  } else if ("range" in step && (step.range as unknown[]).length) {
    result.range = (step.range as { sha: string }[]).map((c) => c.sha);
    say(`narrowed to ${(step.range as { sha: string; pr: number | null }[]).map((c) => `${c.sha.slice(0, 8)}${c.pr ? ` (#${c.pr})` : ""}`).join(", ")}`);
  }
  if (dry) { say("dry: nothing run, told or written"); Deno.exit(0); }

  // Told, once per culprit: the pull request (a comment) and a session (a notes file the session
  // reads: the author's when the PR body names one, else the lead's), and a macOS notification.
  const prior = bisects;
  const said = prior.some((x) => x.culprit && x.culprit === result.culprit && x.notified);
  if (!result.culprit && (result.range || why) && !quiet) {
    result.notified = tellNote(notify, `release-cron (${app}) failed ${failed.started} on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}). Bisect: ${why || "no commit left to test"}. ${result.range ? `The culprit is one of: ${list.filter((c) => (result.range as string[]).includes(c.sha)).map((c) => `${c.sha.slice(0, 8)}${c.pr ? ` #${c.pr} ${c.branch}` : ""}`).join(", ")}.` : "No commit is blamed: look at what else ran on the machine then."} Log: ${state}/runs/${failed.started}.log`, `release-cron-bisect-${failed.started.replace(/[^0-9A-Za-z-]/g, "")}.md`, "release-cron bisect") || undefined;
  }
  if (result.culprit && result.pr && !said && !quiet) {
    const info = prInfo(slug, result.pr as number);
    const msg = `release-cron (${app}) failed ${failed.started} on ${failed.commit.slice(0, 8)} (${sig.kind}${sig.names.length ? `: ${sig.names.join(", ")}` : ""}). Bisecting main since the last release ${green.commit.slice(0, 8)} names ${(result.culprit as string).slice(0, 8)}, PR #${result.pr} (${result.branch}) ${info.title}. ${ran} checks run, ${fromRecords} commits settled by records. Bisect only reports; nothing is reverted. Log: ${state}/runs/${failed.started}.log`;
    result.notified = tellPr(slug, notify, result.pr as number, info, msg, `release-cron-bisect-${failed.started.replace(/[^0-9A-Za-z-]/g, "")}.md`, `PR #${result.pr} (${result.branch}) broke release-cron ${app}`);
  }
  Deno.writeTextFileSync(`${dir}/bisects.jsonl`, JSON.stringify(result) + "\n", { append: true });
  // In runs.jsonl beside the runs, for `report`; its own outcome, which no rule of the schedule reads.
  Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify({ app, started: local(Date.now()), steps: {}, outcome: outcomes.bisect, commit: failed.commit, detail: { bisect: result } }) + "\n", { append: true });
  say(bisectLine(result as Parameters<typeof bisectLine>[0]));
  unlock();
  Deno.exit(0);
}

// The run's worktree, at main: its own checkout, never one a person or a session works in.
const ref = Deno.env.get("RELEASE_CRON_REF") ?? "origin/main";
function worktree() {
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], exists(wt) ? wt : here);
  must("git", remote(["--git-dir", repo, "fetch", "-q", "origin"]));
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
  const registry = Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1];
  // The app's own cue, run through mise there: pronto's runtime puts its memory-budget wrapper first
  // (`mise which cue` names it), and the wrapper finds the real cue on the PATH mise gives it; called by
  // its path from a run's own PATH, it finds none (2026-11-05, pronto gcp.98). Its memory claim is the
  // run's own (STACK_PRIORITY=release), ahead of the pull requests' evaluations in the budget's line.
  const cue = (args: string[]) => must(mise, ["exec", "--", "cue", ...args], appDir, { STACK_PRIORITY: "release", ...(registry ? { CUE_REGISTRY: registry } : {}) }, 900);
  // An app with no GCP in its release.cue, or no release.cue (a releaseCron.target of kind command, as Bonk Chess on its
  // node since PRONTO-205), has no Cloud Run release: only its opt-in is read.
  // release.cue is loaded whenever the app has one, for the facts the cron's steps share with it (an app's node, its kubeconfig:
  // stated once there); its GCP is read only where it declares one.
  const has = exists(`${appDir}/release.cue`);
  const own = has && /^GCP:/m.test(Deno.readTextFileSync(`${appDir}/release.cue`));
  const { gcp, cron } = JSON.parse(cue(["export", ...(has ? ["release.cue"] : []), "release_cron.cue", "release_cron_plugin.cue", "-e", own ? "{gcp: GCP, cron: releaseCron}" : "{cron: releaseCron}", "--out", "json"]));
  if (!gcp && cron.target.kind === "cloud-run") throw new Error(`${appRel} has no GCP in a release.cue and its releaseCron names no target: nothing to release`);
  return { gcp, cron: { ...cron, watch: cron.watch?.length ? cron.watch : [appRel] } };
}

if (verb === "install") {
  // On actions nothing is installed: the app's workflow is the scheduler.
  if (config(top).cron.scheduler.kind === "actions") {
    console.log(`${label}: nothing to install: releaseCron.scheduler is actions, so the app's workflow runs \`release-cron.ts ${app} run\` itself`);
    Deno.exit(0);
  }
  const head = worktree();
  const { cron } = config(wt);
  // The scheduler's environment is bare: the tools the run calls by name are found as the app's mise finds
  // them, and sayt's own mise (which ./saytw installs) is on its PATH for `mise trust`.
  const path = [...new Set([mise.replace(/\/mise$/, ""), `${home}/.local/share/mise/shims`, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])].join(":");
  // gcloud's `pronto` configuration, never this Mac's default one, which is the owner's other work
  // and asks to sign in again where launchd cannot answer (integrate@local's check-secrets).
  const env = { PATH: path, HOME: home, ...schedulerEnv(Deno.env.toObject(), Deno.build.os) };
  const job = { label, program: Deno.execPath(), args: ["run", "-A", `${wt}/${appRel}/release-cron/release-cron.ts`, app, "run"], poll: cron.poll };
  if (cron.scheduler.kind === "systemd") {
    const u = systemdUnits({ ...job, log: `${state}/systemd.log`, env });
    Deno.mkdirSync(`${home}/.config/systemd/user`, { recursive: true });
    Deno.writeTextFileSync(`${units}.service`, u.service);
    Deno.writeTextFileSync(`${units}.timer`, u.timer);
    must("systemctl", ["--user", "daemon-reload"]);
    must("systemctl", ["--user", "enable", "--now", `${label}.timer`]);
  } else {
    Deno.mkdirSync(`${home}/Library/LaunchAgents`, { recursive: true });
    Deno.writeTextFileSync(agent, plist({ ...job, log: `${state}/launchd.log`, env }));
    sh("launchctl", ["bootout", `gui/${uid}/${label}`]);
    must("launchctl", ["bootstrap", `gui/${uid}`, agent]);
  }
  console.log(`${label}: a run ${cron.gap} min after the last release, checked every ${cron.poll} min, from ${wt} (main ${head.slice(0, 8)}); no step has a time limit`);
  Deno.exit(0);
}
if (verb !== "run") throw new Error(`${verb}: run, install, uninstall, pause, resume, status, report or bisect`);

// --- A run. ---
// The script as this process loaded it: a run that finds it changed on main runs main's (below).
const here_ = (f: string) => { try { return Deno.readTextFileSync(`${here}${f}`); } catch { return ""; } };
const loaded = ["release-cron.ts", "cron.js"].map(here_).join("\0");
const t0 = Date.now();
const started = local(t0);
// RELEASE_CRON_DRY: read before any scheduling decision (mutates, cron.js); `android` runs only the android step, ending dry as well.
const dry = Deno.env.get("RELEASE_CRON_DRY");
let out: Deno.FsFile | undefined;
const log = (b: Uint8Array) => (out ??= Deno.openSync(`${state}/runs/${started}.log`, { write: true, create: true, append: true })).writeSync(b);
const enc = new TextEncoder();
const say = (s: string) => { const l = `release-cron: ${Math.round((Date.now() - t0) / 1000)}s ${s}\n`; log(enc.encode(l)); Deno.stdout.writeSync(enc.encode(l)); };
let head = "";
let gcp: { name: string; service: string; project: string; region: string; domain?: string; rehearsal?: { job: string } } | undefined;
type Command = { release: string[]; serving: string[]; servingAfterRelease: boolean; origin: string; preview?: { up: string[]; reach: string[]; down: string[]; origin: string; when?: "after" | "first" | "beside" } };
let cron!: { steps: { prepare: string; slot: string; rehearse: string; android: string; preview: string; beside: string; release: string; confirm: string; error: string }; scheduler: { kind: string }; target: ({ kind: "command" } & Command) | { kind: "cloud-run" }; rehearsal: { command: string[] | null; slot: boolean; holder: string }; android?: { command: string[] }; notify: Notify; hooks: { on: string; command: string[] }[]; flagsReleased: string[] | null; gap: number; poll: number; watch: string[]; ready: string[]; holder: string; bisect: { command: string }; probes: Record<string, { path: string; agent?: string; status: number; has: string[]; location?: string; preview?: false }> };
let before: string | null = null;
const steps: Record<string, number> = {};
let mark = Date.now();
// While the rehearsal and the preview overlap (preview `when: "beside"`) neither is a step of its own: both are the one
// step "rehearse+preview", their wall time, so `report`'s sum of the steps counts the time once.
let overlap = false;
const step = (name: string) => { if (overlap) return; steps[name] = Math.round((Date.now() - mark) / 1000); mark = Date.now(); };
const run: Record<string, unknown> = { app, started, steps };
// The release-active file: written whole to a temporary file then renamed, so a reader never sees half.
const activePath = Deno.env.get("RELEASE_ACTIVE") ?? `${home}/.cache/pronto/release-active`;
const active = (phase: string) => {
  if (overlap) return;
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
// Previews not yet torn down (up to the end of their `down`), and whether a signal has come.
let previews = 0, interrupted = false;
const end = (outcome: string, why = "", code = 0, cause = "") => {
  // After a signal, whatever the run reaches is the stop's doing, not a verdict (cron.js endWhenInterrupted): no gap, no bisect.
  const mapped = endWhenInterrupted(interrupted, outcome);
  if (mapped !== outcome) { why = `${outcome}: ${why}`; outcome = mapped; code = 130; cause = "signal"; }
  // The machine is given back first, whatever the outcome; only a file this run wrote is removed.
  try { if (JSON.parse(Deno.readTextFileSync(activePath)).pid === Deno.pid) Deno.removeSync(activePath); } catch { /* none, or not ours */ }
  Object.assign(run, { outcome, why: why || undefined, ...(cause ? { cause } : {}), ended: local(Date.now()) });
  // Inside the steps: the rehearsal's and the release's own records of this commit, since this run began.
  if (run.commit && (cron && (cron.steps.rehearse in steps || cron.steps.beside in steps || cron.steps.release in steps))) {
    const d = detail(jsonl(`${home}/.cache/pronto/rehearsals/${app}.jsonl`), gcp ? jsonl(`${home}/.cache/pronto/releases/${gcp.name}.jsonl`) : [], run.commit, new Date(t0).toISOString());
    run.detail = d;
    if (d.rehearsal) run.rehearsal = d.rehearsal;
  }
  const l = line(run);
  Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
  Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify(run) + "\n", { append: true });
  // `last`: the end, the gap, the commit it failed on or "-" (retry, cron.js) and the commit it tried (behind, cron.js).
  if (spaced(outcome)) Deno.writeTextFileSync(`${state}/last`, `${Date.now()} ${(run.gap as number | undefined) ?? 60} ${lastFields(outcome, run.commit as string | undefined).join(" ")}`);
  say(l);
  // A failed run starts its bisect as it ends, after the machine was given back above, so it never holds
  // release-active.
  const bisects = outcome === outcomes.failed && !!run.commit && !Deno.env.get("RELEASE_CRON_NO_BISECT");
  // Never in the cd job's foreground, which held pronto-release, and with it every release, for the
  // bisect's hours (2026-11-07 12:12-15:12 BRT): its own process in its own session, run from the run's
  // worktree (the job's checkout is the next job's), `gh` with the owner's login, not the job's token,
  // and out of the runner's reach (an empty RUNNER_TRACKING_ID: the runner ends a job's leftovers by it).
  const bisectEnv = () => {
    const env: Record<string, string> = { ...Deno.env.toObject(), RELEASE_CRON_NO_BISECT: "1", RELEASE_CRON_BISECT_BY: String(Deno.pid), RUNNER_TRACKING_ID: "" };
    delete env.STACK_PRIORITY; // the pull requests' pool, never the release lane
    for (const k of ["GH_TOKEN", "GITHUB_TOKEN", "CLOUDSDK_CONFIG", "GOOGLE_APPLICATION_CREDENTIALS", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "GOOGLE_GHA_CREDS_PATH"]) delete env[k];
    return env;
  };
  const script = exists(`${wt}/${appRel}/release-cron/release-cron.ts`) ? `${wt}/${appRel}/release-cron/release-cron.ts` : `${here}release-cron.ts`;
  if (bisects) {
    try { new Deno.Command("perl", { args: ["-e", "use POSIX; setsid(); exec @ARGV or die $!", "--", ...lowPriority([Deno.execPath(), "run", "-A", script, app, "bisect"], Deno.build.os)], env: bisectEnv(), clearEnv: true, cwd: home, stdin: "null", stdout: "null", stderr: "null" }).spawn().unref(); } catch (e) { say(`bisect not started: ${(e as Error).message}`); }
  }
  // The last 50 runs' output kept.
  const logs = [...Deno.readDirSync(`${state}/runs`)].map((e) => e.name).sort();
  for (const old of logs.slice(0, -50)) Deno.removeSync(`${state}/runs/${old}`);
  dropLock();
  Deno.exit(code);
};

if (exists(`${state}/paused`)) end(outcomes.skipped, "paused");

// The lock (takeLock): a directory holding the run's pid. A lock whose run is gone is
// taken over; one whose run lives means this run skips: launchd never overlaps its own job, and
// this keeps a run started by hand from overlapping it.
{
  const taken = takeLock();
  if (!taken.got) {
    // Logged as any run, but the lock is the other run's: left alone.
    const l = line({ app, started, steps: {}, outcome: outcomes.skipped, why: `run ${taken.pid} still going` });
    Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
    console.log(l);
    Deno.exit(0);
  }
}
const [lastAt, lastGap, lastFailed, lastTried] = (() => { try { const [a, g, f, t] = Deno.readTextFileSync(`${state}/last`).trim().split(" "); return [Number(a), Number(g), f === "-" ? undefined : f, t === undefined ? (f === "-" ? undefined : f) : t === "-" ? undefined : t]; } catch { return [NaN, NaN, undefined, undefined]; } })();

// Not due: the wake ends here, with no line (it was no run). The gap is the config of the tree last
// run, kept beside its end; the first run has none.
{
  const [at, gap, failed] = [lastAt, lastGap, lastFailed];
  // After a failed run, main as the remote has it now (git ls-remote, no fetch): moved past the
  // failed commit by a change that concerns what failed (judged), the run starts without the gap.
  const moved = () => { const r = sh("git", remote(["ls-remote", "origin", "refs/heads/main"]), wt, {}, 60); return r.ok ? r.out.split(/\s/)[0] || null : null; };
  const early = () => { const head = moved(); return !!failed && retry(failed, head) && judged(failed, head!) !== null; };
  // A run a CD job starts for a commit (RELEASE_CRON_NOW=1) has no gap to wait: the commit's push is its schedule.
  if (!Deno.env.get("RELEASE_CRON_NOW") && !Number.isNaN(at) && !due(Date.now(), at, Number.isNaN(gap) ? 60 : gap) && !early()) {
    dropLock();
    Deno.exit(0);
  }
}

// Whether main's change from the failed commit to `head` concerns what failed (cron.js's concerns): the
// first file that does and why, or null, and the run waits the gap. Judged once per failed commit and
// head (kept in <state>/retry), so the wakes in between fetch nothing; said once in launchd.log. A change
// that cannot be fetched or read concerns it (fail open).
function judged(failed: string, head: string): string | null {
  const memo = `${state}/retry`;
  try {
    const [f, h, ...v] = Deno.readTextFileSync(memo).trim().split(" ");
    if (f === failed && h === head) return v.join(" ") === "-" ? null : v.join(" ");
  } catch { /* not judged yet */ }
  const verdict = (() => {
    if (!sh("git", remote(["fetch", "-q", "origin", "main"]), wt, {}, 120).ok) return "main's change could not be fetched";
    const diff = sh("git", ["diff", "--name-only", "-z", "--no-renames", failed, head], wt, {}, 60);
    if (!diff.ok) return "main's change could not be read";
    const run = jsonl(`${state}/runs.jsonl`).reverse().find((r) => r.outcome === outcomes.failed && r.commit === failed);
    const text = (() => { try { return run ? Deno.readTextFileSync(`${state}/runs/${run.started}.log`) : ""; } catch { return ""; } })();
    const sig = signature(run?.why, text, run?.cause as string | undefined), flaked = flakedNames(text);
    const names = sig.names.filter((n) => !flaked.includes(n));
    // A SQL file and the failed scenarios: by what their newest green records touched, at `head`.
    const sqlHot = (file: string) => {
      const ledger = `${home}/.cache/pronto/scenarios/${app}`;
      const served: string[] = [];
      for (const n of names) {
        let newest: { at: number; served: string[] } | undefined;
        try {
          for (const e of Deno.readDirSync(ledger)) {
            if (!e.name.startsWith(`${n}.`)) continue;
            const at = Deno.statSync(`${ledger}/${e.name}`).mtime?.getTime() ?? 0;
            if (!newest || at > newest.at) newest = { at, served: JSON.parse(Deno.readTextFileSync(`${ledger}/${e.name}`)).served ?? [] };
          }
        } catch { return null; }
        if (!newest) return null;
        served.push(...newest.served);
      }
      const listed = sh("git", ["ls-tree", "-r", "--name-only", head, "--", appRel], wt, {}, 60);
      if (!listed.ok) return null;
      const sql: Record<string, string> = {};
      for (const f of listed.out.split("\n").filter((x) => x.endsWith(".sql"))) {
        const t = sh("git", ["show", `${head}:${f}`], wt, {}, 60);
        if (t.ok) sql[f] = t.out;
      }
      const t = touched(served);
      return hotSql(sql, t.names, t.wild).includes(file);
    };
    const c = concerns(nulPaths(diff.out), appRel, { ...sig, names }, failedRehearsal(text), sqlHot);
    return c ? `${c.file}, ${c.why}` : null;
  })();
  Deno.writeTextFileSync(memo, `${failed} ${head} ${verdict ?? "-"}\n`);
  console.log(`${local(Date.now())} ${app}: main moved from the failed ${failed.slice(0, 8)} to ${head.slice(0, 8)}; ${verdict ? `retried without the gap: ${verdict}` : "nothing it changed concerns what failed: the gap is waited"}`);
  return verdict;
}

// The children running now (the rehearsal and the preview's `up` can run side by side), process group -> tag.
const children = new Map<number, string>();
// The ms a stopped child gets before KILL, and a preview's `down` after them (it is tagged "down", never stopped by a signal).
const STOP_GRACE = 60_000, TEARDOWN_GRACE = 300_000;
// Stopped: every child's group stopped and gone (killed after a minute) before the run ends and its
// lock goes, so the next run never starts beside what this one started.
// The lock goes last (signalStep): after the children are gone (bounded) and a preview has finished its `up` and its `down` (not bounded: its remote
// operation is never cut off by a signal).
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  Deno.addSignalListener(signal, async () => {
    if (interrupted) return;
    interrupted = true;
    // The preview's `up` is never stopped (cancel's own rule, previewCheck): killing the local ssh would leave the node running
    // release@k8s while the preview's `down` starts on the same namespace. It runs to its end, the probes are skipped (`interrupted`),
    // `down` runs, and the lock waits for all of it (signalStep).
    const groups = [...children].filter(([, tag]) => tag !== "down" && tag !== "preview").map(([pgid]) => pgid);
    for (const pgid of groups) stop(pgid, STOP_GRACE);
    for (const t = Date.now();;) {
      const s = signalStep(groups.some(alive), previews, Date.now() - t, STOP_GRACE, TEARDOWN_GRACE);
      if (s === "done") break;
      if (s === "kill") for (const pgid of groups) if (alive(pgid)) send(pgid, "KILL");
      await new Promise((r) => setTimeout(r, 1000));
    }
    for (const [pgid, tag] of children) if (tag !== "preview" && alive(pgid)) send(pgid, "KILL");
    end(outcomes.stopped, signal, 130);
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
const killers = new Map<number, ReturnType<typeof setTimeout>>();
// `grace`: ms before KILL. A signal gets a minute; a rehearsal stopped for the preview's failure gets more, so its own teardown
// (rehearse.ts's stacks, integrate@k8s's cluster) can finish.
function stop(pgid: number, grace = 60_000) {
  send(pgid, "TERM");
  killers.set(pgid, setTimeout(() => { if (alive(pgid)) send(pgid, "KILL"); }, grace));
}
// Every running child that carries `tag` stopped (the loser of the rehearsal and preview's race).
const stopTagged = (tag: string, grace?: number) => { for (const [pgid, t] of children) if (t === tag) stop(pgid, grace); };
async function child(cmd: string, args: string[], cwd: string, env: Record<string, string>, watch: (l: string) => void = () => {}, tag = "", clearEnv = false) {
  // Nothing new starts once a signal came, but the preview's `down`, which the handler waits for.
  if (interrupted && tag !== "down") throw new Error(causes.signal);
  const p = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", cmd, ...args], cwd, env, clearEnv, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  children.set(p.pid, tag);
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
  clearTimeout(killers.get(p.pid));
  killers.delete(p.pid);
  children.delete(p.pid);
  return { code };
}

// The release preview (releaseCron.target.preview): the release's whole stack in a namespace of its own on the
// cluster, asked the probes through a port-forward before the release goes ahead, and removed after, whatever it
// said. It proves the images, the migrations replayed over a fresh database and the config on the node before
// any traffic moves. Returns what failed (none: it answered every probe). `cancel.stopped` ends it early (the
// rehearsal beside it failed first): `up` is never cancelled (stopping it would only kill the local ssh, leaving the remote
// release running while `down` starts in the same worktree), so it runs to its end (Bonk Chess's ends with the kill rehearsal);
// the waits and probes after it are skipped, and `down` runs. A failed `down` is always logged.
async function previewCheck(pv: NonNullable<Command["preview"]>, dir: string, cancel: { stopped: boolean }): Promise<string[]> {
  const env = { ...Deno.env.toObject(), STACK_PRIORITY: "release" };
  const bad: string[] = [];
  let reach: Deno.ChildProcess | undefined;
  previews++;
  // A signal ends the preview as `cancel` does: its `down` still runs, and the run's lock waits for it.
  const stopped = () => cancel.stopped || interrupted;
  try {
    const up = await child(pv.up[0], pv.up.slice(1), dir, env, undefined, "preview");
    if (up.code !== 0) bad.push(`the preview (${pv.up.join(" ")}) failed (exit ${up.code})`);
    else if (!stopped()) {
      // In a process group of its own, so ending it ends the ssh forward and what it started; its stdin stays open (nothing
      // is written to it), which is how the remote side knows to stop: it reads it until the connection closes.
      reach = new Deno.Command("perl", { args: ["-e", "setpgrp(0,0); exec @ARGV or die $!", "--", ...pv.reach], cwd: dir, env, stdin: "piped", stdout: "null", stderr: "null" }).spawn();
      // Answering through the forward: `/` is asked until it answers (the forward takes a moment, as a cold pod's first page does).
      // A forward that exits first (the ssh dropped, the remote port-forward ended) fails the preview: waiting on would hold
      // the app's release lock for ever.
      let gone: Deno.CommandStatus | undefined;
      reach.status.then((s) => { gone = s; });
      let said2 = 0;
      for (;;) {
        if (stopped()) break;
        try { const r = await fetch(pv.origin + "/", { signal: AbortSignal.timeout(15_000) }); await r.body?.cancel(); if (r.status < 500) break; } catch { /* not up yet */ }
        if (gone) { bad.push(`the preview's forward (${pv.reach.join(" ")}) exited (code ${gone.code}) before ${pv.origin} answered`); break; }
        if (Date.now() - said2 >= HEARTBEAT) { said2 = Date.now(); say(`preview: still waiting for ${pv.origin}`); }
        await new Promise((r) => setTimeout(r, 5_000));
      }
      // A forward that never bound (ExitOnForwardFailure on a port something else holds) has exited by now: what answered was
      // that other listener, not the preview.
      if (!bad.length && gone) bad.push(`the preview's forward (${pv.reach.join(" ")}) exited (code ${gone.code}): what answered on ${pv.origin} was not the preview`);
      if (!bad.length) for (const [name, p] of previewProbes(cron.probes)) {
        if (stopped()) break;
        try {
          const r = await fetch(`${pv.origin}${p.path}`, { headers: p.agent ? { "User-Agent": p.agent } : {}, redirect: p.location ? "manual" : "follow", signal: AbortSignal.timeout(60_000) });
          const v = probe(p, r.status, await r.text(), r.headers.get("location"));
          if (v) bad.push(`${name} ${v}`);
        } catch (e) { bad.push(`${name} ${p.path}: ${(e as Error).message}`); }
      }
    }
    // Stopped by a signal before its checks ran: no pass to read (a race loser's cancel is no failure).
    if (interrupted && !bad.length) bad.push(causes.signal);
  } finally {
    if (reach) { try { send(reach.pid, "TERM"); await reach.stdin.close().catch(() => {}); } catch { /* already gone */ } }
    let down: { code: number };
    try { down = await child(pv.down[0], pv.down.slice(1), dir, env, undefined, "down"); } finally { previews--; }
    // A preview left standing fails the run before the release: its namespace and what runs there stay until someone
    // removes them, which a run that reads as released would hide.
    if (down.code !== 0) { const m = `removing the preview (${pv.down.join(" ")}) failed (exit ${down.code})`; bad.push(m); say(`preview: ${m}`); }
  }
  return bad;
}
const sayPreview = (bad: string[]) => say(bad.length ? `preview failed: ${bad.join("; ")}` : "preview answered every probe");

const gcloud = (args: string[], seconds = 120) => must("gcloud", [...args, "--project", gcp!.project, "--region", gcp!.region, "--format=json"], undefined, {}, seconds);
try {
  // 1. Main, its config, the commit serving.
  head = worktree();
  run.commit = head;
  // Never backwards: a ref older than the commit the last run tried (CD's newest finished ci can be
  // one, when newer runs were cancelled) would meet again what main has since fixed. Not a spaced run.
  // A `last` from before this field names it only for a failed run: runs.jsonl has the other.
  const tried = lastTried ?? jsonl(`${state}/runs.jsonl`).filter((x) => spaced(x.outcome)).at(-1)?.commit;
  if (tried && behind(sh("git", ["merge-base", "--is-ancestor", head, tried], wt).ok, head, tried)) end(outcomes.skipped, `${head.slice(0, 8)} is behind ${tried.slice(0, 8)}, which the last run tried`);
  // launchd runs the worktree's script, loaded before the worktree moved to main: when main changed
  // it, this run hands over to main's, which takes the lock and goes on, so a merged fix applies to
  // the next run, not the one after. RELEASE_CRON_AGAIN keeps it to one hand-over.
  if (here.startsWith(wt) && !Deno.env.get("RELEASE_CRON_AGAIN") && ["release-cron.ts", "cron.js"].map(here_).join("\0") !== loaded) {
    say("the script changed on main: running main's");
    dropLock();
    const again = await new Deno.Command(Deno.execPath(), { args: ["run", "-A", `${here}release-cron.ts`, ...Deno.args], env: { RELEASE_CRON_AGAIN: "1" }, stdin: "null", stdout: "inherit", stderr: "inherit" }).spawn().status;
    Deno.exit(again.code);
  }
  ({ gcp, cron } = config(wt));
  run.gap = cron.gap;
  // What production serves: the commit the target's serving command prints, else Cloud Run's traffic.
  const target = cron.target.kind === "command" ? cron.target : undefined;
  // Read over ssh: a transport failure (exit 255, a connect that timed out, PRONTO-758, 07:05 BRT) is tried twice more, 20 s apart, before
  // it fails the run; any other failure fails it at once, with its exit status and stderr (servingRetryable).
  const servingNow = () => {
    for (let i = 1; ; i++) {
      const r = sh(target!.serving[0], target!.serving.slice(1), `${wt}/${appRel}`, Deno.env.toObject(), 120);
      if (r.ok) return r.out.split(/\s+/)[0];
      const why = `${target!.serving.join(" ")} failed (exit ${r.code}): ${r.err || r.out}`;
      if (i >= 3 || !servingRetryable(r.code)) throw Object.assign(new Error(why), { exit: r.code, permanent: !servingRetryable(r.code) });
      say(`serving unread (try ${i} of 3): ${why.split("\n").at(-1)}`); sh("sleep", ["20"], undefined, {}, 30);
    }
  };
  before = target ? servingNow() : whole(JSON.parse(gcloud(["run", "services", "describe", gcp!.service])).status?.traffic);
  const live = target ? (sh("git", ["cat-file", "-e", `${before}^{commit}`], wt).ok ? before : undefined) : base(jsonl(`${state}/runs.jsonl`), before);
  step(cron.steps.prepare);
  if (live === head) {
    if (mutates(dry)) run.flagsReleased = await flagsReleased(`${wt}/${appRel}`, true) ?? undefined;
    // The marker is written again here when an earlier write failed (flagsReleasedDue), without a deploy; a write that fails again is the job's nonzero exit.
    end(outcomes.skipped, `main ${head.slice(0, 8)} is serving as ${before}${mutates(dry) ? "" : "; flags not recorded (RELEASE_CRON_DRY)"}${flagsExit(run.flagsReleased as string | undefined) ? `; flags bookkeeping ${run.flagsReleased}` : ""}`, flagsExit(run.flagsReleased as string | undefined));
  }
  if (live) {
    const diff = sh("git", ["diff", "--name-only", "-z", live, head], wt);
    if (diff.ok && !changed(nulPaths(diff.out), cron.watch).length) end(outcomes.skipped, `nothing under ${cron.watch.join(", ")} changed since ${live.slice(0, 8)}, released by a run and serving as ${before}`);
  }
  // RELEASE_CRON_DRY=android runs only the android step below, in place of the rehearsal and the preview.
  if (dry && dry !== "android") end(outcomes.dry, `would rehearse and release ${head.slice(0, 8)}: it differs from ${live?.slice(0, 8) ?? "an unknown commit"}, serving as ${before}`);
  say(`${head.slice(0, 8)} differs from what serves (${live ? live.slice(0, 8) : `unknown: no run that released confirmed ${before}`}): rehearsing`);

  const dir = `${wt}/${appRel}`;
  // 2. The rehearsal: it waits for its slot as long as it takes (the lock keeps another run from starting meanwhile), then runs to its verdict.
  // With GCP.rehearsal the rehearsal is release@gcp's own, in the cloud: no slot, nothing run here. A rehearsal.command of
  // null is none at all; rehearsal.slot false runs the command without waiting for a slot.
  const cloud = !!gcp?.rehearsal;
  const rehearse = cron.rehearsal.command;
  const own = !cloud && !!rehearse;
  const wantSlot = own && cron.rehearsal.slot && !dry;
  if (cloud) say(`GCP.rehearsal: the rehearsal runs in the cloud, job ${gcp!.rehearsal!.job}, inside release@gcp`);
  else if (!rehearse) say("no rehearsal: releaseCron.rehearsal.command is null");
  let newFailing: string[] = [];
  let flaked: string[] = [];
  // The rehearsal to its verdict: its slot waited for, then the command run. `got`: whether the slot was taken (or none was wanted).
  const rehearsalRun = async () => {
    let got = !wantSlot;
    // When the claim began and when the slot admitted it (no slot wanted: at once), for a beside run's `slot` (besideTimes).
    const began = Date.now();
    let admitted: number | null = got ? began : null;
    if (wantSlot) active("slot");
    else if (own && !dry) { step(cron.steps.slot); active("rehearse"); say("rehearsal.slot is false: run without waiting for a slot"); }
    // The slot is taken once a live slot of the pool names this rehearsal as its owner.
    const pool = Deno.env.get("STACK_POOL") ?? "/tmp/pronto-stacks";
    const look = setInterval(() => {
      if (got) return;
      for (const e of (() => { try { return [...Deno.readDirSync(pool)]; } catch { return []; } })()) {
        if (!/^slot-\d+$/.test(e.name)) continue;
        const owner = (() => { try { return Deno.readTextFileSync(`${pool}/${e.name}/owner`); } catch { return ""; } })();
        const pid = (() => { try { return Deno.readTextFileSync(`${pool}/${e.name}/pid`).trim(); } catch { return ""; } })();
        // The holder alive and started by this run: not a slot a dead or stray rehearsal left.
        const ours = pid && [...children.keys()].some((g) => tree(g).pids.includes(Number(pid)));
        if (ours && holds(owner, dir, cron.rehearsal.holder) && owner.startsWith(`${pid} `)) { got = true; admitted = Date.now(); step(cron.steps.slot); active("rehearse"); say(`slot taken: ${e.name}`); return; }
      }
    }, 5000);
    // STACK_PRIORITY=release puts its claim at the head of the pool's line, ahead of every claim a
    // pull request's gate or a launch is waiting with (tests/slot.ts).
    // The rehearsal's own output names the new-feature scenarios it passed on and the ones that flaked on their one retry.
    // What serves is read when the rehearsal is started, before its slot wait (rehearsalBase): once, 20 s at most, no retries; a failed
    // read is unknown. A wait for the slot, or a preview beside it, can still outlast it.
    const readLive = (() => { if (!target || !own || dry) return live; const r = sh(target.serving[0], target.serving.slice(1), `${wt}/${appRel}`, Deno.env.toObject(), 20); const c = r.ok ? r.out.split(/\s+/)[0] : ""; return c && sh("git", ["cat-file", "-e", `${c}^{commit}`], wt).ok ? c : undefined; })();
    const base0 = rehearsalBase(readLive, live, head);
    if (base0.moved) say(`production moved since this run read it: ${live?.slice(0, 8)} then, ${base0.live?.slice(0, 8)} now; the rehearsal takes ${base0.live?.slice(0, 8)} as its baseline`);
    const spawn = rehearsalSpawn(Deno.env.toObject(), base0.live, !!target, base0.rehearsed);
    const gate = !own || dry ? { code: 0 } : await child(rehearse![0], rehearse!.slice(1), dir, spawn.env, (l) => { newFailing = [...new Set([...newFailing, ...newFeatureNames(l)])]; flaked = [...new Set([...flaked, ...flakedNames(l)])]; }, "rehearsal", spawn.clearEnv);
    clearInterval(look);
    // Every check passed already for this tree: the rehearsal took no slot and waited for none.
    if (!got && gate.code === 0) { got = true; admitted = began; step(cron.steps.slot); active("rehearse"); }
    return { gate, got, began, admitted };
  };
  // The preview's `when` (schema.cue): "after" runs below, once the rehearsal and the android step passed; "first" here, before
  // the rehearsal's slot; "beside" at the same time as the rehearsal, the first to fail stopping the other. RELEASE_CRON_DRY=android
  // runs neither.
  const pv = target?.preview;
  const when = pv ? pv.when ?? "after" : "after";
  if (pv && when === "first" && !dry) {
    active("preview");
    const bad = await previewCheck(pv, dir, { stopped: false });
    step(cron.steps.preview);
    sayPreview(bad);
    if (bad.length) { const f = failureOf("previewFailed", { bad, stopped: false }); end(outcomes.failed, f.why, 1, f.cause); }
  }
  const beside = !!pv && when === "beside" && !dry;
  let outcome: Awaited<ReturnType<typeof rehearsalRun>>;
  let downFailed = "";
  if (beside) {
    active(cron.steps.beside);
    overlap = true;
    const t = Date.now();
    const cancel = { stopped: false };
    const race: { r?: { code: number; at: number }; p?: { bad: string[]; at: number } } = {};
    let rehearsalStopped = false;
    let rehearsalResult: Awaited<ReturnType<typeof rehearsalRun>> | undefined;
    // Once one has ended, the other is stopped when that is the verdict (cron.js besideOutcome).
    const decide = () => {
      const o = besideOutcome(race.r ?? null, race.p ?? null);
      if (o.stop === "preview") { cancel.stopped = true; say(`${o.why}`); }
      if (o.stop === "rehearsal") { rehearsalStopped = true; stopTagged("rehearsal", TEARDOWN_GRACE); say(`${o.why}`); }
    };
    const rP = rehearsalRun().then((x) => { rehearsalResult = x; race.r = { code: x.gate.code, at: Date.now() - t }; decide(); });
    const pP = previewCheck(pv!, dir, cancel).then((bad) => { race.p = { bad, at: Date.now() - t }; decide(); });
    try {
      await Promise.all([rP, pP]);
    } catch (e) {
      // One of them threw: the rehearsal is stopped and the preview's `down` awaited before the run's own handler sees it.
      cancel.stopped = true;
      stopTagged("rehearsal", TEARDOWN_GRACE);
      await Promise.allSettled([rP, pP]);
      throw e;
    } finally {
      overlap = false;
    }
    // One step, their wall time: the two overlapped, so the sum of the steps must count it once.
    steps[cron.steps.beside] = Math.round((Date.now() - mark) / 1000);
    mark = Date.now();
    const r = race.r!, p = race.p!;
    run.beside = { ...besideTimes(rehearsalResult!.began, rehearsalResult!.admitted, t + r.at), preview: Math.round(p.at / 1000), first: p.at < r.at ? "preview" : "rehearsal" };
    if (!cancel.stopped) sayPreview(p.bad);
    // A rehearsal the preview's failure stopped (it ended without passing) is no verdict of the tree:
    // no bisect (noVerdictRun). One that passed before the stop landed is a verdict.
    const stopped = rehearsalStopped && r.code !== 0;
    const o = besideOutcome(r, p, stopped);
    if (o.failed === "preview") { const f = failureOf("previewFailed", { bad: p.bad, stopped }); end(outcomes.failed, f.why, 1, f.cause); }
    // The rehearsal failed first: the preview was cut short, but a failed `down` (a preview left standing) is said in the run's reason.
    if (cancel.stopped) downFailed = p.bad.filter((b) => b.startsWith("removing the preview")).map((b) => `; ${b}`).join("");
    outcome = rehearsalResult!;
  } else outcome = await rehearsalRun();
  const { gate, got } = outcome;
  // Exit 3 before its slot (a ledger key it could not read, a start mark it could not write) is no verdict as well.
  // So is a rehearsal stopped by a signal (130, or killed: 128 and above), the machine's doing, not the tree's.
  // And a rehearsal its wrapper timed out (124, timeout(1): Studio's integrate@k8s).
  const noVerdict = noVerdictExit(gate.code);
  if (!got) { if (!beside) step(cron.steps.slot); const f = failureOf("beforeSlot", { noVerdict, command: rehearse!.slice(1).join(" ") || rehearse![0], code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, f.cause); }
  if (own && !dry && !beside) step(cron.steps.rehearse);
  // Exit 3 is the rehearsal's "no verdict" (a verdict or record it could not read or write, the checkout changed): nothing
  // is released, and the bisect never takes it up (noVerdictRun), since it says nothing of a commit.
  if (noVerdict) { const f = failureOf("noVerdict", { code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, f.cause); }
  if (gate.code !== 0) { const f = failureOf("rehearsalFailed", { code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, f.cause); }

  // 2a. The android step (releaseCron.android): the app's phone scenarios on an emulator, on a Mac, once the rehearsal
  // passed. A failure ends the run as a failed rehearsal does, and its bisect says "not bisected" (cron.js).
  if (androidRuns(cron.android, Deno.build.os)) {
    active("android");
    let failedNames: string[] = [];
    const cmd = cron.android!.command;
    // Only what cron.js's androidSpawn lets through: the credentials the bisect's env drops, and a Cloudflare token, are not the step's.
    const { env, clearEnv } = androidSpawn(Deno.env.toObject());
    const phoneRun = await child(cmd[0], cmd.slice(1), dir, env, (l) => { failedNames = [...new Set([...failedNames, ...androidFailed(l)])]; }, "", clearEnv);
    step(cron.steps.android);
    if (dry) end(outcomes.dry, phoneRun.code === 0 ? "the android step passed" : androidWhy(phoneRun.code, failedNames), phoneRun.code === 0 ? 0 : 1);
    if (phoneRun.code !== 0) end(outcomes.failed, androidWhy(phoneRun.code, failedNames), 1, "androidFailed");
  } else {
    const skip = androidSkip(cron.android, Deno.build.os);
    if (skip) say(skip);
    if (dry) end(outcomes.dry, "the android step is not declared, or release-cron is not on a Mac: nothing run");
  }

  // 2b. The release preview (releaseCron.target.preview): the release's whole stack in a namespace of its own on the
  // cluster, asked the probes through a port-forward before the release goes ahead, and removed after, whatever it
  // said. It proves the images, the migrations replayed over a fresh database and the config on the node before
  // any traffic moves; a preview that fails stops the release (nothing released).
  if (pv && when === "after") {
    active("preview");
    const bad = await previewCheck(pv, dir, { stopped: false });
    step(cron.steps.preview);
    sayPreview(bad);
    if (bad.length) { const f = failureOf("previewFailed", { bad, stopped: false }); end(outcomes.failed, f.why, 1, f.cause); }
  }

  // The tree the rehearsal and the preview ran on is the tree released: the preview ran before or beside the rehearsal, so
  // the worktree must not have moved meanwhile.
  if (pv && when !== "after") {
    const now = must("git", ["rev-parse", "HEAD"], wt);
    if (now !== head) { const f = failureOf("treeMoved", { from: head.slice(0, 8), to: now.slice(0, 8) }); end(outcomes.failed, f.why, 1, f.cause); }
  }

  // 3. The release, on the tree the rehearsal passed.
  active("release");
  const rel = await child(target ? target.release[0] : "./saytw", target ? target.release.slice(1) : ["release@gcp"], dir, { ...Deno.env.toObject(), STACK_PRIORITY: "release" }, (l) => { newFailing = [...new Set([...newFailing, ...newFeatureNames(l)])]; flaked = [...new Set([...flaked, ...flakedNames(l)])]; });
  step(cron.steps.release);
  // A scenario that flaked and passed only on a rerun (the rehearsal's, or the cloud tests' in release@gcp) is told to the PR that added or last changed it, once per scenario
  // (its own ledger, apart from the new-feature one): the rerun is never a fix.
  if (flaked.length) {
    run.flaked = flaked;
    try {
      const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], wt);
      const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
      const ledger = `${state}/flaked.jsonl`;
      const found = flaked.flatMap((name) => {
        const touched = (sha: string) => sh("git", ["--git-dir", repo, "diff", "--name-only", `${sha}^1`, sha, "--", `${appRel}/tests/scenarios/${name}.cue`]).out !== "";
        const merged = merges(must("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H %s", "-200", head]).split("\n"));
        const c = changedBy(merged, Object.fromEntries(merged.map((m: { sha: string }) => [m.sha, touched(m.sha)])));
        return c?.pr ? [{ scenario: name, pr: c.pr, branch: c.branch }] : [];
      });
      for (const f of untold(found, jsonl(ledger))) {
        const info = prInfo(slug, f.pr);
        const msg = `release-cron (${app}): the scenario ${f.scenario} (added or last changed by PR #${f.pr}, ${f.branch}) flaked, and passed only on its one rerun. Fix it at its cause: the rerun is never a fix. Log: ${state}/runs/${started}.log`;
        const told = tellPr(slug, cron.notify, f.pr, info, msg, `release-cron-flaked-${f.scenario.replace(/[^0-9A-Za-z-]/g, "")}.md`, `scenario ${f.scenario} (PR #${f.pr}) flaked in release-cron ${app}`);
        if (told.includes("comment")) Deno.writeTextFileSync(ledger, JSON.stringify({ ...f, told, at: local(Date.now()) }) + "\n", { append: true });
      }
    } catch (e) { say(`flaked scenarios not told: ${(e as Error).message.split("\n")[0]}`); }
  }

  // (told above even when the release failed: the flakes happened)
  // An ssh that dropped is not a release that failed (PRONTO-758): what the node serves decides, read for about 15 min
  // while the node may still be finishing, only for a target whose `serving` is written after the release (servingAfterRelease, PRONTO-870). Landed, the run goes on to confirm, which checks readiness; else it failed.
  if (rel.code !== 0 && target && rescuable(rel.code, target.servingAfterRelease)) {
    say("the release's ssh exited 255 (its own failure, not the release's): reading what the node serves");
    for (const t = Date.now(); Date.now() - t < 15 * 60_000; await new Promise((r) => setTimeout(r, 30_000))) {
      let now = "";
      try { now = servingNow(); } catch (e) {
        // A failure that is not ssh's own (the serving command ran and failed) says what is wrong at once: the run fails with that exit, not the ssh's.
        const x = e as Error & { exit?: number; permanent?: boolean };
        if (rescueReadStep(x.permanent ? x.exit : 255) === "fail") end(outcomes.failed, `serving (${target!.serving.join(" ")}) failed (exit ${x.exit}) after the release's ssh exited ${rel.code}: ${x.message.split("\n").at(-1)}`, 1);
        say(`serving unread: ${x.message.split("\n").at(-1)}`); continue;
      }
      if (landed(rel.code, now, head, target!.servingAfterRelease)) { run.sshDropped = `the release's ssh exited 255; the node serves ${head.slice(0, 8)}`; say(run.sshDropped as string); break; }
    }
  }
  if (rel.code !== 0 && !run.sshDropped) end(outcomes.failed, target ? `release (${target.release.join(" ")}) failed (exit ${rel.code})` : `release@gcp failed (exit ${rel.code})`, 1);
  // pronto's release ships when only new-feature scenarios fail: the run names them, and the PR that added each is told once.
  if (newFailing.length) {
    run.newFailing = newFailing;
    try {
      const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], wt);
      const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
      const green = jsonl(`${state}/runs.jsonl`).filter((r) => r.outcome === outcomes.released && r.commit).at(-1)?.commit as string | undefined;
      const list = merges(must("git", ["--git-dir", repo, "log", "--first-parent", "--format=%H %s", `${green ?? head}..${head}`]).split("\n"));
      const has = (sha: string, name: string) => sh("git", ["--git-dir", repo, "ls-tree", "--name-only", sha, `${appRel}/tests/scenarios/${name}.cue`]).out !== "" || sh("git", ["--git-dir", repo, "grep", "-q", "-F", "-e", name, sha, "--", `${appRel}/tests/scenarios`]).ok;
      const ledger = `${state}/new-feature.jsonl`;
      const found = green ? newFailing.flatMap((name) => {
        const c = introducedBy(list, Object.fromEntries(list.map((m: { sha: string }) => [m.sha, has(m.sha, name)])), has(green, name));
        return c?.pr ? [{ scenario: name, pr: c.pr, branch: c.branch }] : [];
      }) : [];
      for (const f of untold(found, jsonl(ledger))) {
        const info = prInfo(slug, f.pr);
        const msg = `release-cron (${app}) released ${head.slice(0, 8)} on stable features, although the new scenario ${f.scenario} (added by PR #${f.pr}, ${f.branch}) fails: a release is not held by a new feature's own scenarios. Fix it or take it out. Log: ${state}/runs/${started}.log`;
        const told = tellPr(slug, cron.notify, f.pr, info, msg, `release-cron-new-feature-${f.scenario.replace(/[^0-9A-Za-z-]/g, "")}.md`, `new scenario ${f.scenario} (PR #${f.pr}) fails in release-cron ${app}`);
        if (told.includes("comment")) Deno.writeTextFileSync(ledger, JSON.stringify({ ...f, told, at: local(Date.now()) }) + "\n", { append: true });
      }
    } catch (e) { say(`new-feature scenarios not told: ${(e as Error).message.split("\n")[0]}`); }
  }


  // 4. Production: the revision taking every request is the one this tree's live record names, the `ready` services are
  // ready, the probes answer. Retried until it is confirmed, as a cache or a cold start settles; no limit, a line every few minutes says what is still wrong.
  active("confirm");
  let said = 0;
  let wrong: string[] = [];
  let origin = target ? target.origin : gcp!.domain ? `https://${gcp!.domain}` : "";
  for (;;) {
    wrong = [];
    // A gcloud call that fails is one more thing wrong this round, retried with the rest: the release
    // has happened, and a flake must not log it failed.
    if (target) {
      try {
        const now = servingNow();
        run.revision = now;
        if (now !== head) wrong.push(`serving ${now.slice(0, 8)}, not ${head.slice(0, 8)}`);
      } catch (e) { wrong.push(`serving unread: ${(e as Error).message.split("\n")[0]}`); }
    } else try {
      const svc = JSON.parse(gcloud(["run", "services", "describe", gcp!.service], 60));
      const now = whole(svc.status?.traffic);
      // The probes' address: the domain mapped onto the service, else its run.app one (GCP.domain absent).
      origin = gcp!.domain ? `https://${gcp!.domain}` : svc.status?.url ?? origin;
      run.revision = now;
      wrong.push(...served(now, jsonl(`${home}/.cache/pronto/releases/${gcp!.name}.jsonl`), head));
    } catch (e) { wrong.push(`traffic unread: ${(e as Error).message.split("\n")[0]}`); }
    for (const svc of target ? [] : cron.ready) {
      try {
        const c = JSON.parse(gcloud(["run", "services", "describe", svc], 60)).status?.conditions?.find((c: { type: string }) => c.type === "Ready");
        if (c?.status !== "True") wrong.push(`${svc} not ready`);
      } catch (e) { wrong.push(`${svc} unread: ${(e as Error).message.split("\n")[0]}`); }
    }
    for (const [name, p] of Object.entries(cron.probes)) {
      try {
        const r = await fetch(`${origin}${p.path}`, { headers: p.agent ? { "User-Agent": p.agent } : {}, redirect: p.location ? "manual" : "follow", signal: AbortSignal.timeout(30_000) });
        const v = probe(p, r.status, await r.text(), r.headers.get("location"));
        if (v) wrong.push(`${name} ${v}`);
      } catch (e) { wrong.push(`${name} ${p.path}: ${(e as Error).message}`); }
    }
    if (!wrong.length) break;
    if (Date.now() - said >= HEARTBEAT) { said = Date.now(); say(`confirm: still waiting on production: ${wrong.join("; ")}`); }
    await new Promise((r) => setTimeout(r, 15_000));
  }
  step(cron.steps.confirm);
  if (wrong.length) end(outcomes.failed, `released, production not confirmed: ${wrong.join("; ")}`, 1);
  // 5b. The flags the release reads (releaseCron.flagsReleased), now that production serves it.
  run.flagsReleased = await flagsReleased(`${wt}/${appRel}`, false) ?? undefined;
  // 6. The release's notes (release-notes/release-notes.ts), when the app has them and the revision is new: a GitHub Release
  // tagged <app>/<revision>. Its output is in the run's log; whatever it does, the run's outcome stays.
  if (run.revision !== before && exists(`${dir}/release-notes/release-notes.ts`)) {
    try {
      // With the run's own GH_TOKEN: under CD the release job's token, which may write Releases (bsoneca/pronto's
      // cd.yml: contents write, pull-requests read). A job started with SessionCreate cannot reach the owner's
      // gh login in the keychain, so that token is the only login there; launchd's run uses the owner's.
      // This run as release-notes reads a released one: end() writes it to runs.jsonl only after the notes, and an app
      // on a command target has no other record of the revision it just made live (PRONTO-205).
      const current = JSON.stringify({ ...run, outcome: outcomes.released, ended: local(Date.now()) });
      const n = await child(Deno.execPath(), ["run", "-A", "release-notes/release-notes.ts", app, "publish", String(run.revision)], dir, { ...Deno.env.toObject(), RELEASE_NOTES_RUN: current });
      run.notes = n.code === 0 ? "published" : `failed (exit ${n.code})`;
    } catch (e) { run.notes = `failed (${(e as Error).message.split("\n")[0]})`; }
    say(`release notes ${run.notes}`);
  }
  // 6b. The release's source maps (pronto-errors: errors/sourcemaps.ts), when the app sends them and the revision is new:
  // the bundles built again from the tree released, with their maps, sent to GlitchTip, so a page's error there shows its
  // original file, function and line. Its output is in the run's log; whatever it does, the run's outcome stays.
  if (run.revision !== before && exists(`${dir}/errors/sourcemaps.ts`)) {
    try {
      const m = await child(Deno.execPath(), ["run", "-A", "--no-config", "errors/sourcemaps.ts", "upload"], dir, Deno.env.toObject());
      run.maps = m.code === 0 ? "sent" : `failed (exit ${m.code})`;
    } catch (e) { run.maps = `failed (${(e as Error).message.split("\n")[0]})`; }
    say(`source maps ${run.maps}`);
  }
  // 7. The hooks (releaseCron.hooks, on `released`), each in the run's worktree with the worktree, the app and the commit
  // appended (the dev flow's board is one: devflow/hook.ts released, which tells the app's Merged issues whose pull request
  // this release holds that they are Live, a flagless fix Done; its token is PLANE_TOKEN or Secret Manager's). The hook finds
  // `cue` as mise's newest when the PATH has none (boardEnv). A hook that fails is logged and never changes the run's outcome.
  const hooked: string[] = [];
  for (const h of hooksOf(cron.hooks, "released")) {
    const argv = hookArgv(h, wt, appRel.split("/").pop()!, head);
    let result: string;
    try {
      const r = await child(argv[0] === "deno" ? Deno.execPath() : argv[0], argv.slice(1), wt, boardEnv(Deno.env.toObject(), Deno.env.get("HOME") ?? "", cueVersions()));
      result = r.code === 0 ? "ok" : `failed (exit ${r.code})`;
    } catch (e) { result = `failed (${(e as Error).message.split("\n")[0]})`; }
    hooked.push(`${h.command.slice(0, 3).join(" ")} ${result}`);
    say(`hook ${h.on} ${h.command.join(" ")}: ${result}`);
  }
  if (hooked.length) run.hooks = hooked;
  // A release that changed nothing Cloud Run runs (tests, config) keeps the revision: said, so it
  // does not read as a deploy that never went out.
  // The revision stays in the ledger as released; failed flag bookkeeping is the job's nonzero exit, retried by the next wake on the already-serving path.
  const flagsFailed = flagsExit(run.flagsReleased as string | undefined);
  end(outcomes.released, (!target && run.revision === before ? `same image, nothing served changed: ${before} kept` : "") + (flagsFailed ? `${!target && run.revision === before ? "; " : ""}flags bookkeeping ${run.flagsReleased}` : ""), flagsFailed);
} catch (e) {
  step(cron?.steps.error ?? "error");
  const why = (e as Error).message.split("\n")[0];
  end(outcomes.failed, appendWhy(run.why as string | undefined, why), 1, why === causes.signal ? "signal" : "");
}

// releaseCron.flagsReleased: records which flags the release now served reads, so a flag push keeps one it still reads
// (pronto-flags `released`). Its outcome never changes the run's outcome or the confirmed revision, but a failure is the job's nonzero exit (flagsExit). The commit
// it succeeded for is kept in `flags-released`: a run that finds main already serving records again only when that is not head.
async function flagsReleased(dir: string, onlyIfDue: boolean): Promise<string | null> {
  const marker = `${state}/flags-released`;
  if (onlyIfDue && !flagsReleasedDue(exists(marker) ? Deno.readTextFileSync(marker) : null, head)) return null;
  const result = await recordFlagsReleased(cron.flagsReleased, dir, { cwd: wt, env: boardEnv(Deno.env.toObject(), Deno.env.get("HOME") ?? "", cueVersions()) });
  if (result === null) return null;
  // A marker that cannot be written is said with its path and recorded as the bookkeeping's failure (run.flagsReleased), apart from the deploy outcome.
  let err: unknown = null;
  if (result === "ok") { try { Deno.writeTextFileSync(marker, head); } catch (e) { err = (e as Error).message ?? e; } }
  const final = flagsBookkeeping(result, marker, err);
  say(`flags released ${cron.flagsReleased!.join(" ")}: ${final}${final === "ok" ? "" : "; the flags' push keeps every live flag until it is recorded"}`);
  return final;
}

function cueVersions(): string[] {
  try {
    return [...Deno.readDirSync(`${Deno.env.get("HOME")}/.local/share/mise/installs/github-cue-lang-cue`)].map((e) => e.name);
  } catch { return []; }
}
function exists(p: string) { try { Deno.statSync(p); return true; } catch { return false; } }
