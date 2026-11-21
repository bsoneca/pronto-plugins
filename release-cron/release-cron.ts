// release-cron: an app released to production on a schedule, by launchd on this Mac, from main.
// pronto-plugins' release-cron/README.md says more. Run from the app's folder, where it is written:
//   deno run -A release-cron/release-cron.ts <app> run         one run now (what launchd runs)
//   deno run -A release-cron/release-cron.ts <app> install     the run's worktree and the scheduler's job (releaseCron.scheduler: launchd, systemd or actions)
//   deno run -A release-cron/release-cron.ts <app> uninstall   the scheduler's job gone (the worktree kept)
//   deno run -A release-cron/release-cron.ts <app> pause|resume  runs skip while paused
//   deno run -A release-cron/release-cron.ts <app> abandon     give up the held release branch (the next run cuts from main again, after the gap)
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
// With releaseCron.branches.enabled a run whose rehearsal fails on main holds the release on a branch, release/<app>/<id>, instead of
// failing it: `open` (JSON) names it, the next runs take the branch as their ref, ignore the gap and run only when its tip is new, and
// the first green one releases from it (README.md, "Release branches"). `abandon` gives a held release up by hand.
// Its state is ~/.cache/pronto/release-cron/<app>/: the worktree (wt), the lock, the pause, the open release, the
// log (release-cron.log, a line a run), last (when the last spaced run ended), runs.jsonl (the same as JSON) and each run's output (runs/).
import { causes, outcomes } from "./causes.js";
import { legacyLock, reapSignal, appendWhy, holderPid, holderKind, reapStep, signalDone, trustNotice, stopSeconds, failureOf, abandoned, attempted, backportPlan, backportWhy, corruptOpen, dryWould, heldConfig, heldDiffArgs, heldPlan, limitPlan, servingPlan, rerunWhy, heldTrusted, backportCheck, rehearsalSpawn, signalStops, previewUpStep, upExtra, lockStep, flagsBookkeeping, branchOutcome, patchIdsOf, patchOf, nulPaths, resolvedMerges, isSha, leaseDelete, leaseLost, missingFromMain, mutates, refusal, heldNotice, heldWait, lastFields, migrationFiles, parseLog, refusedTip, unmerged, branchName, heldDue, heldLine, schedulerEnv, previewProbes, boardEnv, hookArgv, hooksOf, flagsReleasedDue, recordFlagsReleased, channels, systemdUnits, lowPriority, activeLine, base, behind, bisectLine, changed, detail, due, holds, line, local, merges, next, plist, newFeatureNames, flakedNames, changedBy, introducedBy, untold, undecidable, unreproduced, probe, report, served, sessionOf, signature, spaced, retry, landed, rescuable, verdict, releaseModes, rehearsalBase, abandonPlan, shippedRecord, releaseAttempt, cutPlan, noVerdictExit, noVerdictRun, besideOutcome, besideTimes, inconclusiveExit, whole, fixedBy, stopsBisect, concerns, failedRehearsal, androidRuns, androidSkip, androidFailed, androidWhy, androidSpawn, endWhenInterrupted, branchTip, signalStep, servingRetryable } from "./cron.js";
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

const real = (p: string) => { try { return Deno.realPathSync(p); } catch { return p; } };
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

// The open release (cron.js, "Release branches"): written whole and renamed into place, null when none is held.
type Attempt = { tip: string; verdict: string; at: string };
type Open = { branch: string; base: string; opened: string; limits: { abandonHours: number; abandonAttempts: number }; attempts: Attempt[] };
const openPath = `${state}/open`;
// Only a file that is not there is absent: one that cannot be read or parsed stops the run loudly, never reads as "nothing held".
const readJson = <T>(path: string): T | null => {
  try { return JSON.parse(Deno.readTextFileSync(path)); } catch (e) {
    if (e instanceof Deno.errors.NotFound) return null;
    throw new Error(`${path} could not be read: ${(e as Error).message}`);
  }
};
type Released = { branch: string; tip: string };
const readOpen = (): Open | null => readJson<Open>(openPath);
const readReleased = (): Released | null => readJson<Released>(`${state}/released-branch`);
const writeOpen = (o: Open) => { Deno.writeTextFileSync(`${openPath}.tmp`, JSON.stringify(o) + "\n"); Deno.renameSync(`${openPath}.tmp`, openPath); };
// `abandon` is how a lead gets past an `open` file that cannot be read: it reports it and removes it only with --force (corruptOpen).
let open = null as Open | null;
// `abandon` reads `open` only once it holds the run lock (below), so no run changes it meanwhile; every other verb reads it now.
const loadOpen = (release: () => void = () => {}) => {
  try { open = readOpen(); } catch (e) {
    if (verb !== "abandon") throw e;
    const c = corruptOpen(openPath, (e as Error).message, Deno.args.includes("--force"));
    console.log(c.text);
    if (!c.remove) { release(); Deno.exit(1); }
    Deno.removeSync(openPath);
  }
};
if (verb !== "abandon") loadOpen();

if (verb === "pause") { Deno.writeTextFileSync(`${state}/paused`, local(Date.now()) + "\n"); console.log(`${app}: paused; runs skip until \`resume\``); Deno.exit(0); }
if (verb === "resume") { Deno.removeSync(`${state}/paused`); console.log(`${app}: resumed`); Deno.exit(0); }
if (verb === "status") {
  const job = exists(`${units}.timer`) ? sh("systemctl", ["--user", "is-enabled", `${label}.timer`]) : sh("launchctl", ["print", `gui/${uid}/${label}`]);
  console.log(`job ${label}: ${job.ok ? "installed" : "not installed"}${exists(`${state}/paused`) ? ", paused" : ""}`);
  console.log(heldLine(open) ?? "no release branch held");
  console.log(sh("tail", ["-n", "12", `${state}/release-cron.log`]).out);
  Deno.exit(0);
}
const jsonl = (f: string) => { try { return Deno.readTextFileSync(f).split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
// The ms a stopped child gets before KILL, and a preview's `down` after them (it is tagged "down", never stopped by a signal).
const STOP_GRACE = 60_000, TEARDOWN_GRACE = 300_000;
// A lock: an flock(2) on a file (`<state>/lock` for a run and `abandon`, `bisect/lock` for the bisect), which the kernel releases when its holder dies, so a
// dead holder's lock is never taken over by a race. Deno 2.5's FsFile.lock/lockSync only block (no try-lock), so a small perl helper takes it with
// LOCK_NB and holds it for as long as its stdin stays open: when this process ends, however, the pipe closes and the helper exits. The holder's pid is
// written into the file for messages and `holderKind` only, never for the decision. The reap of a dead run's preview runs only once the lock is held.
// A lock directory an earlier version made keeps its live holder (legacyLock): busy while its `lock/pid` is alive, removed when it is dead or unreadable.
const FLOCK_HELPER = 'use Fcntl qw(:flock); open(F, ">>", $ARGV[0]) or exit 4; flock(F, LOCK_EX | LOCK_NB) or exit 3; $| = 1; print "ok\n"; <STDIN>; exit 0;';
const heldLocks = new Map<string, Deno.ChildProcess>();
const flockTry = async (path: string): Promise<boolean> => {
  const p = new Deno.Command("perl", { args: ["-e", FLOCK_HELPER, path], stdin: "piped", stdout: "piped", stderr: "null" }).spawn();
  const reader = p.stdout.getReader();
  const first = await reader.read();
  if (first.value && decode(first.value).startsWith("ok")) { reader.releaseLock(); p.unref(); heldLocks.set(path, p); return true; }
  const { code } = await p.status;
  if (code !== 3) throw new Error(`the lock ${path} could not be opened (the flock helper exited ${code})`);
  return false;
};
// The pid in a lock (cron.js holderPid): a file's content, or, for a directory an earlier version made, its `pid` file.
const lockHolder = (lock: string) => {
  const read = (f: string) => { try { return Deno.readTextFileSync(f); } catch { return ""; } };
  let isDir = false;
  try { isDir = Deno.statSync(lock).isDirectory; } catch { /* none */ }
  return holderPid(isDir, read(`${lock}/pid`), read(lock));
};
const lockAcquire = async (lock: string, orphan: () => boolean = () => false, reap: () => void = () => {}): Promise<{ got: true } | { got: false; pid: number }> => {
  let isDir = false;
  try { isDir = Deno.statSync(lock).isDirectory; } catch { /* none */ }
  if (isDir) {
    const pid = lockHolder(lock);
    const legacy = legacyLock(true, pid, !!pid && sh("kill", ["-0", String(pid)]).ok);
    if (legacy === "busy") return { got: false, pid };
    Deno.removeSync(lock, { recursive: true });
  }
  const acquired = await flockTry(lock);
  const step = lockStep(acquired, acquired && orphan());
  if (step === "busy") return { got: false, pid: lockHolder(lock) };
  if (step === "reap") reap();
  Deno.writeTextFileSync(lock, String(Deno.pid));
  return { got: true };
};
// Let the lock go: the pid emptied (a reader sees no holder), then the helper's stdin closed so it exits and the kernel releases the flock. `await`ed where
// another process takes the lock next (the hand-over to main's script); a process that exits next needs no wait.
const lockRelease = async (lock: string) => {
  const p = heldLocks.get(lock);
  if (!p) return;
  heldLocks.delete(lock);
  try { Deno.writeTextFileSync(lock, ""); } catch { /* gone */ }
  try { await p.stdin.close(); } catch { /* closed */ }
  await p.status;
};
const lockPath = `${state}/lock`;
const lockPid = () => lockHolder(lockPath);
// The run holding the lock named by its pid, from its command line: a run or an abandon (cron.js holderKind).
const holderOf = (pid: number) => holderKind(sh("ps", ["-o", "command=", "-p", String(pid)], undefined, {}, 10).out);
// A preview's remote `up` that its run did not live to end: its pgid and the `down` that removes the preview, kept in <state>/lock.preview from the start of
// `up` to the end of `down`. The next run to take the lock over a dead holder first stops that `up` (TERM, then KILL after the grace: the recorded pgid
// only, never a pattern) and runs the `down`, so the preview is never left for a run to race. What it did is `reaped`, told in the run's record.
const previewRecord = `${state}/lock.preview`;
// A process's identity: whether it exists, its start time (`ps -o lstart=`) and the machine's boot (Linux's boot_id, else macOS's kern.boottime), what
// tells it from a later process that reused its pid (cron.js reapSignal).
const bootId = () => { try { return Deno.readTextFileSync("/proc/sys/kernel/random/boot_id").trim(); } catch { return sh("sysctl", ["-n", "kern.boottime"], undefined, {}, 10).out; } };
const identityOf = (pid: number) => { const r = sh("ps", ["-o", "lstart=", "-p", String(pid)], undefined, {}, 10); return { exists: r.ok && r.out !== "", lstart: r.out, boot: bootId() }; };
let reaped = "";
const reapPreview = () => {
  let rec: { pgid?: number; lstart?: string; boot?: string; down: string[]; dir: string } | null = null;
  try { rec = JSON.parse(Deno.readTextFileSync(previewRecord)); } catch (e) {
    reaped = `the preview record ${previewRecord} could not be read (${(e as Error).message.split("\n")[0]}): removed, its preview may still stand`;
    console.log(`release-cron: ${reaped}`);
    try { Deno.removeSync(previewRecord); } catch { /* gone */ }
    return;
  }
  // The group is signalled only when its leader is still the process recorded (same start time, same boot): a pgid is reused, and a record with no pgid
  // (its `up` had exited) or a leader that is gone or another process is an `up` that is gone, and `down` runs at once (cron.js reapSignal).
  const pg = rec!.pgid;
  const signal = reapSignal(rec, pg ? identityOf(pg) : null);
  let note = pg ? (signal ? `its up (group ${pg}) stopped` : `its up (group ${pg}) was gone or not the recorded process: not signalled`) : "its up had exited";
  if (signal) {
    const group = (sig: string) => sh("kill", [`-${sig}`, "--", `-${pg}`], undefined, {}, 10);
    let termed = false;
    for (const t = Date.now();;) {
      const a = reapStep(group("0").ok, Date.now() - t, STOP_GRACE);
      if (a === "gone") break;
      if (a === "giveup") { note = `its up (group ${pg}) was still alive a minute after KILL: gone on to down`; break; }
      if (a === "term" && !termed) { termed = true; console.log(`release-cron: a dead run left the preview's up (group ${pg}): stopped`); group("TERM"); }
      else if (a === "kill") group("KILL");
      sh("sleep", ["1"], undefined, {}, 5);
    }
  }
  const d = sh(rec!.down[0], rec!.down.slice(1), rec!.dir, { STACK_PRIORITY: "release" }, TEARDOWN_GRACE / 1000);
  reaped = d.ok ? `a dead run left a preview: ${note} and ${rec!.down.join(" ")} ran` : `a dead run left a preview: ${note} but ${rec!.down.join(" ")} failed (exit ${d.code}): the preview may still stand, the record is kept`;
  console.log(`release-cron: ${reaped}`);
  if (d.ok) { try { Deno.removeSync(previewRecord); } catch { /* gone */ } }
};
const takeLock = () => lockAcquire(lockPath, () => exists(previewRecord), reapPreview);
const dropLock = () => { lockRelease(lockPath); };
// A held release ends: removed, and its record (the branch, its attempts, how it ended and the commit released, if any) appended to
// runs.jsonl beside the runs, in an outcome of its own that no rule of the schedule reads.
const closeOpen = (result: "released" | "abandoned", commit?: string) => {
  Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify({ app, started: local(Date.now()), steps: {}, outcome: outcomes.closed, commit, detail: { release: { ...open, result, commit } } }) + "\n", { append: true });
  Deno.removeSync(openPath);
  open = null;
};
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

// The release branch's commits that main has no counterpart of, since it was cut from main (cron.js, missingFromMain): `tip` and `main` are
// commit ids (isSha), the branch's and the one main is compared at, so the merge base and both ranges name commits that cannot move under the
// check; a merge whose resolution changed code counts as missing. Fetched first; git runs on the repository itself, so no worktree need exist.
const repoDir = () => must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], here);
const fetchOrigin = () => must("git", remote(["--git-dir", repoDir(), "fetch", "-q", "origin"]), undefined, {}, 300);
const missingOnMain = (tip: string, main: string) => {
  if (!isSha(tip) || !isSha(main)) throw new Error(`the backport check needs commit ids, got ${tip} and ${main}`);
  const repo = repoDir();
  const g = (...a: string[]) => must("git", ["--git-dir", repo, ...a], undefined, {}, 300);
  fetchOrigin();
  const range = (r: string) => {
    const log = parseLog(g("log", "--no-merges", "--reverse", "--format=%H%x1f%B%x1e", r));
    // Two git processes, each checked (patchIdsOf): the patch is made from a file, so a failed or timed-out `git log -p` is never read as the
    // shorter list it left. A failure stops the backport check, loudly (callers keep the branch and its record).
    const tmp = Deno.makeTempFileSync({ prefix: "release-cron-patch." });
    try {
      const made = patchIdsOf(
        sh("git", ["--git-dir", repo, "log", "-p", "--no-merges", "--reverse", `--output=${tmp}`, r], undefined, {}, 300),
        sh("sh", ["-c", 'git patch-id --stable < "$PATCH_FILE"'], undefined, { PATCH_FILE: tmp }, 300),
      );
      if ("error" in made) throw new Error(`the backport check of ${r} stopped: ${made.error}`);
      // A commit with no patch id is empty only when it has no tree change (patchOf); null: nothing to carry (cron.js, backported).
      return log.map((c: { sha: string; body: string }) => {
        const p = patchOf(c.sha, made.ids[c.sha], made.ids[c.sha] ? { ok: true, out: "" } : sh("git", ["--git-dir", repo, "diff-tree", "--root", "-r", "--no-commit-id", c.sha], undefined, {}, 120));
        if ("error" in p) throw new Error(`the backport check of ${r} stopped: ${p.error}`);
        return { ...c, patch: p.patch };
      });
    } finally { try { Deno.removeSync(tmp); } catch { /* gone */ } }
  };
  // The cherry-pick and Backport-of lines are read from all of main's history at that commit, as the ledger does.
  const all = parseLog(g("log", "--format=%H%x1f%B%x1e", main));
  const mb = g("merge-base", main, tip);
  const merged = g("rev-list", "--merges", `${mb}..${tip}`).split("\n").filter(Boolean)
    .map((sha) => ({ sha, subject: g("log", "-1", "--format=%s", sha), cc: g("show", "--cc", "--format=", sha) }));
  return missingFromMain(range(`${mb}..${tip}`), range(`${mb}..${main}`), merged, all) as { sha: string; body: string }[];
};
// `branch` deleted from origin, only as the tip that was checked (`verified`): an explicit lease on it. A branch pushed to since the check
// stays, with its new tip said. Returns whether it is gone from origin, or "unknown" when origin could not be asked (kept, its record too).
const deleteBranch = (branch: string, verified: string, notify: Notify): boolean | "unknown" => {
  const pushed = sh("git", remote(["--git-dir", repoDir(), "push", "-q", ...leaseDelete(branch, verified)]), undefined, {}, 120);
  if (pushed.ok) return true;
  const r = sh("git", remote(["--git-dir", repoDir(), "ls-remote", "origin", `refs/heads/${branch}`]), undefined, {}, 60);
  // A lookup that failed says nothing of the branch: it is kept, and the failure told (branchTip), never read as gone.
  const looked = branchTip(r.ok, r.out, r.err);
  if (looked.error) {
    tellNote(notify, `release-cron (${app}): ${branch} was not deleted: its lookup on origin failed (${looked.error}); the branch and its record are kept.`, `release-cron-branch-${branch.split("/").at(-1)}.md`, "release-cron branch kept");
    console.log(`release-cron: ${branch}: the lookup on origin failed (${looked.error}): kept`);
    return "unknown";
  }
  const lost = leaseLost(branch, verified, looked.tip);
  if (!lost.deleted) tellNote(notify, `release-cron (${app}): ${lost.why}; the branch and its record are kept.`, `release-cron-branch-${branch.split("/").at(-1)}.md`, "release-cron branch kept");
  else console.log(`release-cron: ${lost.why}`);
  return lost.deleted;
};
// The branch of a release that ended (abandoned, or released and found on main) is deleted from origin only when everything on it
// is on main, at the tip and main this checked; else it stays, and the lead is told which commits still need a cherry-pick.
// Returns "deleted", "kept" (commits missing, or an error), "moved" (the branch has a tip nothing checked: kept, its record too)
// or "unknown" (origin could not be asked: kept).
const dropBranch = (branch: string, notify: Notify): "deleted" | "kept" | "moved" | "unknown" => {
  try {
    fetchOrigin();
    const g = (...a: string[]) => must("git", ["--git-dir", repoDir(), ...a], undefined, {}, 60);
    const tip = g("rev-parse", "--verify", `origin/${branch}^{commit}`);
    const missing = missingOnMain(tip, g("rev-parse", "--verify", "origin/main^{commit}"));
    if (missing.length) {
      tellNote(notify, `release-cron (${app}): ${branch} is left on origin: ${backportWhy(missing)}. Cherry-pick them to main (git cherry-pick -x), then delete the branch.`, `release-cron-branch-${branch.split("/").at(-1)}.md`, "release-cron branch kept");
      return "kept";
    }
    const gone = deleteBranch(branch, tip, notify);
    return gone === "unknown" ? "unknown" : gone ? "deleted" : "moved";
  } catch (e) {
    // Loud: in the log and told; the branch and its record are kept.
    const why = (e as Error).message.split("\n")[0];
    console.log(`release-cron: ${branch} not deleted: ${why}`);
    tellNote(notify, `release-cron (${app}): ${branch} was not deleted: ${why}; the branch and its record are kept.`, `release-cron-branch-${branch.split("/").at(-1)}.md`, "release-cron branch kept");
    return "kept";
  }
};
// A held branch that shipped though no record says so (its confirmation never ran) gets its released-branch record, from the evidence
// shippedRecord names: a run of the branch that reached the release step (runs.jsonl), what serves (read the way a run reads it: the
// serving command, or Cloud Run's traffic, once, 20 s at most; `known` is what a run already read) and origin's tip. Written so abandoning
// the hold keeps its backport hold. Returns what it wrote, or "".
// `known`: what a run already read as serving, and its config (in end(), where the run's is loaded).
const recordShipped = (o: Open, known?: { live: string | null; cron: { steps: { release: string } } }): string => {
  const g = (...a: string[]) => sh("git", ["--git-dir", repoDir(), ...a], undefined, {}, 60);
  let tip: string | null = null, serving: string | null = null, released: string | null = null;
  // Origin's tip; unread, the local ref of the branch, else its newest attempt's.
  try { fetchOrigin(); } catch { /* the local ref stands */ }
  try { tip = must("git", ["--git-dir", repoDir(), "rev-parse", "--verify", `origin/${o.branch}^{commit}`]); } catch { tip = o.attempts.at(-1)?.tip ?? null; }
  try {
    // The config once: the run's own (`known`), else the trusted checkout's.
    const { cron: c, gcp: d } = known ? { cron: known.cron, gcp: undefined } : config(top);
    released = releaseAttempt(jsonl(`${state}/runs.jsonl`), o.branch, c.steps.release);
    if (known) serving = known.live;
    else if (c.target.kind === "command") { const r = sh(c.target.serving[0], c.target.serving.slice(1), `${top}/${appRel}`, Deno.env.toObject(), 20); if (r.ok) serving = r.out.split(/\s+/)[0] || null; }
    else {
      const out = sh("gcloud", ["run", "services", "describe", d.service, "--project", d.project, "--region", d.region, "--format=json"], undefined, {}, 20);
      if (out.ok) serving = base(jsonl(`${state}/runs.jsonl`), whole(JSON.parse(out.out).status?.traffic));
    }
  } catch { /* serving unread */ }
  // A commit of the branch main lacks: serving moved past a tip the branch has since left. Only a full commit id goes to git.
  const onBranch = isSha(serving) && !!tip && g("merge-base", "--is-ancestor", serving!, `origin/${o.branch}`).ok && !g("merge-base", "--is-ancestor", serving!, "origin/main").ok;
  const rec = shippedRecord(o, readReleased(), { released, serving, tip, onBranch });
  if (!rec) return "";
  Deno.writeTextFileSync(`${state}/released-branch`, JSON.stringify({ branch: rec.branch, tip: rec.tip }) + "\n");
  return `${o.branch}: ${rec.why}; its record and backport hold are kept`;
};
// `abandon` holds the run's lock (takeLock) from before it reads `open` or `released-branch` until every change is done, so a scheduled wake
// that starts meanwhile skips as it does beside any run, and never rehearses or deploys the branch being closed. A lock held by a live run
// refuses: said in the log and the error, nothing read or changed.
const abandonRun = async (): Promise<number> => {
  // Held, or released and waiting for its commits on main (held-backport), or both for one branch; abandonPlan says what goes: a hold
  // that never shipped is dropped with its branch, a released branch's record (its backport hold) only once every commit is on main.
  // A released-branch record that cannot be read is cleared by --force, as an open one is (corruptOpen).
  const taken = await takeLock();
  if (!taken.got) {
    const why = `${holderOf(taken.pid)} ${taken.pid} is going and holds the run lock: abandon when it ends; nothing was read or changed`;
    const rec = { app, started: local(Date.now()), steps: {}, outcome: outcomes.skipped, why: `abandon: ${why}` };
    const l = line(rec);
    Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
    Deno.writeTextFileSync(`${state}/runs.jsonl`, JSON.stringify(rec) + "\n", { append: true });
    console.log(l);
    throw new Error(why);
  }
  loadOpen(dropLock);
  const recordPath = `${state}/released-branch`;
  try { readReleased(); } catch (e) {
    const c = corruptOpen(recordPath, (e as Error).message, Deno.args.includes("--force"));
    console.log(c.text);
    if (!c.remove) return 1;
    Deno.removeSync(recordPath);
  }
  if (!open && !readReleased()) { console.log(`${app}: no release branch held`); return 0; }
  const shippedNote = open ? recordShipped(open) : "";
  if (shippedNote) console.log(shippedNote);
  const force = Deno.args.includes("--force");
  const rb = readReleased();
  const shipped = abandonPlan(open, rb, null, null).shipped;
  // Checked against main as it is now, at a commit id read once; the branch is deleted only as the released tip, and a branch that moved
  // since its release (a tip nothing checked) is kept with its record, for the next look.
  const missing = !shipped ? [] : (() => { try { fetchOrigin(); return missingOnMain(rb!.tip, must("git", ["--git-dir", repoDir(), "rev-parse", "--verify", "origin/main^{commit}"])); } catch { return null; } })();
  const gone = shipped && missing && !missing.length ? deleteBranch(rb!.branch, rb!.tip, { kind: "none" }) : null;
  // --force clears a record only when this call did not just write one for a hold that shipped.
  const plan = abandonPlan(open, rb, missing, gone, force && !shippedNote);
  if (plan.removeRecord) for (const f of ["released-branch", "backport-told"]) { try { Deno.removeSync(`${state}/${f}`); } catch { /* none */ } }
  const missingSaid = missing === null ? "the commits missing from main could not be read" : missing.length ? `still missing from main: ${backportWhy(missing)}` : "every commit was on main";
  let outcome: string, why: string, told: string;
  // What happened to the branch on origin, from what was done: deleted (gone), or kept and why.
  const kept = plan.shipped ? (gone === true ? `${rb!.branch} deleted from origin` : `${rb!.branch} kept on origin${plan.why ? `: ${plan.why}` : ""}`) : "";
  if (plan.closeHold) {
    const branch = open!.branch;
    closeOpen("abandoned");
    // As an abandoned run ends: the gap is waited before main is cut again, the app's, kept beside the last run's end.
    const gap = (() => { try { return Number(Deno.readTextFileSync(`${state}/last`).split(" ")[1]) || 60; } catch { return 60; } })();
    Deno.writeTextFileSync(`${state}/last`, `${Date.now()} ${gap} - -`);
    outcome = branchOutcome("abandoned", branch); why = plan.removeRecord && plan.shipped ? `by hand${force ? " --force" : ""}; ${missingSaid}` : "by hand";
    told = plan.dropBranch ? (dropBranch(branch, { kind: "none" }) === "deleted" ? `${branch} deleted from origin` : `${branch} kept on origin`)
      : `${kept}${plan.removeRecord ? ", its record cleared" : ", its record and backport hold stay"}`;
  } else {
    outcome = branchOutcome("cleared", rb!.branch);
    why = `by hand${force ? " --force" : ""}; ${plan.removeRecord && !plan.why ? "every commit was on main" : `${missingSaid}${plan.removeRecord ? ", the record cleared" : `, the branch kept and its record (${plan.why})`}`}`;
    told = "";
  }
  const l = line({ app, started: local(Date.now()), steps: {}, outcome, why });
  Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
  console.log(l);
  if (told) console.log(told);
  return 0;
};
if (verb === "abandon") {
  let code: number;
  try { code = await abandonRun(); } finally { dropLock(); }
  Deno.exit(code);
}

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
  const failed = only ? runs.find((r) => r.started === only) : since.find((r) => (r.outcome === outcomes.failed || r.cut) && r.commit && !settled(r) && !noVerdictRun(r.why, r.cause));
  if (failed && noVerdictRun(failed.why, failed.cause)) { say(`run ${failed.started} gave no verdict: nothing to bisect`); Deno.exit(0); }
  if (!failed) { say("no failed run unbisected"); Deno.exit(0); }
  const at = runs.indexOf(failed);
  const green = runs.slice(0, at).filter((r) => r.outcome === outcomes.released && r.commit).at(-1);
  if (runs.slice(at + 1).some((r) => r.outcome === outcomes.released)) { say(`run ${failed.started} was followed by a release: nothing to bisect`); Deno.exit(0); }
  if (!green) { say(`no run released before ${failed.started}: no good commit to start from`); Deno.exit(0); }
  // One bisect at a time: a lock directory holding the pid, a dead holder's taken over.
  if (!dry) {
    // The same lock as the run's (lockAcquire).
    const l = await lockAcquire(`${dir}/lock`);
    if (!l.got) { say(l.pid ? `bisect ${l.pid} still going` : "another bisect took the lock"); Deno.exit(0); }
  }
  const unlock = () => { lockRelease(`${dir}/lock`); };
  // The run's lock holder. The run that started this bisect (RELEASE_CRON_BISECT_BY, its pid) lets it go
  // as it ends; any other live holder is a run this bisect yields to, one by hand's too.
  const runHolder = () => lockPid();
  const starter = Number(Deno.env.get("RELEASE_CRON_BISECT_BY") ?? 0);
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], here);
  must("git", remote(["--git-dir", repo, "fetch", "-q", "origin"]));
  const slug = must("git", ["--git-dir", repo, "remote", "get-url", "origin"]).replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
  const { gcp: g, cron } = config(top);
  const gcpName = g?.name as string | undefined;
  const b = cron.bisect;
  const notify = cron.notify;
  const text = (() => { try { return Deno.readTextFileSync(`${state}/runs/${failed.started}.log`); } catch { return ""; } })();
  const sig = signature(failed.why, text);
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
// A held release (releaseCron.branches) takes its branch in main's place, for a run only.
const override = Deno.env.get("RELEASE_CRON_REF");
const ref = override ?? (open && verb === "run" ? `origin/${open.branch}` : "origin/main");
// RELEASE_CRON_REF skips the cut, and a held release is run only by naming its own branch, which then runs as any held run.
if (verb === "run" && override) {
  if (open && override !== `origin/${open.branch}` && override !== open.branch) throw new Error(`${open.branch} is held: RELEASE_CRON_REF=${override} would release past it; abandon it or name it`);
}
// A run on a held release's branch (a failure there is not main's: no bisect, no failed commit in `last`).
const heldRun = !!open && verb === "run";
// `at`: the ref a run takes, or, for a held release's tip, the commit id heldCheck judged (so what is checked out and trusted is what was).
function worktree(at = ref) {
  const repo = must("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], exists(wt) ? wt : here);
  must("git", remote(["--git-dir", repo, "fetch", "-q", "origin"]));
  if (!exists(`${wt}/.git`)) must("git", ["--git-dir", repo, "worktree", "add", "-q", "--detach", wt, at]);
  must("git", ["checkout", "-q", "--detach", "-f", at], wt);
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
  // The job runs this script from the run's worktree, so its checkout is the one the held tip would be checked out into: held releases cannot be trusted
  // there, and a hold it cut would always be refused (heldTrusted). Installing it with branches enabled is refused, with the same message.
  const untrustedJob = config(top).cron.branches?.enabled ? heldTrusted(real(wt), real(wt)) : null;
  if (untrustedJob) throw new Error(`${label} not installed: releaseCron.branches is enabled and ${untrustedJob}`);
  const head = worktree();
  const { cron } = config(wt);
  // The scheduler's environment is bare: the tools the run calls by name are found as the app's mise finds
  // them, and sayt's own mise (which ./saytw installs) is on its PATH for `mise trust`.
  const path = [...new Set([mise.replace(/\/mise$/, ""), `${home}/.local/share/mise/shims`, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])].join(":");
  // gcloud's `pronto` configuration, never this Mac's default one, which is the owner's other work
  // and asks to sign in again where launchd cannot answer (integrate@local's check-secrets).
  const env = { PATH: path, HOME: home, ...schedulerEnv(Deno.env.toObject(), Deno.build.os) };
  const job = { label, program: Deno.execPath(), args: ["run", "-A", `${wt}/${appRel}/release-cron/release-cron.ts`, app, "run"], poll: cron.poll,
    // Seconds the scheduler gives a stopping run before it kills it: at least the preview's `up` limit and the signal's teardown (stopSeconds), so a stop is never cut short.
    stop: stopSeconds((cron.target as { preview?: { upMinutes: number } }).preview?.upMinutes ?? 0) };
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
if (verb !== "run") throw new Error(`${verb}: run, install, uninstall, pause, resume, abandon, status, report or bisect`);

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
// What a run read as serving (null: unread), for the abandon in end(); undefined before it read.
let runLive: string | null | undefined;
let gcp: { name: string; service: string; project: string; region: string; domain?: string; rehearsal?: { job: string } } | undefined;
type Command = { release: string[]; serving: string[]; servingAfterRelease: boolean; origin: string; preview?: { up: string[]; reach: string[]; down: string[]; origin: string; upMinutes: number; when?: "after" | "first" | "beside" } };
let cron!: { steps: { prepare: string; slot: string; rehearse: string; android: string; preview: string; beside: string; release: string; confirm: string; error: string }; scheduler: { kind: string }; target: ({ kind: "command" } & Command) | { kind: "cloud-run" }; rehearsal: { command: string[] | null; slot: boolean; holder: string }; android?: { command: string[] }; notify: Notify; hooks: { on: string; command: string[] }[]; flagsReleased: string[] | null; gap: number; poll: number; branches?: { enabled: boolean; abandonHours: number; abandonAttempts: number }; watch: string[]; ready: string[]; holder: string; bisect: { command: string }; probes: Record<string, { path: string; agent?: string; status: number; has: string[]; location?: string; preview?: false }> };
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
// `red`: a failure of the rehearsal, the android step or the preview, before any release. With releaseCron.branches a run on main
// holds the release on a new branch (cut); a run on a held release's branch records its failure as an attempt (abandoning at the limits).
const end = (outcome: string, why = "", code = 0, red = false, cause = "") => {
  // After a signal, whatever the run reaches is the stop's doing, not a verdict (cron.js endWhenInterrupted): no red attempt, no gap, no bisect.
  const mapped = endWhenInterrupted(interrupted, outcome);
  if (mapped !== outcome) { why = `${outcome}: ${why}`; outcome = mapped; code = 130; red = false; cause = "signal"; }
  // Only a red verdict is an attempt: any other failure on the held branch (release, confirm, ssh, slot) records nothing, so the tip runs again.
  // The run's outcome, reason and cause are on its record before anything below that can throw (a write of `open`, a push): a throw there still
  // leaves the record with its cause.
  const settle = () => Object.assign(run, { outcome, why: why || undefined, ...(cause ? { cause } : {}) });
  if (red && outcome === outcomes.failed && run.commit) {
    settle();
    if (open) {
      const o = attempted(open, run.commit as string, "red", local(Date.now()));
      open = o;
      run.branch = o.branch;
      if (abandoned(o, Date.now(), o.limits)) {
        const shippedNote = recordShipped(o, runLive === undefined || !cron ? undefined : { live: runLive, cron });
        outcome = branchOutcome("abandoned", o.branch); why = `${why}; ${o.attempts.length} attempts, abandoned${shippedNote ? `; ${shippedNote}` : ""}`; settle(); closeOpen("abandoned"); dropBranch(o.branch, cron.notify);
      }
      else { outcome = branchOutcome("held", o.branch); why = `${why}; ${heldNotice(o.branch)}`; settle(); writeOpen(o); }
    } else if (cron?.branches?.enabled && !override && !(() => { let rel: Released | null; try { rel = readReleased(); } catch { rel = { branch: "an unreadable released-branch record", tip: "" }; } const c = cutPlan(true, false, rel, heldTrusted(real(top), real(wt))); if (!c.cut) why = `${why}; no release branch cut: ${c.why}`; return c.cut; })()) {
      // cutPlan's refusal, said above: the failure stands, no hold is cut.
    } else if (cron?.branches?.enabled && !override) {
      const branch = branchName(app, Date.now());
      const pushed = sh("git", remote(["push", "-q", "origin", `${run.commit}:refs/heads/${branch}`]), wt, {}, 120);
      if (pushed.ok) {
        const { abandonHours, abandonAttempts } = cron.branches;
        settle();
        run.branch = branch;
        writeOpen(open = { branch, base: run.commit as string, opened: local(Date.now()), limits: { abandonHours, abandonAttempts }, attempts: [{ tip: run.commit as string, verdict: "red", at: local(Date.now()) }] });
        Object.assign(run, { branch, cut: true });
        outcome = branchOutcome("held", branch);
        why = `${why}; ${heldNotice(branch)}`;
      } else why = `${why}; the release branch ${branch} could not be pushed: ${pushed.err.split("\n")[0]}`;
    }
  }
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
  if (spaced(outcome)) Deno.writeTextFileSync(`${state}/last`, `${Date.now()} ${(run.gap as number | undefined) ?? 60} ${lastFields(outcome, run.commit as string | undefined, heldRun).join(" ")}`);
  say(l);
  // A failed run starts its bisect as it ends, after the machine was given back above, so it never holds
  // release-active.
  // A cut's first failure is bisected on main as any failure is; a failure on a held release's branch is not.
  const bisects = ((outcome === outcomes.failed && !heldRun) || !!run.cut) && !!run.commit && !Deno.env.get("RELEASE_CRON_NO_BISECT");
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

// The lock: an flock on <state>/lock (lockAcquire). A lock whose run is gone is free (the kernel
// released it); one whose run lives means this run skips: launchd never overlaps its own job, and
// this keeps a run started by hand from overlapping it.
// `abandon` takes it the same way (takeLock).
{
  const taken = await takeLock();
  if (!taken.got) {
    // Logged as any run, but the lock is the other run's: left alone.
    const l = line({ app, started, steps: {}, outcome: outcomes.skipped, why: `${holderOf(taken.pid)} ${taken.pid} still going` });
    Deno.writeTextFileSync(`${state}/release-cron.log`, l + "\n", { append: true });
    console.log(l);
    Deno.exit(0);
  }
  // A preview a dead run left behind was stopped and removed before this lock was taken (reapPreview): said in this run's record.
  if (reaped) run.reaped = reaped;
}
// Read under the lock, so no other run changes it meanwhile; a record that cannot be read stops the run loudly, the lock let go first.
let released: Released | null;
try { released = readReleased(); } catch (e) { dropLock(); throw e; }

const [lastAt, lastGap, lastFailed, lastTried, lastHeldTip] = (() => { try { const [a, g, f, t, h] = Deno.readTextFileSync(`${state}/last`).trim().split(" "); return [Number(a), Number(g), f === "-" ? undefined : f, t === undefined ? (f === "-" ? undefined : f) : t === "-" ? undefined : t, h === "-" ? undefined : h]; } catch { return [NaN, NaN, undefined, undefined, undefined]; } })();

// Not due: the wake ends here, with no line (it was no run). The gap is the config of the tree last
// run, kept beside its end; the first run has none.
{
  const [at, gap, failed] = [lastAt, lastGap, lastFailed];
  // After a failed run, main as the remote has it now (git ls-remote, no fetch): moved past the
  // failed commit by a change that concerns what failed (judged), the run starts without the gap.
  const moved = () => { const r = sh("git", remote(["ls-remote", "origin", "refs/heads/main"]), wt, {}, 60); return r.ok ? r.out.split(/\s/)[0] || null : null; };
  const early = () => { const head = moved(); return !!failed && retry(failed, head) && judged(failed, head!) !== null; };
  // A held release has no gap: it is given up (abandoned) at its limits, else due only when its branch has a tip no attempt judged.
  if (open) {
    if (abandoned(open, Date.now(), open.limits)) {
      const o = open;
      if (limitPlan(dry).includes("report-abandon")) end(outcomes.dry, dryWould(`give up ${o.branch}: held since ${o.opened}, past its ${o.limits.abandonHours} h or ${o.limits.abandonAttempts} red attempts, and delete it from origin only when everything on it is on main`));
      const shippedNote = recordShipped(o);
      closeOpen("abandoned");
      // The app's gap, kept in `last` (cron.js lastFields), not the default: the main run after it waits as any run does.
      run.gap = Number.isNaN(gap) ? 60 : gap;
      dropBranch(o.branch, (() => { try { return config(wt).cron.notify as Notify; } catch { return { kind: "none" } as Notify; } })());
      end(branchOutcome("abandoned", o.branch), `held since ${o.opened}, past its ${o.limits.abandonHours} h or ${o.limits.abandonAttempts} red attempts${shippedNote ? `; ${shippedNote}` : ""}`);
    }
    const r = sh("git", remote(["ls-remote", "origin", `refs/heads/${open.branch}`]), wt, {}, 60);
    // Only a clean "not found" is no tip; a lookup that failed stops the run, reported, and is tried again next wake.
    const looked = branchTip(r.ok, r.out, r.err);
    if (looked.error) end(outcomes.skipped, `the tip of ${open.branch} could not be read on origin (${looked.error}): tried again next wake`, 1);
    const tip = looked.tip;
    // A tip refused (below) is not run again until another is pushed.
    // A tip that failed outside the rehearsal (no attempt) waits the gap before it runs again; a new tip runs at once.
    if (!heldDue(open, tip) || heldWait(lastHeldTip, tip, Date.now(), lastAt, Number.isNaN(lastGap) ? 60 : lastGap) || tip === (() => { try { return Deno.readTextFileSync(`${state}/refused`).trim(); } catch { return ""; } })()) {
      dropLock();
      Deno.exit(0);
    }
  // A run a CD job starts for a commit (RELEASE_CRON_NOW=1) has no gap to wait: the commit's push is its schedule.
  } else if (!Deno.env.get("RELEASE_CRON_NOW") && !Number.isNaN(at) && !due(Date.now(), at, Number.isNaN(gap) ? 60 : gap) && !early()) {
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
    const sig = signature(run?.why, text), flaked = flakedNames(text);
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
// When each child started (ms), and how long a preview's `up` may run on after a signal (its own limit, previewUpStep): the preview's upMinutes.
const childStart = new Map<number, number>();
let upTimeoutMs = 120 * 60_000;
// The `down` and directory of the preview now running, written beside its `up`'s pgid (previewRecord).
let previewDown: { down: string[]; dir: string } | null = null;
// Stopped: every child's group stopped and gone (killed after a minute) before the run ends and its
// lock goes, so the next run never starts beside what this one started.
// The lock goes last (signalStep): after the children are gone and a preview beside has finished its `down`, each bounded.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  Deno.addSignalListener(signal, async () => {
    if (interrupted) return;
    interrupted = true;
    const termed = new Set<number>();
    // A preview's remote `up` is not stopped now (signalStops): stopping it would end only the local ssh, the remote release going on while
    // `down` starts in the same worktree. It is waited for until its own limit (previewUpStep), its group stopped then (the recorded pid, never a
    // pattern), and `down` runs once it has exited (previewCheck awaits it); the lock goes after.
    const groups = [...children].filter(([, tag]) => signalStops(tag)).map(([pgid]) => pgid);
    const ups = [...children].filter(([, tag]) => tag === "preview").map(([pgid]) => pgid);
    for (const pgid of groups) stop(pgid, STOP_GRACE);
    if (ups.length) say(`signal: waiting for the preview's up to end (at most ${Math.round(upTimeoutMs / 60_000)} min from its start), then its process group is stopped and down runs`);
    const upLeft = Math.max(0, ...ups.map((pgid) => upExtra(Date.now() - (childStart.get(pgid) ?? Date.now()), upTimeoutMs, STOP_GRACE)));
    // `down` is given its grace and teardown from the moment `up` is gone, not from the signal (signalDone).
    let upGoneAt: number | null = null;
    for (const t = Date.now();;) {
      if (ups.length && upGoneAt === null && !ups.some((pgid) => children.has(pgid) && alive(pgid))) upGoneAt = Date.now();
      for (const pgid of ups) {
        const a = previewUpStep(children.has(pgid) && alive(pgid), Date.now() - (childStart.get(pgid) ?? Date.now()), upTimeoutMs, STOP_GRACE);
        if (a === "term" && !termed.has(pgid)) { termed.add(pgid); say(`signal: the preview's up passed its limit: its process group ${pgid} is stopped`); send(pgid, "TERM"); }
        else if (a === "kill") send(pgid, "KILL");
      }
      const s = signalStep(groups.some(alive), previews, Date.now() - t, STOP_GRACE, Number.MAX_SAFE_INTEGER / 2);
      if (s === "done" || signalDone(upGoneAt, ups.length > 0, Date.now(), t, upLeft, STOP_GRACE, TEARDOWN_GRACE)) break;
      if (s === "kill") for (const pgid of groups) if (alive(pgid)) send(pgid, "KILL");
      await new Promise((r) => setTimeout(r, 1000));
    }
    for (const pgid of children.keys()) if (alive(pgid)) send(pgid, "KILL");
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
  childStart.set(p.pid, Date.now());
  // The preview's `up` is recorded with the `down` that removes it, until that `down` has run (previewCheck): a run killed meanwhile leaves it for the
  // next lock-taker to stop and remove (reapPreview).
  // With the leader's identity (start time and boot), so a later reap signals the group only while that process is still the leader (reapSignal).
  if (tag === "preview" && previewDown) { try { const id = identityOf(p.pid); Deno.writeTextFileSync(previewRecord, JSON.stringify({ pgid: p.pid, lstart: id.lstart, boot: id.boot, ...previewDown }) + "\n"); } catch (e) { say(`the preview record ${previewRecord} was not written: ${(e as Error).message}`); } }
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
  childStart.delete(p.pid);
  // `up` has exited: the record keeps only its `down`, so a reap never signals a group the system may have given to another process.
  if (tag === "preview" && previewDown) { try { Deno.writeTextFileSync(previewRecord, JSON.stringify(previewDown) + "\n"); } catch { /* the record stays as it was */ } }
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
  upTimeoutMs = pv.upMinutes * 60_000;
  previewDown = { down: pv.down, dir };
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
    // The record is kept until `down` has run clean, so a run that dies in between leaves it for the next lock-taker.
    if (down.code === 0) { try { Deno.removeSync(previewRecord); } catch { /* none */ } }
    previewDown = null;
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
  // A held branch's tip is judged before it is checked out or trusted (PRONTO-1099): from git objects and GitHub's records, by this
  // process's own code and the trusted checkout's config, never the candidate's .mise.toml or script. A refused tip is never checked out, so
  // the scheduler's entry point (the run's worktree) stays where it was and the next wake cannot run the refused tip's script.
  // It is run only when it is the branch's own work: it descends from the cut, every commit past the cut came by a merged pull request
  // into the branch (a push straight to it is refused), and no migration changed (migrations go to main only), renames included.
  // The refusal is logged, told and no attempt; a tip is refused once, and a check that could not be made is tried again next wake.
  let candidate: string | undefined;
  if (open) {
    fetchOrigin();
    const repo = repoDir();
    const g = (...a: string[]) => must("git", ["--git-dir", repo, ...a], undefined, {}, 120);
    candidate = g("rev-parse", "--verify", `origin/${open.branch}^{commit}`);
    run.commit = candidate;
    run.branch = open.branch;
    // A scheduler that runs from the run's own checkout (top is wt) would let the candidate supply the settings and script that confirm it:
    // refused before it is checked out, in the log and in the run's `why`; held releases run from a separate trusted checkout only (README).
    const untrusted = heldTrusted(real(top), real(wt));
    if (untrusted) {
      console.log(`release-cron: ${open.branch} not run: ${untrusted}`);
      // Told once for each branch and reason (trustNotice), as the provenance refusal is; the notify settings are the trusted checkout's where one is
      // readable, else the log alone.
      if (mutates(dry)) {
        const told = (() => { try { return Deno.readTextFileSync(`${state}/trust-told`); } catch { return ""; } })();
        const n = trustNotice(told, open.branch, untrusted);
        if (n.tell) {
          const notify: Notify = (() => { try { return config(top).cron.notify as Notify; } catch (e) { console.log(`release-cron: notify settings unread (${(e as Error).message.split("\n")[0]}): the log alone`); return { kind: "none" }; } })();
          tellNote(notify, refusal(app, open.branch, candidate, untrusted), `release-cron-trust-${candidate.slice(0, 8)}.md`, "release-cron held release refused");
          Deno.writeTextFileSync(`${state}/trust-told`, n.key + "\n");
        }
      }
      end(dry ? outcomes.dry : branchOutcome("heldRefused", open.branch), dry ? dryWould(`refuse ${open.branch}: ${untrusted}`) : untrusted);
    }
    const slug = g("remote", "get-url", "origin").replace(/^.*[:/]([^/:]+\/[^/]+?)(\.git)?$/, "$1");
    const descends = sh("git", ["--git-dir", repo, "merge-base", "--is-ancestor", open.base, candidate]).ok;
    const shas = descends ? g("rev-list", `${open.base}..${candidate}`).split("\n").filter(Boolean) : [];
    const pulls: Record<string, { merged_at?: string; base?: { ref: string } }[]> = {};
    for (const sha of shas) {
      const r = sh("gh", ["api", `repos/${slug}/commits/${sha}/pulls`], undefined, {}, 120);
      if (!r.ok) end(outcomes.skipped, `the pull requests of ${sha.slice(0, 8)} could not be read (${r.err.split("\n")[0]}): tried again next wake`);
      pulls[sha] = JSON.parse(r.out || "[]");
    }
    // NUL-separated (-z): git quotes a path with a non-ASCII or special character, which a newline split would read as another name.
    const files = descends ? nulPaths(g(...heldDiffArgs(open.base, candidate))) : [];
    // The merges since the cut whose combined diff is not empty (a conflict resolution): the branch stays linear, so one refuses the tip.
    const merged = descends ? g("rev-list", "--merges", `${open.base}..${candidate}`).split("\n").filter(Boolean).map((sha) => ({ sha, cc: g("show", "--cc", "--format=", sha) })) : [];
    const why = refusedTip({ descends, unmerged: unmerged(shas, pulls, open.branch), migrations: migrationFiles(files, appRel), resolved: resolvedMerges(merged) });
    // What is done with the judged tip is heldPlan's, in order: a refused tip is refused before any checkout, and a dry run checks nothing out.
    for (const action of heldPlan(why, dry)) {
      if (action === "report-refusal") end(outcomes.dry, dryWould(`refuse ${open.branch} at ${candidate.slice(0, 8)}: ${why}`));
      else if (action === "report-checkout") end(outcomes.dry, dryWould(`check out ${open.branch} at ${candidate.slice(0, 8)} (judged: its own work), then rehearse and release it, or resume its confirmation if it already serves`));
      else if (action === "mark-refused") Deno.writeTextFileSync(`${state}/refused`, candidate + "\n");
      else if (action === "notify") {
        // The refusal's channels are the trusted checkout's (this script's own), not the refused tip's.
        const notify: Notify = (() => { try { return config(top).cron.notify as Notify; } catch (e) { console.log(`release-cron: notify settings unread (${(e as Error).message.split("\n")[0]}): the log alone`); return { kind: "none" }; } })();
        tellNote(notify, refusal(app, open.branch, candidate, why!), `release-cron-refused-${candidate.slice(0, 8)}.md`, "release-cron branch tip refused");
      } else if (action === "end-refused") end(branchOutcome("heldRefused", open.branch), why!);
    }
  }
  head = worktree(candidate);
  run.commit = head;
  // Never backwards: a ref older than the commit the last run tried (CD's newest finished ci can be
  // one, when newer runs were cancelled) would meet again what main has since fixed. Not a spaced run.
  // A `last` from before this field names it only for a failed run: runs.jsonl has the other.
  const tried = lastTried ?? jsonl(`${state}/runs.jsonl`).filter((x) => x.outcome === outcomes.released || (x.outcome === outcomes.failed && !x.branch)).at(-1)?.commit;
  if (!open && tried && behind(sh("git", ["merge-base", "--is-ancestor", head, tried], wt).ok, head, tried)) end(outcomes.skipped, `${head.slice(0, 8)} is behind ${tried.slice(0, 8)}, which the last run tried`);
  // launchd runs the worktree's script, loaded before the worktree moved to main: when main changed
  // it, this run hands over to main's, which takes the lock and goes on, so a merged fix applies to
  // the next run, not the one after. RELEASE_CRON_AGAIN keeps it to one hand-over.
  if (!open && here.startsWith(wt) && !Deno.env.get("RELEASE_CRON_AGAIN") && ["release-cron.ts", "cron.js"].map(here_).join("\0") !== loaded) {
    say("the script changed on main: running main's");
    await lockRelease(lockPath);
    const again = await new Deno.Command(Deno.execPath(), { args: ["run", "-A", `${here}release-cron.ts`, ...Deno.args], env: { RELEASE_CRON_AGAIN: "1" }, stdin: "null", stdout: "inherit", stderr: "inherit" }).spawn().status;
    Deno.exit(again.code);
  }
  ({ gcp, cron } = config(wt));
  // A held tip confirms itself by the trusted checkout's probes and serving command, not the candidate's (heldConfig).
  if (open) cron = heldConfig(cron, config(top).cron);
  run.gap = cron.gap;
  if (open) run.branch = open.branch;
  // What production serves: the commit the target's serving command prints, else Cloud Run's traffic.
  const target = cron.target.kind === "command" ? cron.target : undefined;
  // Read over ssh: a transport failure (exit 255, a connect that timed out, PRONTO-758, 07:05 BRT) is tried twice more, 20 s apart, before
  // it fails the run; any other failure fails it at once, with its exit status and stderr (servingRetryable).
  const servingNow = () => {
    for (let i = 1; ; i++) {
      const r = sh(target!.serving[0], target!.serving.slice(1), `${open ? top : wt}/${appRel}`, Deno.env.toObject(), 120);
      if (r.ok) return r.out.split(/\s+/)[0];
      const why = `${target!.serving.join(" ")} failed (exit ${r.code}): ${r.err || r.out}`;
      if (i >= 3 || !servingRetryable(r.code)) throw new Error(why);
      say(`serving unread (try ${i} of 3): ${why.split("\n").at(-1)}`); sh("sleep", ["20"], undefined, {}, 30);
    }
  };
  before = target ? servingNow() : whole(JSON.parse(gcloud(["run", "services", "describe", gcp!.service])).status?.traffic);
  const live = target ? (sh("git", ["cat-file", "-e", `${before}^{commit}`], wt).ok ? before : undefined) : base(jsonl(`${state}/runs.jsonl`), before);
  runLive = live ?? null;
  step(cron.steps.prepare);
  // A held branch's tip that is already serving: its release landed and only its confirmation did not (PRONTO-1101). The run resumes
  // at confirmation, which closes the hold and writes the released-branch record, instead of skipping with the hold left open.
  // Only a post-deployment serving marker (the target's servingAfterRelease) resumes there; a serving read of a worktree's HEAD moves before the
  // release runs, so the held release is run again (servingPlan), said here and recorded in the run.
  const afterPlan = servingPlan(open, live, head, target?.servingAfterRelease === true);
  const resumed = afterPlan === "resume";
  if (afterPlan === "rerun") { run.heldRerun = rerunWhy(open!.branch, head); say(run.heldRerun as string); }
  if (afterPlan === "skip") {
    if (mutates(dry)) run.flagsReleased = await flagsReleased(`${wt}/${appRel}`, true) ?? undefined;
    end(outcomes.skipped, `main ${head.slice(0, 8)} is serving as ${before}${mutates(dry) ? "" : "; flags not recorded (RELEASE_CRON_DRY)"}`);
  }
  if (live && !open) {
    const diff = sh("git", ["diff", "--name-only", "-z", live, head], wt);
    if (diff.ok && !changed(nulPaths(diff.out), cron.watch).length) end(outcomes.skipped, `nothing under ${cron.watch.join(", ")} changed since ${live.slice(0, 8)}, released by a run and serving as ${before}`);
  }
  // A release from a held branch must not be lost: before main is released, every commit of the last branch released (kept in
  // <state>/released-branch) has its counterpart on main (a cherry-pick -x line or an equal patch id; a merge whose resolution changed code
  // has none), checked against `head`, the commit this run releases, else this run waits and says which. Once they all are, the branch is
  // deleted from origin, only as the tip released (an explicit lease), and a branch pushed to since stays with its record.
  // On every run that can deploy main, whatever ref it names (RELEASE_CRON_REF too), against `head`, the exact commit it releases (backportCheck).
  if (backportCheck(open, released) && released) {
    // A fetch or git failure here is not a failed run: it ends skipped, and the next wake checks again.
    let missing: { sha: string; body: string }[] = [];
    try { missing = missingOnMain(released.tip, head); } catch (e) { end(outcomes.skipped, `the backport check of ${released.branch} could not be made (${(e as Error).message.split("\n")[0]}): tried again next wake`); }
    // What follows is backportPlan's, in order: wait and tell once, or delete (a dry run reports and does neither).
    const key = `${released.branch} ${missing.map((c) => c.sha).join(" ")}`;
    const told = (() => { try { return Deno.readTextFileSync(`${state}/backport-told`).trim(); } catch { return ""; } })();
    for (const action of backportPlan(missing, told === key, dry)) {
      if (action === "tell") tellNote(cron.notify, `release-cron (${app}) will not release main until the fixes released from ${released.branch} are on main: ${backportWhy(missing)}. Cherry-pick each with -x (git cherry-pick -x <sha>) in a PR to main; the next wake checks again.`, `release-cron-backport-${released.branch.split("/").at(-1)}.md`, "release-cron backport missing");
      else if (action === "mark-told") Deno.writeTextFileSync(`${state}/backport-told`, key + "\n");
      else if (action === "end-held-backport") end(branchOutcome("heldBackport", released.branch), backportWhy(missing));
      else if (action === "report-delete") say(dryWould(`delete ${released.branch} from origin as ${released.tip.slice(0, 8)}: every commit is on main`));
      else if (action === "delete-branch") {
        let gone: boolean | "unknown" = false;
        try { gone = deleteBranch(released.branch, released.tip, cron.notify); } catch (e) { say(`${released.branch} not deleted: ${(e as Error).message.split("\n")[0]}`); }
        if (gone === true) {
          say(`${released.branch}: every commit is on main, the branch deleted from origin`);
          for (const f of ["released-branch", "backport-told"]) { try { Deno.removeSync(`${state}/${f}`); } catch { /* none */ } }
        } else say(`${released.branch} kept on origin, and its record: the next wake checks again`);
      }
    }
  }
  // RELEASE_CRON_DRY=android runs only the android step below, in place of the rehearsal and the preview.
  if (dry && (dry !== "android" || resumed)) end(outcomes.dry, resumed ? dryWould(`resume the confirmation of ${head.slice(0, 8)}, serving as ${before}, and close ${open!.branch}`) : `would rehearse and release ${head.slice(0, 8)}: it differs from ${live?.slice(0, 8) ?? "an unknown commit"}, serving as ${before}`);
  say(`${head.slice(0, 8)} differs from what serves (${live ? live.slice(0, 8) : `unknown: no run that released confirmed ${before}`}): rehearsing`);

  const dir = `${wt}/${appRel}`;
  // A held tip already serving (`resumed`) goes straight to confirmation: it is neither rehearsed nor released again.
  if (resumed) say(`${head.slice(0, 8)} of ${open!.branch} is already serving as ${before}: resuming at confirmation`);
  else {
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
      const readLive = (() => { if (!target || !own || dry) return live; const r = sh(target.serving[0], target.serving.slice(1), `${open ? top : wt}/${appRel}`, Deno.env.toObject(), 20); const c = r.ok ? r.out.split(/\s+/)[0] : ""; return c && sh("git", ["cat-file", "-e", `${c}^{commit}`], wt).ok ? c : undefined; })();
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
      if (bad.length) { const f = failureOf("previewFailed", { bad, stopped: false }); end(outcomes.failed, f.why, 1, true, f.cause); }
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
      // A rehearsal the preview's failure stopped (it ended without passing) is no verdict of the tree: no attempt, no branch (red),
      // and no bisect (noVerdictRun). One that passed before the stop landed is a verdict, and the preview's failure is red as in "after".
      const stopped = rehearsalStopped && r.code !== 0;
      const o = besideOutcome(r, p, stopped);
      if (o.failed === "preview") { const f = failureOf("previewFailed", { bad: p.bad, stopped }); end(outcomes.failed, f.why, 1, !stopped, f.cause); }
      // The rehearsal failed first: the preview was cut short, but a failed `down` (a preview left standing) is said in the run's reason.
      if (cancel.stopped) downFailed = p.bad.filter((b) => b.startsWith("removing the preview")).map((b) => `; ${b}`).join("");
      outcome = rehearsalResult!;
    } else outcome = await rehearsalRun();
    const { gate, got } = outcome;
    // Exit 3 before its slot (a ledger key it could not read, a start mark it could not write) is no verdict as well.
    // So is a rehearsal stopped by a signal (130, or killed: 128 and above), the machine's doing, not the tree's.
    // And a rehearsal its wrapper timed out (124, timeout(1): Studio's integrate@k8s).
    const noVerdict = noVerdictExit(gate.code);
    if (!got) { if (!beside) step(cron.steps.slot); const f = failureOf("beforeSlot", { noVerdict, command: rehearse!.slice(1).join(" ") || rehearse![0], code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, false, f.cause); }
    if (own && !dry && !beside) step(cron.steps.rehearse);
    // Exit 3 is the rehearsal's "no verdict" (a verdict or record it could not read or write, the checkout changed): nothing
    // is released, and the bisect never takes it up (noVerdictRun), since it says nothing of a commit; no release branch is cut for it.
    if (noVerdict) { const f = failureOf("noVerdict", { code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, false, f.cause); }
    if (gate.code !== 0) { const f = failureOf("rehearsalFailed", { code: gate.code, downFailed }); end(outcomes.failed, f.why, 1, true, f.cause); }

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
      if (phoneRun.code !== 0) end(outcomes.failed, androidWhy(phoneRun.code, failedNames), 1, true);
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
      if (bad.length) { const f = failureOf("previewFailed", { bad, stopped: false }); end(outcomes.failed, f.why, 1, true, f.cause); }
    }

    // The tree the rehearsal and the preview ran on is the tree released: the preview ran before or beside the rehearsal, so
    // the worktree must not have moved meanwhile.
    if (pv && when !== "after") {
      const now = must("git", ["rev-parse", "HEAD"], wt);
      if (now !== head) { const f = failureOf("treeMoved", { from: head.slice(0, 8), to: now.slice(0, 8) }); end(outcomes.failed, f.why, 1, false, f.cause); }
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
        try { now = servingNow(); } catch (e) { say(`serving unread: ${(e as Error).message.split("\n").at(-1)}`); continue; }
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
  // The held release, if this run was it, is released: closed with the commit it released.
  if (open) {
    Deno.writeTextFileSync(`${state}/released-branch`, JSON.stringify({ branch: open.branch, tip: head }) + "\n");
    closeOpen("released", head);
  }
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
  end(outcomes.released, !target && run.revision === before ? `same image, nothing served changed: ${before} kept` : "");
} catch (e) {
  step(cron?.steps.error ?? "error");
  const why = (e as Error).message.split("\n")[0];
  end(outcomes.failed, appendWhy(run.why as string | undefined, why), 1, false, why === causes.signal ? "signal" : "");
}

// releaseCron.flagsReleased: records which flags the release now served reads, so a flag push keeps one it still reads
// (pronto-flags `released`). Whatever it does, the run's outcome stays: a failure is said and never fails the run. The commit
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
