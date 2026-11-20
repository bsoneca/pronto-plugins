// A slot: one of several local stacks on one machine at once, of this app or any other, each on
// ports of its own. The same file in every app with a local stack, copied unchanged, and frozen: a
// byte-identity guard (tests/lint.ts, guard-slot) fails an app whose copy differs from
// apps/brawl-chess's, and ci checks one app, not all, when only the shared copies change.
//
// It is a static semaphore, nothing more (docs/queue-research-2026-11-07.md): GitHub's runner pools
// cap who may start, this file only keeps stacks off each other's ports and the `cue` evaluations off
// the machine's memory, by what each claims. It measures nothing before it admits: no load, no cores, no
// memory (a cue's own resident size is read while it runs, to correct its claim; the machine's free
// memory is read once, as a veto on starting another evaluation).
//
//   Ports. Slot n's ports are 33000 + 100·(n-1) onward: the door (CADDY_DOOR_PORT, and
//   CADDY_TLS_HOST_PORT, which ORIGIN names) first, then each ${<VAR>_PORT:-<n>} variable of
//   .bayt/process-compose.yaml by name, then each port it writes as a literal by number. Above the
//   10000-32767 bayt and pronto-identity hash an app's ports into, below macOS's ephemeral 49152: 160
//   slots, none another's, whichever app holds it. The stack runs from the slot's own copy of the app
//   (<pool>/slot-<n>/app): every entry a link to the checkout's, but .bayt/process-compose.yaml,
//   written with the slot's ports. A slot is held as <pool>/slot-<n>/pid (STACK_POOL, else
//   /tmp/pronto-stacks); STACK_SLOT=<n> asks for one by number (a command run under tests/slot.ts is
//   given its slot there; a claim of its own for that number fails at once, naming the holder).
//
//   Weight. A holder declares its weight, a plain count: a launch ½ (it idles), a stack 1, a gate 3
//   (integrate@local with the few `slow` scenarios throttled: about 2.9 cores on average in a timed Bonk Chess run of
//   2026-11-19, 3555 s of CPU over the 1225 s it held its claim with every scenario, and 2.25-2.6 per gate by app
//   from the machine's busy cores against the live claims over 2026-11-08..19, PRONTO-841), a rehearsal 6, a scenarios pass 6,
//   its Premium lane 2; STACK_WEIGHT=<n> or --weight <n> names another. The budget is fixed:
//   STACK_BUDGET, else every core but STACK_RESERVE (3): 15 on an 18-core Mac. A claim is admitted
//   when the weight held, the weight of every live ticket older than its own (they reserve their room)
//   and its own fit the budget; the oldest ticket is admitted on an empty pool whatever it weighs.
//   First come first served, so a heavy claim is never starved by lighter ones. There is no release
//   lane and no ci lane (STACK_RELEASE_LANE, STACK_CI_LANE are accepted and ignored): GitHub's runner
//   pools separate release, gate and ci, not this file. The one priority is a release's hold (below).
//
//   Reclaim. Every claim, under the pool's lock, frees what dead pids left: job-<pid> dirs, queue
//   tickets, and slot-<n> dirs whose holder is gone and no port of whose range answers (a stack
//   orphaned by a killed holder keeps its slot until it is down; a claim refused a slot names what
//   listens there, its pid and its parent). On a Mac it also removes the System V shared
//   memory segments dead postgres left (leakedSegments), of which the machine has only 32.
//
//   Run folders. A launch's and a gate's work folders (slot.<pid>.*, gate.<pid>.*) live in STACK_RUNS,
//   else ~/.cache/pronto/stacks, not $TMPDIR, whose old files macOS deletes at 03:35 (PRONTO-851); a
//   claim removes those whose pid is dead and that are a day old.
//
//   Nested. A claim with a live holder above it (by the process tree, or STACK_JOB, the job that ran
//   it, or STACK_SLOT, the slot of the command it runs under) is admitted at once inside that
//   holder's weight: it adds none (its record says weight 0 and `in=<holder>`), takes no ticket, and
//   a stack still gets a free slot of its own, for its ports. A claim that waited for its own holder
//   would wait for ever (2026-11-07 09:22 BRT).
//
//   A release holds the machine (PRONTO-894; the owner, 2026-11-19: "Gates wait"). While a claim made
//   with STACK_PRIORITY=release and a weight above 0 holds or waits (its record says `prio=release`, its
//   ticket `prio=release`), every other claim with a weight above 0 waits, GitHub Actions jobs too (load was
//   90-131 on 2026-11-19 with a rehearsal and runner jobs at once). A waiting claim's STACK_WAIT_MINUTES
//   deadline is reset while a release holds it, and its message names the release. Beside a running rehearsal
//   (the owner, 2026-11-20: "Admit while there's room"): while a release holds a slot and none waits for one, a
//   held claim is admitted, a runner job too, while the machine's load1 (Deno.loadavg, as release-cron reads it) is
//   under STACK_HOLD_LOAD (else one per core: 18 here) and its weight fits the budget beside the holders and the
//   tickets older than its own; at or over it, it waits. A release that waits keeps its room. Not held: weight-0
//   claims (cue memory alone, watches) and nested claims. A release claim waits only for room beside the
//   running holders: it skips the tickets of other claims ahead of it, counting older releases only (so
//   does a claim a release holds, whose own `ahead` is only the releases'). A release counts only
//   while its process started before its record or ticket was written (a pid reused by another process
//   is no release) and for STACK_RELEASE_HOLD_MAX hours (else 12) from that write: a hung or stale release
//   stops holding, and the claims it held then fail at STACK_WAIT_MINUTES as before.
//   Another account's release (PRONTO-762: pull-request jobs run as pronto-pr, with a pool of its own,
//   beside the owner's): STACK_HOLD_POOL, a pool path, and STACK_HOLD_UID, the numeric uid that must own it,
//   make a claim also held by a live release record there, by the same rule and message, with the same wait
//   deadline reset and the same hours cap. It is read-only and follows no link (every dir and file is lstat-ed
//   and must be a real one of that uid; the file is opened and its handle's dev and ino must be the lstat's),
//   reads a few KB of it, and writes nothing there. Its process must live and have started no later than the
//   record, and it reads the release's waiting tickets (queue/, cue-queue/) by the same rules. STACK_HOLD_UID is
//   digits and not this account's; either variable unset: no change. Only a weighted claim that is no release reads
//   it. It is cooperative: it orders honest pull-request jobs, and a job's code can skip its own slot.ts, so it is
//   no security boundary. Its hours cap can be extended by a release's mem sampler renaming its record, as the
//   local pool's is.
//
//   This account's own pool (and its queue/, cue-queue/, slot and job dirs) must be a real directory of this uid
//   that no other account can write, or a claim refuses it and writes nothing (another account could have made
//   the path first, after a reboot, and planted links to write through).
//   Without a release, a claim made inside a GitHub Actions job (GITHUB_ACTIONS=true: ci's checks,
//   gate.yml's gates) is admitted at once on cores, its weight still held: the runner pools are its
//   cap (docs/queue.md), and a job holding a runner while it waits here queues twice. The cue memory
//   budget still applies, and so does the weight budget to a top-level cue's cores (--mem with
//   --weight, PRONTO-761/837): a runner's evaluation waits for them as any other.
//
//   Cue memory (PRONTO-870, which replaced the cue lock: a gate's generate queued 44 of 92 minutes
//   behind it for about one minute of work, on a 128 GB Mac whose learned peaks are p95 0.5 GB, p99
//   2.2 GB, largest 26.7 GB). A job that names --mem <GB> (the cue wrapper, machine/cue: an evaluation
//   of up to tens of GB; 21 at once ran macOS out of memory on 2026-11-05) claims that memory from a
//   budget of its own, CUE_MEM_GB (64), and --cores-claim <n> of CUE_CORES (every core but
//   STACK_RESERVE): several evaluations run at once while their claims fit. The line is <pool>/cue-queue,
//   nested or not, strictly first come first served: a claim is admitted when the memory held by the live
//   holders, the memory reserved by every ticket older than its own and its own fit the budget, and the
//   same for its cores; the oldest ticket is admitted on an empty pool whatever it claims. A small claim
//   never passes a large one waiting ahead (no starvation). A holder's record is
//   "<pid> <weight> cue mem=<GB> cores=<n>", its ticket "<weight> [nested=1 ]mem=<GB> cores=<n> <what>":
//   a record or ticket without mem= (a copy of this file from before the budget) claims the whole of
//   CUE_MEM_GB, which is the old lock. While the job runs it rewrites its record every second with
//   mem=max(claim, resident size), so an evaluation grown past its claim counts at its real size, and
//   writes job-<pid>/child, the process it runs: a holder alive whose child has been dead for 60 s is
//   stuck, counts for no memory, and is logged. While kern.memorystatus_level is under CUE_MIN_FREE_PCT
//   (20) no claim is admitted but the head of the line on a pool holding no cue memory. Cue cores stay
//   outside the stacks' weight budget (PRONTO-838). --weight <n> beside --mem makes it weigh cores in that
//   weight too (an evaluation keeps several busy: a ~9 core one ran at weight 0 on 2026-11-18): one that
//   is not nested is then one ticket in both lines, the cores' and the cue line's, admitted under the
//   pool's lock only when both admit, so it holds nothing while it waits. A nested one (a holder above
//   it) weighs none and waits in the cue line behind the nested tickets older than its own only: waiting
//   behind a top-level ticket that waits for the cores its own holder keeps would wait for ever. Without
//   --weight a --mem job weighs none, as before. --mem-learn <file> writes its peak (GB) there at the
//   end, for the wrapper's next run; --cores-learn <file> the cores it kept busy (the CPU seconds of the
//   command over its seconds since it started, once it ran 5 s: a run that failed only raises it);
//   --wait-out <file> the seconds from its ticket to its admission. A job the memory watchdog
//   (machine/watchdog.sh) killed under pressure, not for its own size, waits its turn again, once.
//
//   A claim that does not wait (claim(..., false), as a rehearsal's extra lanes) is asked once, in its
//   place in the line, and gives back no slot when it is not admitted then. The wait has no
//   wall-clock limit but progress: a claim fails after STACK_WAIT_MINUTES (else 120) in which no
//   ticket ahead of it left and no weight held dropped.
//
//   deno run -A tests/slot.ts <command...>   the command on a slot, in the slot's copy, with
//                                            APP_URL, ORIGIN and every port variable set
//   deno run -A tests/slot.ts launch         the stack itself, as launch@local, until stopped
//   deno run -A tests/slot.ts launch --watch the same, warm: an edit lands without a relaunch
//   deno run -A tests/slot.ts ./saytw launch@local
//                                            generate and build in the checkout, then launch
//   deno run -A tests/slot.ts ./saytw integrate@host
//                                            generate and build in the checkout, then integrate@host's
//                                            suites in the slot's copy (an engineer's local gate)
//   deno run -A tests/slot.ts ./saytw integrate@local
//                                            the same host tier, as the gate runs it (PRONTO-470): the
//                                            gate's secrets check, the last release's database, the
//                                            visual lint slowed, and the pass stamped (`gate`, below)
//   deno run -A tests/slot.ts --weight <n> --what "<label>" -- <command...>
//                                            claims <n> of the budget, no stack, no ports moved, runs
//                                            the command where it is, releases on exit (a job is held
//                                            as <pool>/job-<pid>)
//
// A launch is a stack kept up for someone to use, and forgotten: three of them held slots for 16 h
// after their sessions were gone. So it ends after an hour (STACK_LAUNCH_TTL seconds, 3600; 0 =
// none): at the deadline it stops its stack, frees the slot, and logs what it stopped to stderr and
// to the slot's owner file. The deadline is <pool>/slot-<n>/deadline (ms since the epoch);
// `renew [<slot n>|<pid>]` pushes it to now + the TTL. Only a launch has one.
//
//   deno run -A tests/slot.ts status         the slots held: holder, what, since when, deadline
//   deno run -A tests/slot.ts renew [n|pid]  a launch's deadline to now + STACK_LAUNCH_TTL
//   deno run -A tests/slot.ts sweep-browsers playwright's browsers (ms-playwright cache) whose owner is gone
//                                            (ppid 1) and that are older than 30 min, killed and logged
//
// Browsers (PRONTO-450). A claim's release kills every ms-playwright browser in its process tree, and
// every claim sweeps the orphans first (and, for a claim that died, the ones started since it began).
// Only the cache's browsers whose owner is the claim or gone: never the user's own Chrome. The runners
// close their own (tests/browser.ts); this is the machine's side of it.
//
// The run owner (PRONTO-684). A job, a gate and a launch run their command as the root of a run this process owns, and
// when the command ends (passes, fails, times out, or gets INT, TERM or HUP) everything it started ends with it, however
// it hid (a double fork, setsid, a parent that exited first, an Apple binary): the kernel's responsible pid on a Mac, a child
// subreaper on Linux (ownRun, below). What is left after TERM and KILL fails the run, named. A claim inside a live run does not
// own: it runs its command as before, and the outer owner covers it.
//
//   deno run -A tests/slot.ts own [--what <label>] [--grace <s>] [--timeout <s>] [--root-out <file>] -- <command...>
//                                            the owner alone, no claim: ends 130 on INT or TERM, 129 on HUP, 124 on --timeout
//   deno run -A tests/slot.ts detach --what <label> -- <command...>
//                                            a command that joins no run (colima's VM, which outlives the run that started it)
//   deno run -A tests/slot.ts member <root pid> <pid>   exits 0 when <pid> is in the run of <root pid>, 1 when not
//   deno run -A tests/slot.ts leftovers      what runs whose owner is gone left behind (it only reports, for now)
//
// Run inside the app's toolchain (mise exec), which has process-compose, as the verbs are.

const app = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const pool = Deno.env.get("STACK_POOL") ?? "/tmp/pronto-stacks";
const budget = Number(Deno.env.get("STACK_BUDGET") ?? Math.max(1, navigator.hardwareConcurrency - Number(Deno.env.get("STACK_RESERVE") ?? 3)));
const asked = Number(Deno.env.get("STACK_SLOT") ?? "0");
// The cue memory budget (GB) and cores (PRONTO-870): what the evaluations claimed through --mem and --cores-claim may add up to.
// A value that is not a finite number above 0 is the default.
const positive = (v: string | undefined, def: number) => { const n = v === undefined || v.trim() === "" ? NaN : Number(v); return Number.isFinite(n) && n > 0 ? n : def; };
const cueMem = positive(Deno.env.get("CUE_MEM_GB"), 64);
// The machine's one-minute load, as release-cron reads it. A failed read throws with its cause: a claim a release holds
// keeps moving its deadline, so a read that failed every poll would hold it through the whole release (PRONTO-1020).
export function load1(read: () => number[] = () => Deno.loadavg()): number {
  let v: number | undefined;
  try {
    v = read()[0];
  } catch (e) {
    throw new Error(`load1 could not be read beside a release (Deno.loadavg): ${e instanceof Error ? e.message : String(e)}`, { cause: e });
  }
  if (!Number.isFinite(v)) throw new Error(`load1 could not be read beside a release (Deno.loadavg): no number, got ${v}`);
  return v as number;
}

// The load1 under which a claim a release holds is admitted beside a running rehearsal: one per core (besideRelease).
const holdLoad = positive(Deno.env.get("STACK_HOLD_LOAD"), navigator.hardwareConcurrency);
const cueCores = positive(Deno.env.get("CUE_CORES"), Math.max(1, navigator.hardwareConcurrency - Number(Deno.env.get("STACK_RESERVE") ?? 3)));
const say = (s: string) => console.error(`slot: ${s}`);

// queued and admitted: when the claim asked for its slot and when it got it (ms since the epoch).
export type Slot = { n: number; dir: string; door: number; env: Record<string, string>; release: () => void; queued: number; admitted: number };

// The slot's ports, from the app's process-compose: the variables and the literals, each its own.
export const layout = (compose: string, n: number) => {
  const base = 33000 + 100 * (n - 1);
  const doors = ["CADDY_DOOR_PORT", "CADDY_TLS_HOST_PORT"];
  const vars = [...new Set([...compose.matchAll(/\$\{([A-Z0-9_]+_PORT):-[0-9]+\}/g)].map((m) => m[1]))].filter((v) => !doors.includes(v)).sort();
  const literals = [...new Set([
    ...compose.matchAll(/[A-Z_]*PORT=([0-9]{4,5})\b/g),
    ...compose.matchAll(/--[a-z-]*port ([0-9]{4,5})\b/g),
    ...compose.matchAll(/(?:localhost|127\.0\.0\.1):([0-9]{4,5})\b/g),
  ].map((m) => Number(m[1])))].sort((a, b) => a - b);
  if (1 + vars.length + literals.length > 100) throw new Error("more than 100 ports in .bayt/process-compose.yaml");
  const ports: Record<string, number> = Object.fromEntries(doors.map((v) => [v, base]));
  vars.forEach((v, i) => ports[v] = base + 1 + i);
  const moved = new Map(literals.map((p, i) => [p, base + 1 + vars.length + i]));
  const text = compose
    .replace(new RegExp(`\\b(${literals.join("|") || "$^"})\\b`, "g"), (p) => String(moved.get(Number(p))))
    .replace(/\$\{([A-Z0-9_]+_PORT):-[0-9]+\}/g, (m, v) => ports[v] ? `\${${v}:-${ports[v]}}` : m);
  return { door: base, ports, moved, text };
};

// The PATH the children get, with mise on it: their commands run through `mise exec`, and without
// it process-compose exits at once. Where mise is, the way ./saytw finds it: on the PATH; else the
// SAYT_MISE_BIN saytw exported; else the newest (by version, numerically) mise-v* sayt cached, in
// the cache dir of the OS (~/Library/Caches/sayt on a Mac, $XDG_CACHE_HOME or ~/.cache/sayt on Linux),
// whichever of the two the machine has. A process whose PATH is bare, as a game's launch inside Studio
// can be, still finds it; with none of them it says so, naming what it looked in.
export function miseDirIn(env: Record<string, string | undefined>, isMise: (dir: string) => boolean, list: (dir: string) => string[]): { dir: string | null; looked: string[] } {
  const path = env.PATH ?? "";
  if (path.split(":").some((d) => d && isMise(d))) return { dir: null, looked: [] };
  const looked: string[] = [];
  const bin = env.SAYT_MISE_BIN;
  if (bin && bin.includes("/")) {
    const dir = bin.slice(0, bin.lastIndexOf("/"));
    looked.push(bin);
    if (isMise(dir)) return { dir, looked };
  }
  const home = env.HOME ?? "";
  const caches = [...new Set([env.XDG_CACHE_HOME ? `${env.XDG_CACHE_HOME}/sayt` : "", home ? `${home}/Library/Caches/sayt` : "", home ? `${home}/.cache/sayt` : ""].filter(Boolean))];
  const version = (name: string) => name.slice(6).split(".").map(Number);
  const newest = (a: string, b: string) => {
    const [x, y] = [version(a), version(b)];
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (y[i] ?? 0) - (x[i] ?? 0);
    return 0;
  };
  for (const cache of caches) {
    looked.push(cache);
    let names: string[] = [];
    try { names = list(cache).filter((n) => /^mise-v[0-9]/.test(n) && isMise(`${cache}/${n}`)); } catch { /* none cached */ }
    if (names.length) return { dir: `${cache}/${names.sort(newest)[0]}`, looked };
  }
  return { dir: null, looked };
}
const misePath = (): string => {
  const env = Deno.env.toObject();
  const isMise = (dir: string) => { try { return ((Deno.statSync(`${dir}/mise`).mode ?? 0) & 0o111) !== 0; } catch { return false; } };
  const { dir, looked } = miseDirIn(env, isMise, (d) => [...Deno.readDirSync(d)].map((e) => e.name));
  const path = env.PATH ?? "";
  if (dir) return `${dir}:${path}`;
  if (looked.length) { console.error(`mise not found: run ./saytw once, or add mise to PATH (looked in ${looked.join(", ")})`); Deno.exit(1); }
  return path;
};

// kill -0 answers "no such process" only for a pid that is gone. A holder another account
// started is alive too, though kill -0 on it fails (EPERM): not ps, which a sandbox cannot spawn
// (setuid), and the reason read in the C locale.
const alive = async (pid: number) => {
  if (pid <= 0) return false;
  const { code, stderr } = await new Deno.Command("kill", { args: ["-0", String(pid)], env: { LC_ALL: "C" }, stderr: "piped" }).output();
  return code === 0 || /not permitted/i.test(new TextDecoder().decode(stderr));
};
// Where a stack's and a gate's run folders live: not $TMPDIR, whose files older than 3 days macOS's
// dirhelper deletes at 03:35, and a running stack's served tree (copied keeping old mtimes) lost its
// static files that way (PRONTO-851). The names stay short: a unix-socket path has a length limit.
export async function runDir(prefix: string): Promise<string> {
  const base = runsBase();
  await Deno.mkdir(base, { recursive: true });
  return Deno.makeTempDir({ dir: base, prefix: `${prefix}${Deno.pid}.` });
}
const runsBase = () => {
  const home = Deno.env.get("HOME");
  if (!Deno.env.get("STACK_RUNS") && !home) throw new Error("slot: neither STACK_RUNS nor HOME is set, so a run folder has nowhere to live");
  return Deno.env.get("STACK_RUNS") ?? `${home}/.cache/pronto/stacks`;
};
// The run folders (<prefix>.<pid>.<suffix>) whose pid is dead and whose mtime (ms, in `mtimes`) is
// older than keepMs: a failed launch's log is kept a day.
export function staleRuns(names: string[], isDead: (pid: number) => boolean, mtimes: Record<string, number>, now: number, keepMs: number): string[] {
  // Only folders runDir made (slot., gate., rehearse.) are ever reaped, wherever STACK_RUNS points.
  return names.filter((name) => {
    if (!/^(slot|gate|rehearse)\./.test(name)) return false;
    const pid = name.split(".").slice(1).find((part) => /^\d+$/.test(part));
    return pid !== undefined && isDead(Number(pid)) && (mtimes[name] ?? now) < now - keepMs;
  });
}
// Removes them; cheap, and never throws.
async function reapRuns(): Promise<void> {
  try {
    const base = runsBase(), names: string[] = [], mtimes: Record<string, number> = {};
    for await (const e of Deno.readDir(base)) {
      names.push(e.name);
      const m = (await Deno.stat(`${base}/${e.name}`).catch(() => null))?.mtime;
      if (m) mtimes[e.name] = m.getTime();
    }
    // Only a folder a day old is asked whether its pid lives (a `kill -0` each): fresh ones are kept anyway.
    const now = Date.now(), keep = 24 * 3600_000, old = names.filter((n) => (mtimes[n] ?? now) < now - keep);
    const dead = new Set<number>();
    for (const pid of new Set(old.map((n) => Number(n.split(".").slice(1).find((part) => /^\d+$/.test(part)))))) {
      if (pid && !await alive(pid)) dead.add(pid);
    }
    for (const name of staleRuns(old, (pid) => dead.has(pid), mtimes, now, keep)) {
      await Deno.remove(`${base}/${name}`, { recursive: true }).catch(() => {});
    }
  } catch { /* no runs folder, or unreadable: nothing to reap */ }
}
// The System V shared memory segments a dead postgres left. Every postgres cluster takes one (its
// interlock), and macOS allows 32 on the whole machine (kern.sysv.shmmni): one killed without its
// cleanup keeps its segment, attached to nothing, until it is removed, and a full machine's next
// postgres then fails at start (a published game's database in Studio's gate, 2026-11-08 15:56 BRT,
// PRONTO-40). From `ipcs -m -o -p` (columns T ID KEY MODE OWNER GROUP NATTCH CPID LPID): the ids of
// `user`'s segments attached to nothing whose creator and last user are both among the `dead` pids.
export function leakedSegments(ipcs: string, user: string, dead: readonly number[]): string[] {
  const gone = (pid: number) => dead.includes(pid);
  const ids: string[] = [];
  for (const line of ipcs.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f[0] !== "m" || f.length < 9) continue;
    const [, id, , , owner, , nattch, cpid, lpid] = f;
    if (owner === user && nattch === "0" && gone(Number(cpid)) && gone(Number(lpid))) ids.push(id);
  }
  return ids;
}
// Removes them, on a Mac (Linux allows thousands); a failure leaves them for the next claim.
async function reclaimSegments(): Promise<void> {
  if (Deno.build.os !== "darwin") return;
  const user = Deno.env.get("USER") ?? "";
  const out = await new Deno.Command("ipcs", { args: ["-m", "-o", "-p"], stdout: "piped", stderr: "null" }).output().catch(() => null);
  if (!user || !out?.success) return;
  const text = new TextDecoder().decode(out.stdout);
  const dead = new Set<number>();
  for (const line of text.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f[0] === "m" && f[6] === "0") for (const pid of [Number(f[7]), Number(f[8])]) if (!await alive(pid)) dead.add(pid);
  }
  for (const id of leakedSegments(text, user, [...dead])) {
    await new Deno.Command("ipcrm", { args: ["-m", id], stdout: "null", stderr: "null" }).output().catch(() => {});
  }
}
// The System V segments free on the machine: the limit (kern.sysv.shmmni) less those in use, from
// `ipcs -m` (live and leaked alike). A stack's postgres needs one to start, so a stack waits in line
// while none is free, rather than start a database that exits at once (PRONTO-39: 21 of 32 in use on
// 2026-11-08, 9 held by orphaned stacks; tools/sysv-shm/install.sh raises the limit, once, as root).
export function segmentsFree(ipcs: string, limit: number): number {
  const used = ipcs.split("\n").filter((l) => l.trim().split(/\s+/)[0] === "m").length;
  return limit - used;
}
// A system tool's output, or null when it fails (`sysctl`, `ipcs`: what the image needs is held by its own check).
const run = async (cmd: string, args: string[]) => {
  const out = await new Deno.Command(cmd, { args, stdout: "piped", stderr: "null" }).output().catch(() => null);
  return out?.success ? new TextDecoder().decode(out.stdout) : null;
};
async function freeSegments(): Promise<{ free: number; limit: number } | null> {
  if (Deno.build.os !== "darwin") return null;
  const limit = Number((await run("sysctl", ["-n", "kern.sysv.shmmni"]))?.trim());
  const ipcs = await run("ipcs", ["-m"]);
  return limit > 0 && ipcs !== null ? { free: segmentsFree(ipcs, limit), limit } : null;
}
// The share of the machine's memory still available (kern.memorystatus_level, %), on a Mac; null elsewhere or when unreadable.
const freeMemoryPct = async (): Promise<number | null> => {
  if (Deno.build.os !== "darwin") return null;
  const out = await run("sysctl", ["-n", "kern.memorystatus_level"]);
  const n = out === null ? NaN : Number(out.trim());
  return Number.isFinite(n) ? n : null;
};
// Whether the release a record or ticket written at `written` names is real: its process `pid` started before
// the write, and the write is within STACK_RELEASE_HOLD_MAX hours. Asked only of release-marked entries.
// What ps says of a (pid, write) is asked once per process: a release's ps outcome does not change.
const started = new Map<string, Promise<boolean>>();
const warnedPs = new Set<number>();
const releaseReal = async (pid: number, written: number) => {
  const hours = Number(Deno.env.get("STACK_RELEASE_HOLD_MAX") ?? 12);
  if (!releaseFresh(written, Date.now(), Number.isFinite(hours) ? hours : 12)) return false;
  const key = `${pid}:${written}`;
  if (!started.has(key)) started.set(key, (async () => {
    let ps: { out: string; ok: boolean; error?: string };
    try {
      const r = await new Deno.Command("ps", { args: ["-o", "lstart=", "-p", String(pid)], env: { LC_ALL: "C" }, stdout: "piped", stderr: "piped" }).output();
      ps = { out: new TextDecoder().decode(r.stdout), ok: r.success, error: new TextDecoder().decode(r.stderr).trim() || undefined };
    } catch (e) {
      ps = { out: "", ok: false, error: `ps did not run: ${e instanceof Error ? e.message : e}` };
    }
    const r = psStart(ps, pid, await alive(pid));
    if ("gone" in r) return false;
    if ("unreadable" in r) {
      if (!warnedPs.has(pid)) { warnedPs.add(pid); say(`${r.unreadable}: counted as a release`); }
      return true;
    }
    return startedBefore(r.at, written);
  })());
  return await started.get(key)!;
};
const holder = async (name: string) => Number(await Deno.readTextFile(`${pool}/${name}/pid`).catch(() => "0"));
// The weights a holder declares: a launch (idle between the clicks of whoever plays it: 0.32 core on
// average, 0.53 at p90), a stack, a rehearsal, and each lane a rehearsal adds to its own
// (tests/rehearse.ts), a scenarios pass's or Premium's.
export const weights = { launch: 0.5, stack: 1, rehearsal: 6, pass: 6, premium: 2, gate: 3 };
// What a command run under slot.ts weighs when STACK_WEIGHT names none: a launch, a stack, or, for an
// integrate@local whose pages will run throttled, the stack and those pages (weights.pass). It mirrors
// tests/slow.ts: SLOW named (not 0 or empty) throttles every scenario's pages, weights.pass; SLOW unset
// in the local gate (INTEGRATE_LOCAL_DRIVERS=all, not SCENARIOS_ALL) throttles only the scenarios
// marked `slow`, weights.gate.
export const commandWeight = (args: string[], env: Record<string, string | undefined>) => {
  if (args[0] === "launch") return weights.launch;
  if (!(/(^|\/)saytw$/.test(args[0] ?? "") && args[1] === "integrate@local")) return weights.stack;
  const asked = env.SLOW;
  if (asked === undefined) return env.INTEGRATE_LOCAL_DRIVERS === "all" && !env.SCENARIOS_ALL ? weights.gate : weights.stack;
  return asked !== "" && asked !== "0" ? weights.pass : weights.stack;
};
// A holder's record, "<pid> <weight>[ cue mem=<GB> cores=<n>][ in=<holder>]", its holder's only while the
// pid is the holder's: a holder that wrote none weighs a stack. A cue holder's mem is what it claims (and,
// as it runs, what it holds when that is more). A record "<pid> <weight> mem=<GB>" (no `cue`) is a cue
// holder too, and its number is read; one with no readable mem= (a copy of this file from before the
// budget wrote `cue` alone) claims the whole of `budget`, which is what the lock was, and no cores.
export const weightOf = (text: string, pid: number, budget = cueMem) => {
  const [p, w, ...rest] = text.trim().split(" ");
  if (!(p === String(pid) && w !== undefined && w !== "" && Number(w) >= 0)) return { weight: weights.stack, cue: false, mem: 0, cores: 0 };
  const cue = rest.some((x) => x === "cue" || x.startsWith("mem="));
  const num = (key: string) => { const v = rest.find((x) => x.startsWith(`${key}=`))?.slice(key.length + 1); return v !== undefined && v !== "" && Number(v) >= 0 ? Number(v) : undefined; };
  return { weight: Number(w), cue, mem: cue ? num("mem") ?? budget : 0, cores: cue ? num("cores") ?? 0 : 0 };
};
// A launch's TTL in seconds (STACK_LAUNCH_TTL, else an hour; 0 or less = none), and the deadline it
// gives a claim made or renewed at `now` (ms since the epoch; 0 = none). Only a launch has one.
export const launchTtl = (env: string | undefined = Deno.env.get("STACK_LAUNCH_TTL")) => {
  const t = env === undefined || env.trim() === "" ? 3600 : Number(env);
  return Number.isFinite(t) && t > 0 ? t : 0;
};
export const deadlineOf = (kind: "launch" | "gate" | "job" | "cue", now: number, ttl: number) => kind === "launch" && ttl > 0 ? now + ttl * 1000 : 0;
// A claim is expired when it is a launch with a deadline and the deadline has come.
export const expired = (claim: { kind: "launch" | "gate" | "job" | "cue"; deadline: number }, now: number) =>
  claim.kind === "launch" && claim.deadline > 0 && now >= claim.deadline;
// BRT, as the user reads times.
const brt = (ms: number) => new Date(ms - 3 * 3600_000).toISOString().replace("T", " ").slice(0, 19) + " BRT";
const weighs = async (name: string, pid: number) => weightOf(await Deno.readTextFile(`${pool}/${name}/weight`).catch(() => ""), pid);
const round = (gb: number) => Math.round(gb * 10) / 10;
// The weight the live holders hold, and how many are stacks (a job is no stack).
export const held = (holders: { weight: number; job?: boolean }[]) => ({ live: holders.filter((h) => !h.job).length, used: holders.reduce((n, h) => n + h.weight, 0) });
// The admission rule: a claim of `weight` is admitted when the weight held (`used`) and the weight
// reserved by the tickets older than its own (`ahead`) leave room for it within the `budget`; the
// oldest ticket (`ahead` 0) is admitted on an empty pool whatever its weight.
export const admits = (used: number, weight: number, ahead: number, budget: number) =>
  used + ahead === 0 || used + ahead + weight <= budget;
// The cue memory budget's rule, for memory (GB) and, the same way, for cores: a claim of `mem` is admitted
// when what the live holders hold (`held`) and what the tickets older than its own reserve (`ahead`) leave
// room for it within the `budget`; the oldest ticket (`ahead` 0) is admitted on an empty pool whatever it
// claims. Strictly first come first served: a small claim never passes a large one that waits.
export const memAdmits = (held: number, ahead: number, mem: number, budget: number) =>
  held + ahead === 0 || held + ahead + mem <= budget;
// The live veto: with the machine's free memory (kern.memorystatus_level, in %; null when unknown) under
// `min`, a claim is refused unless it is the head of the line on a pool holding no cue memory.
export const vetoed = (freePct: number | null, min: number, headOfEmptyPool: boolean) =>
  freePct !== null && freePct < min && !headOfEmptyPool;
// A holder whose child has been dead for 60 s or more (`deadSince`, ms since the epoch; 0 = not seen dead)
// is stuck: it holds no memory.
export const stuck = (deadSince: number, now: number) => deadSince > 0 && now - deadSince > 60_000;
// Which line a claim waits in: "none" inside a live holder (`parent`) with no memory, or inside one
// that holds cue memory (`insideCue`: the same evaluation's memory, a `cue` its own job runs; waiting
// for the memory its ancestor holds would wait for ever, as two aprende generates did for 70 min on
// 2026-11-07); "cue" for any other memory claim, nested or not; "cores" otherwise.
export const lineOf = (parent: number, mem: number, insideCue = false) =>
  mem > 0 && !(insideCue && parent > 0) ? "cue" : parent > 0 ? "none" : "cores";
// Whether a claim comes from a GitHub Actions job (GITHUB_ACTIONS): admitted at once on cores, unless a release holds.
export const runnerJob = (env: string | undefined) => env === "true";
// The cores rule: a nested claim is admitted whatever the room, any other by `admits`, a runner job at once.
// A release claim waits only for room (`admits`); while a release holds or waits (`hold`), any other
// claim with a weight waits, a runner job too (PRONTO-894), unless it runs `beside` a rehearsal (besideRelease):
// then it is admitted by `admits` alone, a runner job too, never at once.
export const admitsCores = (nested: boolean, used: number, weight: number, ahead: number, budget: number,
  runner = false, release = false, hold = false, beside = false) =>
  nested || (release ? admits(used, weight, ahead, budget)
                     : beside ? admits(used, weight, ahead, budget)
                     : !(hold && weight > 0) && (runner || admits(used, weight, ahead, budget)));
// Whether a held claim runs beside a rehearsal (the owner, 2026-11-20: "Admit while there's room"): a release
// holds a slot, none waits for one (a waiting release keeps its room), and the machine's load1 (`load`, null when
// unknown) is under `max` (STACK_HOLD_LOAD, else one per core). Its weight must still fit (admitsCores). Never
// beside another account's release (`foreign`, STACK_HOLD_POOL): its weight is not in this pool's, and whether it
// holds or waits is not told apart.
export const besideRelease = (holding: number, waiting: number, load: number | null, max: number, foreign = false) =>
  !foreign && holding > 0 && waiting === 0 && load !== null && load < max;
// Whether a claim that is not admitted waits for a release (its STACK_WAIT_MINUTES deadline reset): any weighted
// claim but a release's while a release holds or waits, beside a rehearsal or not.
export const heldByRelease = (hold: boolean, weight: number, release: boolean) => hold && weight > 0 && !release;
// Whether an older ticket keeps its place ahead of this claim: a weighted one only while its cores would be admitted.
// Judged by the pool's room beside a release (`poolBeside`), never the arriving claim's: a weight-0 claim is never
// beside, and judging an older weighted ordinary ticket by it would skip that ticket and take the memory it reserved.
export const olderKeeps = (o: { weighted: boolean; weight: number; release: boolean }, used: number, reserved: number,
  budget: number, hold: boolean, poolBeside: boolean) =>
  !(o.weighted && !admitsCores(false, used, o.weight, reserved, budget, false, o.release, hold, poolBeside && !o.release && o.weight > 0));
// The pool's room beside a release for judging older tickets (olderKeeps): the arriving claim's own `beside` when it is
// weighted; false for a release claim, which reads nothing; for a weight-0 one, read only while an older weighted
// ordinary ticket waits (`olderOrdinary`), by the same rule (besideRelease), its load (`load`, called only then) and
// another account's release (`foreign`) included. A read that fails keeps every older ticket (`"keep"`): a weight-0
// claim is never held, so it waits behind them rather than take a reservation it could not judge.
export const poolBesideOf = (weight: number, release: boolean, hold: boolean, olderOrdinary: boolean, beside: boolean,
  holding: number, waiting: number, foreign: boolean, load: () => number, max: number): boolean | "keep" => {
  if (weight > 0) return beside;
  if (release || !hold || !olderOrdinary) return false;
  if (foreign || !holding || waiting) return false;
  try { return besideRelease(holding, waiting, load(), max, false); } catch { return "keep"; }
};
// Whether a claim's STACK_PRIORITY makes it a release's.
export const releaseClaim = (priority: string | undefined) => priority === "release";
// Whether a holder's record is a release's: its weight above 0 and `prio=release` (a bare `release` word is not the mark).
export const releaseOf = (text: string, pid: number) => {
  const [p, w, ...rest] = text.trim().split(" ");
  return p === String(pid) && Number(w) > 0 && rest.includes("prio=release");
};
// A release record or ticket is real only if its process started no later than the write (`started`, `written`:
// ms since the epoch; a little slack for ps's whole seconds): a pid reused by another process started after it.
export const startedBefore = (started: number, written: number) => started > 0 && started <= written + 2000;
// `ps -o lstart=` in the C locale: "Thu Nov 19 10:00:00 2026" (the day padded with a space under 10), local
// time, in ms since the epoch; NaN for anything else. Parsed here, not by Date.parse, which reads no other locale's.
export const parseLstart = (text: string) => {
  const m = /^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$/.exec(text.trim());
  const month = m ? ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].indexOf(m[1]) : -1;
  return m && month >= 0 ? new Date(Number(m[6]), month, Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])).getTime() : NaN;
};
// When pid `pid` started, from what `ps -o lstart=` gave: { at } in ms; { gone } when the process has exited
// (`alive` false: its record is stale, not a release); { unreadable } with the cause when it is alive and ps did
// not run, failed or printed no C-format date. The caller then counts it a real release (a live release's hold is
// not dropped, nor is every claim on the machine failed for a ps that cannot run), bounded by releaseFresh.
export const psStart = (ps: { out: string; ok: boolean; error?: string }, pid: number, alive: boolean):
  { at: number } | { gone: true } | { unreadable: string } => {
  const at = ps.ok ? parseLstart(ps.out) : NaN;
  if (at > 0) return { at };
  if (!alive) return { gone: true };
  return { unreadable: `release pid ${pid} is alive but its start time cannot be read: ${ps.error ?? (ps.ok ? `ps printed ${JSON.stringify(ps.out.trim())}` : "ps failed")}` };
};
// A ticket's text: "<weight>[ nested=1][ mem=<GB> cores=<n>] prio=<release|normal> <label>". The priority is a
// fixed field of its own, written after the numbers and before the free-form label, and always written, so
// no label can stand where it is read (a label "release ..." or "prio=release ..." follows `prio=normal`).
// A ticket without it (a copy of this file from before) is ordinary, whatever its label says, but for one whose
// label itself starts with `prio=release`: that copy wrote the label where the field is read, so it reads as a
// release (releaseReal still asks for a live process that started before the write, within the hold's hours).
export const ticketText = (t: { weight: number; nested: boolean; mem?: number; cores?: number; release: boolean; what: string }) =>
  `${t.weight} ${t.nested ? "nested=1 " : ""}${t.mem !== undefined ? `mem=${t.mem} cores=${t.cores ?? 0} ` : ""}prio=${t.release ? "release" : "normal"} ${t.what}`;
// What ticketText wrote. `release` is the marked priority alone: a release is real only with a weight above 0
// (checked here) and a live process that started before the write (releaseReal).
export const parseTicket = (text: string) => {
  const [w, ...rest] = text.split(" ");
  const nested = rest[0] === "nested=1";
  const words = nested ? rest.slice(1) : rest;
  const field = (key: string) => { const v = words[0]?.startsWith(`${key}=`) ? words[0].slice(key.length + 1) : undefined; if (v !== undefined && v !== "" && Number(v) >= 0) { words.shift(); return Number(v); } return undefined; };
  const mem = field("mem"), cores = field("cores");
  const prio = words[0] === "prio=release" || words[0] === "prio=normal" ? words.shift() : undefined;
  const weight = w !== "" && Number(w) >= 0 ? Number(w) : weights.stack;
  return { weight, nested, mem, cores, release: prio === "prio=release" && weight > 0, what: words.join(" ") };
};
// The cue tickets a cue claim reserves its memory and cores behind: every older one, but, for a release claim,
// the older ordinary weighted ones: those wait for the release (it holds the machine), and it must not wait for
// them (memory they reserve while waiting for it was a deadlock). Eligible release and nested tickets stay.
export const cueAhead = <T extends { weighted: boolean; release: boolean }>(older: T[], release: boolean) =>
  release ? older.filter((o) => !(o.weighted && !o.release)) : older;
// A queue directory's entries; a directory not made yet (nobody has queued in the line) is empty, every other
// failure to read it propagates: an unreadable queue is not an empty one, and work must not be admitted on it.
export const readQueue = async (dir: string) => {
  try { return await Array.fromAsync(Deno.readDir(dir)); }
  catch (e) { if (e instanceof Deno.errors.NotFound) return [] as Deno.DirEntry[]; throw e; }
};
// A release holds for `hours` (STACK_RELEASE_HOLD_MAX) from its record's or ticket's write, then no longer.
export const releaseFresh = (written: number, now: number, hours: number) => now - written <= hours * 3600_000;
// The weight a claim waits behind: every older ticket's, but a release claim's, and any claim while a release
// holds, count only the older releases' (the others do not move while it holds).
export const aheadOf = (older: { weight: number; release: boolean }[], release: boolean, hold: boolean) =>
  older.filter((o) => (release || hold ? o.release : true)).reduce((n, o) => n + o.weight, 0);
// Whether a release holds the machine: one holds a slot, or one waits.
export const releaseHolds = (holding: number, waiting: number) => holding + waiting > 0;
// What was read of one entry of another account's pool (STACK_HOLD_POOL): a slot-<n> or job-<pid> record (its weight
// file) or a ticket in queue/ or cue-queue/. The kind of its dir and of its file as lstat saw them ("dir", "file",
// "symlink", "other"), their uids and modes, the pid, the file's text, when it was written (a record's mtime, a
// ticket's name's ms), whether the pid is alive, when its process started (ms; 0 unknown), and what it names.
export type ForeignRecord = { ticket: boolean; dirKind: string; dirUid: number; dirMode: number; fileKind: string; fileUid: number; fileMode: number; pid: number; text: string; written: number; alive: boolean; started: number; what: string };
// A ticket's text is a release's when its weight is above 0 and its priority field says so, as the claim's own scan
// reads it (parseTicket: "<weight>[ nested=1][ mem=<GB> cores=<n>] prio=release <what>"), or, written by a copy of
// this file from before the field, `release=1` follows the fields before it ("<weight>[ nested=1][ mem= cores=] release=1 <what>").
export const releaseTicketOf = (text: string) => {
  const [w, ...rest] = text.trim().split(" ");
  if (!(Number(w) > 0)) return false;
  if (parseTicket(text.trim()).release) return true;
  let i = 0;
  if (rest[i] === "nested=1") i++;
  if (rest[i]?.startsWith("mem=")) i++;
  if (rest[i]?.startsWith("cores=")) i++;
  return rest[i] === "release=1";
};
// Whether an entry's dir or file may be believed: a real one (no link), of `uid`, that no other account can write.
export const foreignTrusted = (kind: string, want: string, entryUid: number, mode: number, uid: number) =>
  kind === want && entryUid === uid && (mode & 0o022) === 0;
// The first entry that is a live release of `uid`: real dir and file (no link), that uid's and not group- or
// other-writable, a release record (weight above 0, `prio=release`) or ticket (releaseTicketOf), written within `hours`,
// its process alive and started no later than the write. Anything else is no hold.
export const heldByForeign = (records: ForeignRecord[], uid: number, now: number, hours: number) =>
  records.find((r) => foreignTrusted(r.dirKind, "dir", r.dirUid, r.dirMode, uid) && foreignTrusted(r.fileKind, "file", r.fileUid, r.fileMode, uid)
    && r.alive && Number.isInteger(r.pid) && r.pid > 0 && (r.ticket ? releaseTicketOf(r.text) : releaseOf(r.text, r.pid))
    && releaseFresh(r.written, now, hours) && startedBefore(r.started, r.written));
// STACK_HOLD_UID: digits only, and not this account's own (a pool of one's own is not another account's).
export const holdUid = (raw: string | undefined, self: number | null) => {
  if (raw === undefined || !/^[0-9]+$/.test(raw)) return undefined;
  const want = Number(raw);
  return Number.isSafeInteger(want) && want !== self ? want : undefined;
};
// Whether a directory is one only this account can write: a real directory, ours, not group- or other-writable.
export const dirTrust = (st: { isDirectory: boolean; isSymlink: boolean; uid: number | null; mode: number | null }, uid: number | null) =>
  st.isDirectory && !st.isSymlink && (uid === null || st.uid === uid) && ((st.mode ?? 0) & 0o022) === 0;
// Refuses (fails closed, writes nothing) a directory that is not ours alone to write: after a reboot another account
// could have made the pool first, or planted links in it, and this account would write its records through them.
export const requireOwnDir = (path: string, uid: number | null = Deno.uid()) => {
  if (Deno.build.os === "windows") return;
  if (!dirTrust(Deno.lstatSync(path), uid)) throw new Error(`slot: ${path} is not a directory that only this account can write (a link, another account's, or writable by others): refusing to use it`);
};
const kindOf = (st: Deno.FileInfo) => st.isSymlink ? "symlink" : st.isDirectory ? "dir" : st.isFile ? "file" : "other";
// A file of the hold pool read without following a link: lstat, open, fstat the handle (dev and ino as lstat's), at most 4 KB.
const readNoFollow = async (path: string): Promise<{ kind: string; uid: number; mode: number; text: string; mtime: number } | undefined> => {
  try {
    const l = await Deno.lstat(path);
    const base = { uid: l.uid ?? -1, mode: l.mode ?? 0o777 };
    if (!l.isFile) return { kind: kindOf(l), ...base, text: "", mtime: 0 };
    const f = await Deno.open(path, { read: true });
    try {
      const st = await f.stat();
      if (st.dev !== l.dev || st.ino !== l.ino || !st.isFile) return undefined;
      const buf = new Uint8Array(4096);
      const n = (await f.read(buf)) ?? 0;
      return { kind: "file", ...base, text: new TextDecoder().decode(buf.subarray(0, n)).replace(/[\u0000-\u001f\u007f]/g, " "), mtime: st.mtime?.getTime() ?? 0 };
    } finally { f.close(); }
  } catch { return undefined; }
};
const startOf = async (pid: number, live: boolean) => {
  const r = live ? await new Deno.Command("ps", { args: ["-o", "lstart=", "-p", String(pid)], env: { LC_ALL: "C" }, stdout: "piped", stderr: "null" }).output().catch(() => undefined) : undefined;
  return Date.parse(new TextDecoder().decode(r?.stdout ?? new Uint8Array()).trim()) || 0;
};
// The live release in the pool `dir` of account `want` (never this account, `self`), read-only: its slot and job records and
// the tickets waiting in its queue/ and cue-queue/ (a release holds while it waits too, PRONTO-894).
export const readForeign = async (dir: string, want: number, self: number | null, now = Date.now(), hours = 12): Promise<{ what: string; pid: number } | undefined> => {
  if (want === self || Deno.build.os === "windows") return undefined;
  try {
    const top = await Deno.lstat(dir);
    if (!top.isDirectory || top.isSymlink || top.uid !== want || ((top.mode ?? 0o777) & 0o022) !== 0) return undefined;
    const records: ForeignRecord[] = [];
    const dirOf = async (path: string) => { const d = await Deno.lstat(path).catch(() => undefined); return d ? { kind: kindOf(d), uid: d.uid ?? -1, mode: d.mode ?? 0o777 } : undefined; };
    for await (const e of Deno.readDir(dir)) {
      if (!/^(slot|job)-[0-9]+$/.test(e.name)) continue;
      const d = await dirOf(`${dir}/${e.name}`);
      if (!d || d.kind !== "dir") continue;
      const [pidFile, weight, owner] = await Promise.all(["pid", "weight", "owner"].map((n) => readNoFollow(`${dir}/${e.name}/${n}`)));
      if (!pidFile || !weight || !owner || pidFile.kind !== "file" || pidFile.uid !== want || owner.uid !== want || (pidFile.mode & 0o022) !== 0 || (owner.mode & 0o022) !== 0) continue;
      const pid = Number(pidFile.text.trim());
      if (!Number.isInteger(pid) || pid <= 0 || !releaseOf(weight.text, pid)) continue;
      const live = await alive(pid);
      records.push({ ticket: false, dirKind: d.kind, dirUid: d.uid, dirMode: d.mode, fileKind: weight.kind, fileUid: weight.uid, fileMode: weight.mode, pid, text: weight.text, written: weight.mtime, alive: live,
        started: await startOf(pid, live), what: owner.text.replace(/[\u0000-\u001f\u007f]/g, " ").trim().split(" ").slice(2).join(" ").slice(0, 200) });
    }
    for (const q of ["queue", "cue-queue"]) {
      const d = await dirOf(`${dir}/${q}`);
      if (!d || d.kind !== "dir") continue;
      let names: string[];
      try { names = [...Deno.readDirSync(`${dir}/${q}`)].map((e) => e.name); } catch { continue; }
      for (const name of names) {
        const m = name.match(/^([0-9]+)-([0-9]+)(?:-w)?$/);
        if (!m) continue;
        const f = await readNoFollow(`${dir}/${q}/${name}`);
        if (!f) continue;
        const pid = Number(m[2]), live = await alive(pid);
        if (!releaseTicketOf(f.text)) continue;
        const [w, ...rest] = f.text.trim().split(" ");
        records.push({ ticket: true, dirKind: d.kind, dirUid: d.uid, dirMode: d.mode, fileKind: f.kind, fileUid: f.uid, fileMode: f.mode, pid, text: f.text, written: Number(m[1]), alive: live,
          started: await startOf(pid, live), what: rest.filter((x) => !/^(nested=1|release=1|prio=(release|normal)|mem=.*|cores=.*)$/.test(x)).join(" ").slice(0, 200) || `weight ${w}` });
      }
    }
    const found = heldByForeign(records, want, now, hours);
    return found ? { what: found.what, pid: found.pid } : undefined;
  } catch { return undefined; }
};
// The live release in STACK_HOLD_POOL, if any: both variables set (STACK_HOLD_UID digits, not this account's), read-only.
const foreignHold = async (): Promise<{ what: string; pid: number } | undefined> => {
  const dir = Deno.env.get("STACK_HOLD_POOL"), self = Deno.build.os === "windows" ? null : Deno.uid();
  const want = holdUid(Deno.env.get("STACK_HOLD_UID"), self);
  if (!dir || want === undefined) return undefined;
  const hours = Number(Deno.env.get("STACK_RELEASE_HOLD_MAX") ?? 12);
  return readForeign(dir, want, self, Date.now(), Number.isFinite(hours) ? hours : 12);
};
// A slot's directory is stale, to be freed at the next claim, when its holder is gone and no port of
// its range answers: not only its door. A database left by a stack whose door was down kept :33005 from
// 2026-11-06 on while slot 1 was freed and handed out again, and every stack given it failed to start
// its database (Studio #913, #914; PRONTO-41).
export const staleSlot = (holderAlive: boolean, rangeAnswers: boolean) => !holderAlive && !rangeAnswers;
// The processes listening in [from, to], one per port, lowest first, from `lsof -nP -iTCP
// -sTCP:LISTEN -Fpcn` (a `p<pid>` line, its `c<command>`, then an `n<address>:<port>` line per socket).
export function listenersIn(lsof: string, from: number, to: number): { port: number; pid: number; command: string }[] {
  const by = new Map<number, { port: number; pid: number; command: string }>();
  let pid = 0, command = "";
  for (const line of lsof.split("\n")) {
    const v = line.slice(1);
    if (line[0] === "p") { pid = Number(v); command = ""; }
    else if (line[0] === "c") command = v;
    else if (line[0] === "n") {
      const port = Number(v.slice(v.lastIndexOf(":") + 1));
      if (port >= from && port <= to && !by.has(port)) by.set(port, { port, pid, command });
    }
  }
  return [...by.values()].sort((a, b) => a.port - b.port);
}
// Who holds a range: each listener's port, command and pid, and what started it (`under`), so a
// refusal names what to stop.
export const holdersOf = (ls: { port: number; pid: number; command: string; under?: string }[]) =>
  ls.map((l) => `${l.port} ${l.command} (pid ${l.pid}${l.under ? `, under ${l.under}` : ""})`).join(", ");
// A ticket's name: when it was asked for, in ms, and its pid; names sort in the order of the line.
export const ticketOf = (now: number, pid: number) => `${String(now).padStart(15, "0")}-${pid}`;
const ordinal = (n: number) => `${n}${["th", "st", "nd", "rd"][n % 100 >= 11 && n % 100 <= 13 ? 0 : Math.min(n % 10, 4) % 4]}`;
// Held when something answers there, on either loopback.
const answers = (port: number) => Promise.all(["127.0.0.1", "::1"].map((hostname) =>
  Deno.connect({ hostname, port }).then((c) => (c.close(), true), () => false))).then((a) => a.some(Boolean));
// The ports of the range from `door` that answer, every one of its 100.
const answering = async (door: number) => {
  const range = Array.from({ length: 100 }, (_, i) => door + i);
  const a = await Promise.all(range.map(answers));
  return range.filter((_, i) => a[i]);
};
// What listens in the range from `door`, named: its command, pid and parent (`under`). Without lsof or
// ps (a sandbox), the ports alone.
const listening = async (door: number, open: number[]) => {
  const run = (cmd: string, args: string[]) => new Deno.Command(cmd, { args, stdout: "piped", stderr: "null" }).output()
    .then((o) => new TextDecoder().decode(o.stdout), () => "");
  const ls = listenersIn(await run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]), door, door + 99);
  const named = [];
  for (const l of ls) {
    const [ppid] = (await run("ps", ["-o", "ppid=", "-p", String(l.pid)])).trim().split(/\s+/);
    const parent = Number(ppid) > 1 ? (await run("ps", ["-o", "command=", "-p", ppid])).trim().slice(0, 120) : "";
    named.push({ ...l, under: parent ? `${ppid} ${parent}` : "" });
  }
  return named.length ? named : open.map((port) => ({ port, pid: 0, command: "?" }));
};

// The pool's own lock, held only while a slot is chosen; one older than a minute is a crashed
// chooser's.
const choosing = async <T>(f: () => Promise<T>): Promise<T> => {
  const lock = `${pool}/.choosing`;
  for (;;) {
    try { Deno.mkdirSync(lock); break; } catch { /* held */ }
    const age = Date.now() - ((await Deno.stat(lock).catch(() => undefined))?.mtime?.getTime() ?? Date.now());
    if (age > 60_000) await Deno.remove(lock, { recursive: true }).catch(() => {});
    await new Promise((r) => setTimeout(r, 200));
  }
  try { return await f(); } finally { await Deno.remove(lock, { recursive: true }).catch(() => {}); }
};

// The browsers a test run leaves behind (PRONTO-450): playwright's chrome-headless-shell, from its
// ms-playwright cache. A run that threw, was signalled or hung leaves them running, and a Mac under a
// gate's load slows to a crawl (load 155 on 18 cores, 2026-11-12). tests/browser.ts closes a runner's
// own; this is the machine's side: a claim's browsers go with the claim, and the orphans of a run that
// died are swept. Only the cache's browsers, never the user's own Chrome, and only ones whose owner
// is gone (ppid 1) or is the claim being released.
export type Proc = { pid: number; ppid: number; uid: number; age: number; command: string };
// ps's elapsed time, [[dd-]hh:]mm:ss, in ms.
export const etimeMs = (etime: string): number => {
  const m = etime.trim().match(/^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/);
  return m ? (((Number(m[1] ?? 0) * 24 + Number(m[2] ?? 0)) * 60 + Number(m[3])) * 60 + Number(m[4])) * 1000 : 0;
};
// `ps -A -o pid=,ppid=,uid=,etime=,command=`.
export const parseProcs = (out: string): Proc[] => {
  const procs: Proc[] = [];
  for (const line of out.split("\n")) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
    if (m) procs.push({ pid: Number(m[1]), ppid: Number(m[2]), uid: Number(m[3]), age: etimeMs(m[4]), command: m[5] });
  }
  return procs;
};
const psArgs = ["-A", "-o", "pid=,ppid=,uid=,etime=,command="];
export const processes = async (): Promise<Proc[]> => {
  try { return parseProcs(new TextDecoder().decode((await new Deno.Command("ps", { args: psArgs, stdout: "piped", stderr: "null" }).output()).stdout)); } catch { return []; }
};
const processesSync = (): Proc[] => {
  try { return parseProcs(new TextDecoder().decode(new Deno.Command("ps", { args: psArgs, stdout: "piped", stderr: "null" }).outputSync().stdout)); } catch { return []; }
};
// A browser from playwright's cache (its chrome-headless-shell, and the helpers it starts from it).
export const playwrightBrowser = (command: string) => /\/ms-playwright\//.test(command) && /chrome-headless-shell/.test(command);
// A process and everything it started, from one ps table.
export const treeOf = (procs: readonly Proc[], root: number): number[] => {
  const out = [root];
  for (let i = 0; i < out.length; i++) for (const p of procs) if (p.ppid === out[i] && !out.includes(p.pid)) out.push(p.pid);
  return out;
};
// The cache's browsers, owned by `uid`, whose ancestry includes `pid`: the roots (their children come with treeOf).
export const browsersUnder = (procs: readonly Proc[], pid: number, uid: number): Proc[] => {
  const under = new Set(treeOf(procs, pid));
  under.delete(pid);
  return procs.filter((p) => under.has(p.pid) && p.uid === uid && playwrightBrowser(p.command));
};
// The cache's browsers nobody owns (ppid 1), owned by `uid`, older than `minAgeMs` and not older than `maxAgeMs`.
export const orphanBrowsers = (procs: readonly Proc[], uid: number, minAgeMs: number, maxAgeMs = Infinity): Proc[] =>
  procs.filter((p) => p.ppid === 1 && p.uid === uid && playwrightBrowser(p.command) && p.age >= minAgeMs && p.age <= maxAgeMs);
const killAll = (pids: readonly number[]) => { for (const pid of pids) try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } };
let uid: number | undefined;
// This process's owner, from ps (a program every image holds: not `id`, and a `deno test` has --allow-run but not --allow-sys).
const uidOf = () => uid ??= (() => {
  try { return Number(new TextDecoder().decode(new Deno.Command("ps", { args: ["-o", "uid=", "-p", String(Deno.pid)], stdout: "piped", stderr: "null" }).outputSync().stdout).trim()); } catch { return -1; }
})();
// A claim's browsers killed, at its release (normally, or at its owner's death on the next claim): synchronous, a release is.
export function releaseBrowsers(pid: number, procs: readonly Proc[] = processesSync()): number[] {
  const roots = browsersUnder(procs, pid, uidOf());
  const gone = [...new Set(roots.flatMap((r) => treeOf(procs, r.pid)))];
  killAll(gone);
  if (roots.length) say(`released with ${roots.length} browser(s) of its own still running: killed pid ${roots.map((r) => r.pid).join(", ")}`);
  return gone;
}
const humanAge = (ms: number) => { const m = Math.floor(ms / 60_000); return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m` : `${m}m`; };
const cwdOf = async (pid: number) => {
  try {
    // Through sh: lsof is a Mac tool the Linux images do not hold (tests/unit/image.cue checks what slot.ts spawns by name), and a cwd is only for the log.
    const out = await new Deno.Command("sh", { args: ["-c", `lsof -a -d cwd -p ${pid} -Fn 2>/dev/null`], stdout: "piped", stderr: "null", signal: AbortSignal.timeout(5000) }).output();
    return new TextDecoder().decode(out.stdout).split("\n").find((l) => l.startsWith("n"))?.slice(1) ?? "?";
  } catch { return "?"; }
};
// The sweep: the cache's browsers whose owner is gone (ppid 1) and that are older than `minAgeMs`
// (30 min), killed with what they started, each logged with its pid, age and cwd. Never one with a live
// parent, never Google Chrome. Run at every claim, and alone: `deno run -A tests/slot.ts sweep-browsers`.
// `since`: only browsers started after this time (ms since the epoch), for the orphans of a claim that died.
export async function sweepBrowsers(minAgeMs = 30 * 60_000, since = 0, procs?: readonly Proc[]): Promise<{ pid: number; age: number; cwd: string }[]> {
  const table = procs ?? await processes();
  const now = Date.now();
  const swept: { pid: number; age: number; cwd: string }[] = [];
  for (const p of orphanBrowsers(table, uidOf(), minAgeMs, since ? now - since : Infinity)) {
    const cwd = await cwdOf(p.pid);
    killAll(treeOf(table, p.pid));
    say(`swept an orphaned browser: pid ${p.pid}, age ${humanAge(p.age)}, cwd ${cwd}`);
    swept.push({ pid: p.pid, age: p.age, cwd });
  }
  return swept;
}
// A claim that died holds nothing, and its browsers were left to init: the ones started since it began.
async function reapDeadClaims(): Promise<void> {
  let began = Infinity;
  try {
    for await (const e of Deno.readDir(pool)) {
      const m = e.name.match(/^(slot|job)-([0-9]+)$/);
      if (!m) continue;
      const pid = await holder(e.name);
      if (pid > 0 && !await alive(pid)) began = Math.min(began, (await Deno.stat(`${pool}/${e.name}/pid`).catch(() => null))?.mtime?.getTime() ?? Infinity);
    }
  } catch { /* no pool yet */ }
  await sweepBrowsers(30 * 60_000).catch(() => []);
  if (began < Infinity) await sweepBrowsers(0, began - 10_000).catch(() => []);
}

// A slot asked for by number is not waited for when its holder is the asker or above it.
export const heldByAncestor = (holder: number, lineage: number[]) => holder > 0 && lineage.includes(holder);
// A process and its parents, nearest first: one ps of the whole table, not one per level (stops at
// init or a loop). Lenient (the default): without ps (a sandbox) the process alone. Strict: a ps that fails or a table
// that cannot be read throws, for a caller that must know whose process this is (rehearse's release attribution).
export const ancestry = async (pid: number, strict = false) => {
  const out = [pid];
  try {
    const { success, stdout } = await new Deno.Command("ps", { args: ["-A", "-o", "pid=,ppid="], stdout: "piped", stderr: "null" }).output();
    if (!success) throw new Error("ps failed");
    const parent = new Map<number, number>();
    for (const l of new TextDecoder().decode(stdout).split("\n")) {
      const [p, pp] = l.trim().split(/\s+/).map(Number);
      if (p > 0) parent.set(p, pp);
    }
    if (strict && !parent.has(pid)) throw new Error(`process ${pid} is not in the process table`);
    for (let p = pid; out.length < 64;) {
      const up = parent.get(p) ?? 0;
      if (!(up > 1) || out.includes(up)) break;
      out.push(up); p = up;
    }
  } catch (e) { if (strict) throw e; /* alone */ }
  return out;
};
// The live holder among the processes above a claim (0: none): a claim with one is nested, and its cores are not waited for.
export const nestedUnder = (holders: number[], above: number[]) => holders.find((h) => heldByAncestor(h, above)) ?? 0;

export async function claim(pid?: number, what?: string, weight?: number, wait?: true, job?: boolean, mem?: number, cores?: number): Promise<Slot>;
export async function claim(pid: number, what: string, weight: number, wait: false, job?: boolean, mem?: number, cores?: number): Promise<Slot | undefined>;
export async function claim(pid = Deno.pid, what = Deno.args.join(" "), weight = Number(Deno.env.get("STACK_WEIGHT") ?? weights.stack), wait = true, job = false, mem = 0, cores = 0): Promise<Slot | undefined> {
  await Deno.mkdir(pool, { recursive: true, mode: 0o755 });
  requireOwnDir(pool);
  const lineage = await ancestry(pid);
  // STACK_SLOT=<n> names the slot of the command this process runs under (tests/slot.ts <command>): a
  // claim for that number from the command itself would wait for ever, its holder above it. Before the
  // ticket, so the head of the line is never a claim that cannot be admitted.
  if (!job && asked) {
    const held = await holder(`slot-${asked}`);
    if (heldByAncestor(held, lineage) && await alive(held)) {
      throw new Error(`slot ${asked} (STACK_SLOT) is held by ${held}, this process or one above it: ${what} runs on the slot it was given and takes none of its own, so it is not run under tests/slot.ts (verify@local takes its own slot: run it directly)`);
    }
  }
  // A claim is nested when a live holder is above it: by the process tree (not this process, whose
  // own slot a rehearsal's lanes sit beside), or by the environment when the tree was lost (a daemon):
  // STACK_JOB, the job that ran it, and for a job STACK_SLOT, its slot.
  const above = [...lineage.slice(1), Number(Deno.env.get("STACK_JOB") ?? 0), job && asked ? await holder(`slot-${asked}`) : 0];
  const live: number[] = [];
  let insideCue = false;
  for await (const e of Deno.readDir(pool)) {
    const h = /^(?:slot|job)-[0-9]+$/.test(e.name) ? await holder(e.name) : 0;
    if (h > 0 && above.includes(h) && await alive(h)) {
      live.push(h);
      if ((await weighs(e.name, h)).cue) insideCue = true;
    }
  }
  const parent = nestedUnder(live, above);
  if (parent) weight = 0;
  const release = releaseClaim(Deno.env.get("STACK_PRIORITY")) && weight > 0;
  const line = lineOf(parent, mem, insideCue);
  // A cue claim that weighs cores and is not nested is one ticket in both lines (the cue line's and the
  // cores'), admitted only when both admit; a nested one waits in the cue line behind nested tickets only.
  const dual = line === "cue" && weight > 0;
  const nested = line === "cue" && parent > 0;
  // A job (--weight) brings up no stack: no process-compose, no ports, no slot number.
  const compose = job ? "" : await Deno.readTextFile(`${app}/.bayt/process-compose.yaml`);
  let told = "";
  const queued = Date.now();
  const dirOf = line === "cue" ? "cue-queue" : "queue";
  const queue = `${pool}/${dirOf}`;
  const coresQueue = `${pool}/queue`;
  const ticket = ticketOf(queued, pid);
  // A top-level cue's ticket in the cue line is named with a `-w` the copies of this file from before it
  // do not read (their ticket name is digits, a dash and a pid): a nested cue through one of them is
  // not made to wait behind a ticket that waits for its own holder's cores.
  const mine = dual ? `${ticket}-w` : ticket;
  await Deno.mkdir(queue, { recursive: true, mode: 0o755 });
  await Deno.mkdir(coresQueue, { recursive: true, mode: 0o755 });
  requireOwnDir(queue);
  requireOwnDir(coresQueue);
  const put = async (file: string, text: string) => { await Deno.writeTextFile(`${file}.${pid}.tmp`, text); await Deno.rename(`${file}.${pid}.tmp`, file); };
  if (line !== "none") await put(`${queue}/${mine}`, ticketText({ weight, nested, mem: line === "cue" ? mem : undefined, cores: line === "cue" ? cores : undefined, release, what }));
  const minutes = Number(Deno.env.get("STACK_WAIT_MINUTES") ?? 120);
  let end = Date.now() + minutes * 60_000, fewest = Infinity, fewestCores = Infinity, lightest = Infinity, leanest = Infinity;
  const warned = new Set<string>();
  // What dead postgres left, freed once a claim: the stack this claim starts may need a segment.
  await reclaimSegments();
  await reapRuns();
  await reapDeadClaims();
  try {
  for (;;) {
    // A poll that admits nothing for a reason that moves no progress counter (all at Infinity: nothing "dropped").
    const waiting = (why: string): { why: string; ahead: number; coresAhead: number; used: number; memHeld: number; held: boolean } =>
      ({ why, ahead: Infinity, coresAhead: Infinity, used: Infinity, memHeld: Infinity, held: false });
    const got = await choosing(async () => {
      // Reclaim, at every claim: the live tickets of this claim's line older than its own (their
      // weights reserved), the dead ones freed; the live holders, the dead jobs and stale slots freed.
      // Each queue directory once per poll: its live tickets, in order (the dead ones freed). A ticket's number is when it
      // was queued; a release ticket whose process started after that, or that is too old, is not a release.
      let unreadable: string | undefined;
      const scan = async (dir: string) => {
        const found: { name: string; weight: number; mem: number; cores: number; what: string; weighted: boolean; release: boolean; pid: number }[] = [];
        // A line nobody has queued in has no directory yet (readQueue); a queue that cannot be read admits nothing this poll.
        let entries: Deno.DirEntry[] = [];
        try { entries = await readQueue(dir); } catch (e) { unreadable ??= `${dir}: ${e instanceof Error ? e.message : e}`; }
        for (const e of entries) {
          const m = e.name.match(/^[0-9]+-([0-9]+)(?:-w)?$/);
          if (!m) continue;
          if (!await alive(Number(m[1]))) { await Deno.remove(`${dir}/${e.name}`).catch(() => {}); continue; }
          const t = parseTicket(await Deno.readTextFile(`${dir}/${e.name}`).catch(() => ""));
          // A ticket without mem= (a copy from before the budget) reserves the whole budget; the cores' line's has none.
          const isRelease = t.release && await releaseReal(Number(m[1]), Number(e.name.split("-")[0]));
          found.push({ name: e.name, weight: t.weight, mem: t.mem ?? cueMem, cores: t.cores ?? 0, what: t.what, weighted: e.name.endsWith("-w"), release: isRelease, pid: Number(m[1]) });
        }
        return found.sort((x, y) => x.name < y.name ? -1 : 1);
      };
      const coresTickets = await scan(`${pool}/queue`), cueTickets = await scan(`${pool}/cue-queue`);
      // An unreadable queue is no empty one: nothing is admitted on it, and the claim fails only if it stays so past its deadline.
      if (unreadable) return waiting(`queue unreadable: ${unreadable}`);
      const before = (all: typeof coresTickets, own: string) => all.filter((t) => t.name < own);
      const inLine = line === "none" ? [] : before(line === "cue" ? cueTickets : coresTickets, mine);
      const holders: { weight: number; cue: boolean; mem: number; cores: number; job: boolean; release: boolean }[] = [];
      const releasing: { what: string; pid: number }[] = [];
      for await (const e of Deno.readDir(pool)) {
        const m = e.name.match(/^(slot|job)-([0-9]+)$/);
        if (!m) continue;
        const pid = await holder(e.name);
        if (await alive(pid)) {
          const w = await weighs(e.name, pid);
          // A holder alive whose child has been dead for a minute holds nothing: noted when first seen dead.
          const child = Number(await Deno.readTextFile(`${pool}/${e.name}/child`).catch(() => "0"));
          if (w.mem > 0 && child > 0 && !await alive(child)) {
            const marker = `${pool}/${e.name}/child-dead`;
            let since = Number(await Deno.readTextFile(marker).catch(() => "0"));
            if (!(since > 0)) { since = Date.now(); await Deno.writeTextFile(marker, String(since)).catch(() => {}); }
            if (stuck(since, Date.now())) {
              if (!warned.has(e.name)) { warned.add(e.name); say(`${e.name} (pid ${pid}) is alive but its child ${child} has been dead over 60 s: its ${round(w.mem)} GB counted as free`); }
              w.mem = 0; w.cores = 0;
            }
          }
          const isRelease = releaseOf(await Deno.readTextFile(`${pool}/${e.name}/weight`).catch(() => ""), pid)
            && await releaseReal(pid, (await Deno.stat(`${pool}/${e.name}/weight`).catch(() => undefined))?.mtime?.getTime() ?? 0);
          if (isRelease) releasing.push({ what: (await Deno.readTextFile(`${pool}/${e.name}/owner`).catch(() => "")).trim().split(" ").slice(2).join(" "), pid });
          holders.push({ ...w, job: m[1] === "job", release: isRelease });
        }
        else if (m[1] === "job") await Deno.remove(`${pool}/${e.name}`, { recursive: true }).catch(() => {});
        else if (staleSlot(false, (await answering(33000 + 100 * (Number(m[2]) - 1))).length > 0)) await Deno.remove(`${pool}/${e.name}`, { recursive: true }).catch(() => {});
      }
      const { used } = held(holders);
      // Another account's live release, read-only (STACK_HOLD_POOL), holds as one of this pool's does.
      const foreign = weight > 0 && !release ? await foreignHold() : undefined;
      if (foreign) releasing.push(foreign);
      // A release holds the machine while one holds a slot or waits, in either line (PRONTO-894).
      const waitingRelease = [...coresTickets, ...cueTickets].filter((t) => t.release && t.name.replace(/-w$/, "") !== ticket);
      const hold = releaseHolds(holders.filter((h) => h.release).length + (foreign ? 1 : 0), waitingRelease.length ? 1 : 0);
      const blocker = releasing[0] ?? waitingRelease[0];
      // Room beside a running rehearsal: the machine's one-minute load, as release-cron reads it (Deno.loadavg).
      // Read only when it could admit (a local release holds, none waits). A failed read fails the claim, with its cause,
      // through the ticket cleanup below: a held claim's deadline moves, so a read that kept failing would wait out the release.
      const load = hold && weight > 0 && !release && releasing.length && !waitingRelease.length && !foreign ? load1() : null;
      // Only a weighted ordinary claim runs beside: a weight-0 one (a Studio preview inside its slot's work) is not held at
      // all, and keeps counting only the releases ahead of it.
      const beside = hold && weight > 0 && !release && besideRelease(releasing.length, waitingRelease.length, load, holdLoad, !!foreign);
      // The pool's room beside a release, for judging the older tickets: the arriving claim's own when it is weighted and
      // ordinary; for a weight-0 one, read the same way for its sake whenever an older weighted ordinary ticket waits.
      // A release claim judges none beside, as before.
      const olderOrdinary = !release && hold && inLine.some((o) => o.weighted && !o.release);
      const poolForeign = weight > 0 ? foreign : olderOrdinary ? await foreignHold() : undefined;
      const poolBeside = poolBesideOf(weight, release, hold, olderOrdinary, beside, releasing.length, waitingRelease.length,
        !!poolForeign, () => load1(), holdLoad);
      const held_ = heldByRelease(hold, weight, release);
      const memHeld = holders.reduce((n, h) => n + h.mem, 0), coresHeld = holders.reduce((n, h) => n + h.cores, 0);
      // The tickets this claim waits behind, in order, nested or not: all of the older ones but a weighted cue
      // ticket (`-w`) blocked on cores, which waits for cores a holder above a nested claim may keep (PRONTO-761,
      // PRONTO-837: a gate's nested cue behind it, and a zero-weight claim behind that, stalled for ever).
      const older: typeof inLine = [];
      for (const o of inLine) {
        const reserved = o.weighted ? before(coresTickets, o.name.replace(/-w$/, "")).reduce((n, c) => n + c.weight, 0) : 0;
        if (poolBeside === "keep" || olderKeeps(o, used, reserved, budget, hold, poolBeside)) older.push(o);
      }
      const where = `${ordinal(older.length + 1)} in line${older.length ? ` behind ${older.at(-1)!.what} (weight ${older.at(-1)!.weight})` : ""}`;
      // A top-level cue reserves cores only once the cue budget admits it (the memory and cores it claims fit
      // beside the live holders and the tickets ahead): cue holders run side by side, so a claim that waits for
      // the budget reserves none, and one the budget admits holds its place on the cores' line, which is its
      // ticket's name, when it asked.
      const cueOlder = cueAhead(older, release);
      const cueFits = line === "cue" && memAdmits(memHeld, cueOlder.reduce((n, o) => n + o.mem, 0), mem, cueMem)
        && memAdmits(coresHeld, cueOlder.reduce((n, o) => n + o.cores, 0), cores, cueCores);
      if (dual) {
        if (cueFits) await put(`${coresQueue}/${ticket}`, ticketText({ weight, nested: false, release, what }));
        else await Deno.remove(`${coresQueue}/${ticket}`).catch(() => {});
      }
      // The cores a dual ticket waits behind: its older tickets in the cores' line.
      const coresOlder = line === "cue" ? (dual ? before(coresTickets, ticket) : []) : older;
      const ahead = aheadOf(coresOlder, release, hold && !beside);
      // `ahead` counts the lock's line, `coresAhead` the cores': a weighted cue ticket at the lock's head still
      // moves while the cores' line drains (PRONTO-837).
      // Not the live load: the line is said again whenever it changes, and the load changes every poll.
      const loadNote = releasing.length && !waitingRelease.length && !foreign ? ` (admitted beside it while load1 < ${holdLoad} and the weight fits: STACK_HOLD_LOAD)` : "";
      const why = (s: string) => ({ why: held_ ? `held: a release (${blocker.what}, pid ${blocker.pid}) ${releasing.length ? "holds the machine" : "waits for it"}${loadNote}: ${where}: ${s}` : `${where}: ${s}`, ahead: older.length, coresAhead: coresOlder.length, used, memHeld, held: held_ });
      if (line === "cue") {
        const memAhead = cueOlder.reduce((n, o) => n + o.mem, 0), coresAheadCue = cueOlder.reduce((n, o) => n + o.cores, 0);
        if (!memAdmits(memHeld, memAhead, mem, cueMem)) {
          return why(`cue memory: ${round(memHeld)} of ${cueMem} GB held${memAhead ? `, ${round(memAhead)} reserved by those ahead` : ""}, this needs ${round(mem)} (CUE_MEM_GB)`);
        }
        if (!memAdmits(coresHeld, coresAheadCue, cores, cueCores)) {
          return why(`cue cores: ${round(coresHeld)} of ${cueCores} claimed${coresAheadCue ? `, ${round(coresAheadCue)} reserved by those ahead` : ""}, this needs ${round(cores)} (CUE_CORES)`);
        }
        const min = Number(Deno.env.get("CUE_MIN_FREE_PCT") ?? 20);
        const free = await freeMemoryPct();
        if (vetoed(free, min, cueOlder.length === 0 && memHeld === 0)) return why(`the machine has ${free}% of its memory free, under ${min}% (CUE_MIN_FREE_PCT): waiting for it to recover`);
        // A top-level cue's cores are the machine's, whoever runs it: an Actions job's too, or a runner's evaluation
        // would take cores the budget already gave away. A dual claim is never nested (a nested claim weighs 0).
        if (dual && !admitsCores(false, used, weight, ahead, budget, false, release, hold, beside)) {
          return why(`weight ${used} of ${budget} held (STACK_BUDGET)${ahead ? `, ${ahead} reserved by those ahead` : ""}, this needs ${weight}`);
        }
      } else if (!admitsCores(line === "none", used, weight, ahead, budget, runnerJob(Deno.env.get("GITHUB_ACTIONS")), release, hold, beside)) {
        return why(`weight ${used} of ${budget} held (STACK_BUDGET)${ahead ? `, ${ahead} reserved by those ahead` : ""}, this needs ${weight}`);
      }
      if (!job) {
        const shm = await freeSegments();
        if (shm && shm.free < 1) return why(`no shared memory segment free (${shm.limit - shm.free} in use of kern.sysv.shmmni ${shm.limit}): a stack's database needs one; tools/sysv-shm/install.sh raises the limit, once, as root`);
      }
      const tag = `${mem > 0 ? ` cue mem=${mem} cores=${cores}` : ""}${parent ? ` in=${parent}` : ""}${release ? " prio=release" : ""}`;
      if (job) {
        const dir = `${pool}/job-${pid}`;
        await Deno.mkdir(dir, { recursive: true, mode: 0o755 });
        requireOwnDir(dir);
        await Deno.writeTextFile(`${dir}/weight`, `${pid} ${weight}${tag}`);
        await Deno.writeTextFile(`${dir}/pid`, String(pid));
        await Deno.writeTextFile(`${dir}/owner`, `${pid} ${new Date().toISOString()} ${what} (weight ${weight}${mem > 0 ? `, cue memory ${mem} GB` : ""})\n`);
        return { n: 0, dir, door: 0, ports: {}, text: "" };
      }
      const busy: string[] = [];
      for (const n of asked ? [asked] : Array.from({ length: 160 }, (_, i) => i + 1)) {
        if (await alive(await holder(`slot-${n}`))) { busy.push(`${n} held by ${await holder(`slot-${n}`)}`); continue; }
        const { door, ports, moved, text } = layout(compose, n);
        // Every port of the slot's range, not only the ones this app's stack derives: a stack another
        // app left behind (a live postgres on its database port, its door long gone) blocks whatever
        // lands on that slot next (slot 1's :33005 from 2026-11-06 on, PRONTO-40, PRONTO-41). The
        // refusal names what listens, so it can be stopped.
        const open = await answering(door);
        for (const p of new Set([...Object.values(ports), ...moved.values()])) if ((p < door || p > door + 99) && await answers(p)) open.push(p);
        if (open.length) { busy.push(`${n}'s ports answer, a stack not down: ${holdersOf(await listening(door, open))}`); continue; }
        const dir = `${pool}/slot-${n}`;
        await Deno.mkdir(dir, { recursive: true, mode: 0o755 });
        if (Deno.build.os !== "windows" && !dirTrust(Deno.lstatSync(dir), Deno.uid())) { busy.push(`${n}'s record is not a directory only this account can write: left alone`); continue; }
        await Deno.writeTextFile(`${dir}/weight`, `${pid} ${weight}${tag}`);
        await Deno.writeTextFile(`${dir}/pid`, String(pid));
        await Deno.writeTextFile(`${dir}/owner`, `${pid} ${new Date().toISOString()} ${app} ${what} (weight ${weight})\n`);
        return { n, dir, door, ports, text };
      }
      return why(`slot ${busy.join("; ")}`);
    });
    if (!("why" in got)) {
      const { n, dir, door, ports, text } = got;
      const tail = `${parent ? ` (inside ${parent}: admitted at once, within its weight)` : ""}${mem > 0 ? ` (cue memory ${round(mem)} GB, ${round(cores)} cores)` : ""}`;
      if (job) {
        say(`${what}: weight ${weight} of ${budget}${tail}`);
        const release = () => {
          try { Deno.removeSync(dir, { recursive: true }); } catch { /* gone */ }
          releaseBrowsers(pid);
        };
        return { n, dir, door, env: {}, release, queued, admitted: Date.now() };
      }
      // The slot's copy of the app: links to the checkout, but its process-compose.
      const copy = `${dir}/app`;
      await Deno.remove(copy, { recursive: true }).catch(() => {});
      await Deno.mkdir(`${copy}/.bayt`, { recursive: true });
      for await (const e of Deno.readDir(app)) if (e.name !== ".bayt") await Deno.symlink(`${app}/${e.name}`, `${copy}/${e.name}`);
      for await (const e of Deno.readDir(`${app}/.bayt`)) {
        if (e.name !== "process-compose.yaml") await Deno.symlink(`${app}/.bayt/${e.name}`, `${copy}/.bayt/${e.name}`);
      }
      await Deno.writeTextFile(`${copy}/.bayt/process-compose.yaml`, text);
      const url = `https://localhost:${door}`;
      say(`slot ${n}: ${url}, ports ${door}-${door + 99}, weight ${weight} of ${budget}${tail}, from ${copy}`);
      // mise reads the copy's .mise.toml, which it trusts as the checkout's.
      const trusted = [Deno.env.get("MISE_TRUSTED_CONFIG_PATHS"), copy].filter(Boolean).join(":");
      const env = { ...Object.fromEntries(Object.entries(ports).map(([k, v]) => [k, String(v)])), ORIGIN: url, APP_URL: url, STACK_SLOT: String(n), PRONTO_GATE_DIR: app, MISE_TRUSTED_CONFIG_PATHS: trusted };
      const release = () => {
        try { Deno.removeSync(`${dir}/pid`); } catch { /* gone */ }
        releaseBrowsers(pid);
      };
      return { n, dir: copy, door, env, release, queued, admitted: Date.now() };
    }
    if (!wait) { say(`not taken: ${got.why}`); return undefined; }
    // Said again when the reason changes.
    if (got.why !== told) say(`waiting: ${got.why}`);
    told = got.why;
    // Progress: a ticket ahead left (in either line), or the weight or the cue memory held dropped, below the least seen.
    if (got.ahead < fewest || got.coresAhead < fewestCores || got.used < lightest || got.memHeld < leanest) end = Date.now() + minutes * 60_000;
    // A claim a release holds is not stuck: its deadline moves while the release holds it.
    if (got.held) end = Date.now() + minutes * 60_000;
    leanest = Math.min(leanest, got.memHeld);
    fewest = Math.min(fewest, got.ahead);
    fewestCores = Math.min(fewestCores, got.coresAhead);
    lightest = Math.min(lightest, got.used);
    if (Date.now() > end) throw new Error(`no slot, and the line did not move for ${minutes} minutes: ${got.why}`);
    await new Promise((r) => setTimeout(r, 1000));
  }
  } finally {
    if (line !== "none") await Deno.remove(`${queue}/${mine}`).catch(() => {});
    if (dual) await Deno.remove(`${coresQueue}/${ticket}`).catch(() => {});
  }
}


// process-compose with its API on a socket in the run's own folder, and its log there, so the
// stack can be brought down whole: a launch stopped by a signal can leave its postgres behind.
//
// Its own process group (detached), so the stack has one way down: this launch's `down`. A signal to
// the launch's group (Studio stops a preview with SIGTERM to it) reached process-compose too, which
// began its own shutdown while `down` asked for another; it ended mid-way ("failed to stop project:
// EOF") with the database, stopped last, never signalled: host.sh and postgres outlived the slot
// (:33005 from 2026-11-06, seven more by 2026-11-08; PRONTO-41). `down` logs apart from `up`, whose log
// it truncated, and after it whatever still listens in the slot's range is this stack's and is
// stopped by its process group: the claim found the range silent.
//
// What each process says (its stdout and stderr, which process-compose prints as `[name\t] line`) is
// kept beside the log, in processes.log: a database that exits as it starts says why only there
// (PRONTO-39: Studio's published game failed with its database's exit and nothing else to go on).
// What `./saytw launch@local` makes before its stack, made for a slot's launch too: the work folder (a
// no-op `task` on the PATH, the certificates, DENO_CERT's ca.pem) and the served folder, the tree
// .bayt/bayt.served.json lists as the image's served layer holds it. Without them caddy served /srv and
// 404ed every static file, and replay read /docker-entrypoint-initdb.d (PRONTO-199). Not a third copy of
// bayt's logic: the lines are the app's own generated .bayt/Taskfile.launch.yaml's, from its work folder
// to the process-compose log it then writes, run with the work folder at $env.SLOT_WORK, printing as JSON
// the environment launch@local gives its stack (its `pc_env` record: the folders, DENO_CERT, MISE_ENV
// host, whose postgres the database runs) and the `task` folder. A Taskfile whose lines are not found
// fails the launch, naming what is missing: a stack without them only 404s later.
// A generated Taskfile's default command, the `nu -c` script bayt writes, unescaped into its lines.
const taskScript = (taskfile: string, name: string): string[] => {
  const block = /^ {4}- \|-\n((?: {6}.*\n?|\n)*)/m.exec(taskfile);
  const missing = (what: string) => new Error(`.bayt/${name} has no ${what}: regenerate it (./saytw generate)`);
  if (!block) throw missing("default task command");
  const cmd = block[1].split("\n").map((l) => l.slice(6)).join("\n");
  const nu = /^nu -c "([\s\S]*)"\s*$/.exec(cmd);
  if (!nu) throw missing("nu -c command");
  return nu[1].replace(/\\([$`"\\\n])/g, "$1").split("\n");
};
export function preparing(taskfile: string): string {
  const missing = (what: string) => new Error(`.bayt/Taskfile.launch.yaml has no ${what}: regenerate it (./saytw generate)`);
  const lines = taskScript(taskfile, "Taskfile.launch.yaml");
  const os = lines.find((l) => /^let os = /.test(l.trim()));
  const from = lines.findIndex((l) => /^let work = /.test(l.trim()));
  const to = lines.findIndex((l, i) => i > from && /^\$"log_location:/.test(l.trim()));
  const env = lines.findIndex((l) => /^let pc_env = .*merge \{$/.test(l.trim()));
  const end = lines.findIndex((l, i) => i > env && /^\}/.test(l.trim()));
  if (!os) throw missing("`let os`");
  if (from < 0 || to < 0) throw missing("work folder lines (`let work` to its process-compose log)");
  if (env < 0 || end < 0) throw missing("`pc_env` record");
  const trim = (ls: string[]) => ls.map((l) => l.replace(/^ {0,2}/, ""));
  return [os.trim(), "let work = $env.SLOT_WORK", ...trim(lines.slice(from + 1, to)),
    "print ({", ...trim(lines.slice(env + 1, end)), "} | merge { TASK_BIN: $wbin } | to json -r)"].join("\n");
}
// integrate@host on a slot: the suites bayt's host integrate runs (.bayt/Taskfile.integrate.yaml's own
// script: each suite a `process-compose run <suite>` of the stack `launch` waits on, on ports it finds
// free), run whole in the slot's copy, whose literal ports (the identity broker's) the slot moved. Not a
// second copy of bayt's logic: the script is the app's generated one, as `preparing`'s lines are.
export const integrating = (taskfile: string): string => taskScript(taskfile, "Taskfile.integrate.yaml").join("\n");
// integrate@local is integrate@host (PRONTO-470): bayt's host integrate under MISE_ENV=host, the host roster
// and its lock, with what only the gate holds around it. The one place a suite is told apart is the
// visual lint, which is measured slowed (SLOW=1, as integrate-local.ts did) while the scenarios are not:
// the suites share one environment, so the generated loop's `load-env` also carries SLOW for `visual`.
export const slowVisual = (script: string): string => {
  const at = "merge { BAYT_LOCAL_WORK_DIR: $sdir })";
  if (!script.includes(at)) throw new Error(".bayt/Taskfile.integrate.yaml has no `load-env` of BAYT_LOCAL_WORK_DIR: regenerate it (./saytw generate), or slot.ts's gate no longer reads its shape");
  return script.replace(at, "merge { BAYT_LOCAL_WORK_DIR: $sdir } | merge (if $suite == 'visual' and (($env.SLOW? | default '') == '') { { SLOW: '1' } } else { {} }))");
};
// The gate's own steps around the host integrate, from pronto's runtime (integrate-local.ts's, which the
// rehearsal still runs): the secrets the release reads, the tree's key before and its stamp after
// (gcp/local-gate-key.nu), and the last release's database (upgrade-from-released.ts).
const gate = (app: string) => {
  const env = { ...Deno.env.toObject(), PATH: misePath() };
  const mode = Deno.env.get("INTEGRATE_LOCAL_DRIVERS") ?? "";
  if (mode !== "" && mode !== "all") { console.error(`integrate@local: INTEGRATE_LOCAL_DRIVERS is "${mode}": it is unset or "all"`); Deno.exit(1); }
  const out = async (cmd: string, args: string[], cwd = app) => {
    // Through sh, as every program here is started: the image's programs are listed by name (spec/toolchain.cue).
    const r = await new Deno.Command("sh", { args: ["-c", 'exec "$@"', "sh", cmd, ...args], cwd, env, stdin: "null", stdout: "piped", stderr: "inherit" }).output();
    return { ok: r.success, text: new TextDecoder().decode(r.stdout).trim() };
  };
  const pronto = async () => (await out("mise", ["where", "github:bonisoft3/pronto"])).text;
  const keyOf = async (verb: string, key?: string) => out("mise", ["x", "--", "nu", `${await pronto()}/gcp/local-gate-key.nu`, verb, app, ...(key ? [key] : [])]);
  return {
    mode,
    // An app with a GCP release plan reads secrets by name: a missing one fails here, not in release@gcp.
    secrets: async () => (await new Deno.Command("sh", { args: ["-c", 'exec "$@"', "sh", "mise", "x", "--", "nu", `${await pronto()}/gcp/secrets.nu`, "check", app, "--if-gcp"], cwd: app, env, stdout: "inherit", stderr: "inherit" }).output()).success,
    key: async () => { const r = await keyOf("key"); return r.ok ? r.text : ""; },
    stamp: async (key: string) => (await keyOf("stamp", key)).ok,
    // The stack's database is the last release's, carried forward as the release carries it: the slot's
    // process-compose, whose ports the slot moved, is replaced by the file that upgrade makes of it.
    upgrade: async (copy: string, tmp: string) => {
      // upgrade-from-released.ts starts `cue`, `mise` and `git` by name from this process: the gate in GitHub runs
      // slot.ts outside a `mise exec`, so the app's toolchain (cue) is put on PATH here.
      const cue = (await out("mise", ["which", "cue"])).text;
      Deno.env.set("PATH", `${cue ? cue.slice(0, cue.lastIndexOf("/")) + ":" : ""}${misePath()}`);
      const { prepare: upgrade } = await import(`${await pronto()}/upgrade-from-released.ts`);
      const r = await upgrade(copy, app, tmp);
      if ("skip" in r) { console.error(`integrate@local: NOT TESTING THE UPGRADE FROM THE LAST RELEASE: ${r.skip}; the database is built fresh`); return; }
      console.error(`integrate@local: upgrade from the last release: ${r.note}`);
      await Deno.writeTextFile(`${copy}/.bayt/process-compose.yaml`, await Deno.readTextFile(r.file));
    },
  };
};
// Runs them in the slot's copy of the app, into <run>/work: the stack's environment they add.
export const prepare = async (slot: Slot, run: string): Promise<Record<string, string>> => {
  const script = preparing(await Deno.readTextFile(`${slot.dir}/.bayt/Taskfile.launch.yaml`));
  const PATH = misePath();
  const { code, stdout, stderr } = await new Deno.Command("sh", { args: ["-c", 'exec mise x -- nu -c "$1"', "sh", script], cwd: slot.dir, env: { ...slot.env, MISE_ENV: "host", SLOT_WORK: `${run}/work`, PATH }, stdout: "piped", stderr: "piped" }).output();
  if (code) throw new Error(`preparing the launch's work and served folders failed:\n${new TextDecoder().decode(stderr)}`);
  const { TASK_BIN, ...made } = JSON.parse(new TextDecoder().decode(stdout).trim().split("\n").pop()!);
  return { ...made, PATH: `${TASK_BIN}:${PATH}` };
};
export const stack = (slot: Slot, run: string, more: Record<string, string> = {}, owner: { stop?: () => Promise<void> } = {}) => {
  const pc = (more: string[], log = "process-compose.log") => ["-U", "-u", `${run}/pc.sock`, "-L", `${run}/${log}`, ...more];
  const env = { ...slot.env, MISE_LOCKED: "0", PATH: misePath(), ...more };
  // The stack is the root of a run of its own (its own process group, so a signal to the launch's reaches only `down`):
  // when it ends, so does everything it started that `down` left.
  let rootpid = 0;
  const status = ownRun(["sh", "-c", 'out=$1; shift; exec "$@" >"$out" 2>/dev/null </dev/null', "sh", `${run}/processes.log`, "process-compose", ...pc(["-f", ".bayt/process-compose.yaml", "up", "--tui=false"])],
    { what: `launch slot ${slot.n}`, cwd: slot.dir, env, pgroup: true, stop: owner.stop, onSpawn: (pid) => { rootpid = pid; } });
  const child = { status: status.then((r) => ({ code: r.code })), kill: (sig: Deno.Signal) => { if (rootpid) Deno.kill(rootpid, sig); } };
  let exited = false;
  child.status.then(() => exited = true, () => exited = true);
  const down = async () => {
    await new Deno.Command("process-compose", { args: pc(["down"], "down.log"), cwd: slot.dir, env, stdout: "null", stderr: "null" }).output();
    const stopped = await Promise.race([child.status.then(() => true), new Promise<boolean>((r) => setTimeout(() => r(exited), 60_000))]);
    if (!stopped) { try { child.kill("SIGTERM"); } catch { /* gone */ } await Promise.race([child.status, new Promise((r) => setTimeout(r, 30_000))]); }
    await sweep(slot.door);
  };
  return { child, pc, env, exited: () => exited, down };
};
// Why a stack ended, from its two logs: each process that exited with a code of its own (not 0, nor the
// -1 of one the shutdown stopped) or never became ready, named with its code and its own last lines
// (processes.log), after the last lines of process-compose's log. Its own lines come last: whoever
// reads a launch's output keeps its end.
export function whyEnded(pcLog: string, processes: string, lines = 20): string {
  // deno-lint-ignore no-control-regex
  const plain = (t: string) => t.replace(/\x1b\[[0-9;]*m/g, "").replace(/\x1b\][^\x07]*\x07/g, "");
  const log = plain(pcLog).split("\n"), out = plain(processes).split("\n");
  const failed = new Map<string, string>();
  for (const l of log) {
    const exit = /Exited exit_code=(-?\d+) process=(\S+)/.exec(l);
    if (exit && exit[1] !== "0" && exit[1] !== "-1") failed.set(exit[2], `exited ${exit[1]}`);
    const never = /Process (\S+) was aborted and won't become ready/.exec(l);
    if (never && !failed.has(never[1])) failed.set(never[1], "never became ready");
  }
  const parts = [log.filter((l) => l.trim()).slice(-15).join("\n")];
  for (const [name, how] of failed) {
    const own = out.filter((l) => l.startsWith(`[${name}\t]`) || l.startsWith(`[${name} `) || l.startsWith(`[${name}]`)).slice(-lines);
    parts.push(`${name} ${how}; its last lines:${own.length ? `\n${own.join("\n")}` : " none"}`);
  }
  return parts.filter(Boolean).join("\n");
}

// What still listens in a stack's range once its process-compose is gone, stopped: SIGTERM to each
// listener's process group (host.sh's, which stops its postgres and removes its data), SIGKILL to
// what is left after 30 s. Said, naming each.
export const sweep = async (door: number) => {
  if (!door) return;
  let open = await answering(door);
  if (!open.length) return;
  const left = await listening(door, open);
  say(`the stack's processes outlived its process-compose, stopped: ${holdersOf(left)}`);
  const groupOf = async (pid: number) => Number(new TextDecoder().decode((await new Deno.Command("ps", { args: ["-o", "pgid=", "-p", String(pid)], stdout: "piped", stderr: "null" }).output().catch(() => undefined))?.stdout ?? new Uint8Array()).trim()) || 0;
  // A process group as its negative id, a lone process (no ps) as its pid.
  // Never this launch's own group.
  const own = await groupOf(Deno.pid), targets = new Set<number>();
  for (const l of left) if (l.pid > 0) { const g = await groupOf(l.pid); if (g !== own) targets.add(g > 1 ? -g : l.pid); }
  const signal = (s: Deno.Signal) => { for (const t of targets) try { Deno.kill(t, s); } catch { /* gone */ } };
  signal("SIGTERM");
  for (let i = 0; i < 30 && open.length; i++) { await new Promise((r) => setTimeout(r, 1000)); open = await answering(door); }
  if (open.length) signal("SIGKILL");
};

// The warm stack's dev loop (launch --watch), as `sayt launch --watch` is the docker stack's: a
// service restarts when a path its develop.watch names changes (bayt.<service>.json, from what
// the cluster marks watched: the shell, its screens, handlers and styles, the messages, the
// migrations). The served folder is made again from the checkout (`refresh`, the launch's own
// preparation) before a service restarts, so the door serves the edit and a reload shows it (the
// door copies nothing itself: it serves the folder as it is); the
// database runs its migrations again, each idempotent. A CUE file changed runs generate in the
// checkout first; what it writes into a watched path restarts its service; when the stack's
// own definition changed it says to launch again. Nothing is built again.
export const watch = (slot: Slot, pc: (more: string[]) => string[], env: Record<string, string>, refresh?: () => Promise<unknown>, fail?: (why: string) => Promise<void>) => {
  const services = () => {
    const by = new Map<string, Set<string>>();
    for (const e of Deno.readDirSync(`${app}/.bayt`)) {
      const m = e.name.match(/^bayt\.(.+)\.json$/);
      if (!m) continue;
      let list: { path: string }[] = [];
      try { list = JSON.parse(Deno.readTextFileSync(`${app}/.bayt/${e.name}`))?.compose?.develop?.watch ?? []; } catch { continue; }
      for (const w of list) {
        const p = decodeURIComponent(new URL(w.path, `file://${app}/.bayt/`).pathname).replace(/\/$/, "");
        if (!by.has(p)) by.set(p, new Set());
        by.get(p)!.add(m[1]);
      }
    }
    return by;
  };
  let by = services();
  const pcRun = (more: string[]) => new Deno.Command("process-compose", { args: pc(more).filter((a, i, all) => a !== "-L" && all[i - 1] !== "-L"), cwd: slot.dir, env, stdout: "null", stderr: "piped" }).output();
  const mtime = (p: string) => { try { return Deno.statSync(p).mtime?.getTime() ?? 0; } catch { return 0; } };
  // The CUE files generate itself wrote, at the time it left them: an event on one of them,
  // unchanged since, is generate's own, not an edit, so generate never runs itself again.
  const generated = new Map<string, number>();
  const pending = new Set<string>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let busy = Promise.resolve();
  const apply = (first: number) => busy = busy.then(async () => {
    const paths = [...pending];
    pending.clear();
    if (paths.some((p) => p.endsWith(".cue"))) {
      say("watch: CUE changed, generate");
      const start = Date.now();
      const gen = await new Deno.Command("./saytw", { args: ["generate"], cwd: app, stdout: "null", stderr: "null" }).output();
      const walk = (d: string) => {
        for (const e of Deno.readDirSync(d)) {
          const f = `${d}/${e.name}`;
          if (e.isDirectory && !["node_modules", ".bayt", ".task", "cue.mod", ".git"].includes(e.name)) walk(f);
          else if (e.isFile && e.name.endsWith(".cue") && mtime(f) >= start) generated.set(f, mtime(f));
        }
      };
      walk(app);
      for (const [f, t] of generated) if (pending.has(f) && mtime(f) === t) pending.delete(f);
      if (!gen.success) { say(`watch: generate exited ${gen.code}, the stack left as it was`); return; }
      say(`watch: generate done, ${Date.now() - first} ms after the edit; what it wrote restarts what serves it`);
      // A definition changed is a relaunch (seconds, on a slot): process-compose 1.122's project
      // update lost the database's place in the run order after a restart and took the stack down.
      const { text } = layout(await Deno.readTextFile(`${app}/.bayt/process-compose.yaml`), slot.n);
      if (text !== await Deno.readTextFile(`${slot.dir}/.bayt/process-compose.yaml`)) {
        say("watch: the stack's definition changed (a service, a port or a static added): stop this launch and launch again");
      }
      by = services();
    }
    const restart = new Set<string>();
    for (const p of paths) for (const [w, s] of by) if (p === w || p.startsWith(`${w}/`)) s.forEach((x) => restart.add(x));
    // A refresh that fails has deleted the served folder: the launch stops (its stack down, its slot
    // released) rather than restart services over an absent or partial tree.
    if (restart.size && refresh) {
      try { await refresh(); } catch (e) {
        const why = `watch: the served folder could not be made again (${(e as Error)?.message ?? e}): the launch stops`;
        if (fail) return await fail(why);
        throw new Error(why);
      }
    }
    for (const s of restart) {
      const r = await pcRun(["process", "restart", s]);
      say(r.success ? `watch: ${s} restarted, ${Date.now() - first} ms after the edit` : `watch: ${s} failed to restart: ${new TextDecoder().decode(r.stderr).trim()}`);
    }
  }).catch((e) => say(`watch: ${e?.message ?? e}; still watching`));
  // The app's folder, not each file: an editor that saves by rename replaces the file a watch held.
  // Events keep coming while generate runs: what it writes into a watched path restarts its service.
  const watcher = Deno.watchFs(app, { recursive: true });
  say(`watch: ${by.size} paths of ${new Set([...by.values()].flatMap((s) => [...s])).size} services, and the app's CUE`);
  let first = 0;
  (async () => {
    for await (const ev of watcher) {
      if (ev.kind === "access") continue;
      const hit = ev.paths.filter((p) => !p.includes("/.bayt/") && !p.includes("/.task/") && !p.includes("/node_modules/") && !p.includes("/cue.mod/") &&
        (p.endsWith(".cue") ? generated.get(p) !== mtime(p) : [...by.keys()].some((w) => p === w || p.startsWith(`${w}/`))));
      if (!hit.length) continue;
      if (!pending.size) first = Date.now();
      hit.forEach((p) => pending.add(p));
      clearTimeout(timer);
      timer = setTimeout(() => apply(first), 150);
    }
  })().catch((e) => say(`watch: stopped: ${e?.message ?? e}`));
  return () => watcher.close();
};

// ps's CPU time, [[dd-]hh:]mm:ss[.cc], in seconds.
export const cpuSeconds = (time: string): number => {
  const m = time.trim().match(/^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/);
  return m ? ((Number(m[1] ?? 0) * 24 + Number(m[2] ?? 0)) * 60 + Number(m[3])) * 60 + Number(m[4]) : 0;
};
// What a process holds in memory now (GB), its resident set, and the CPU seconds it has used; 0 once it is gone.
const residentOf = async (pid: number) => {
  const r = await new Deno.Command("ps", { args: ["-o", "rss=,time=", "-p", String(pid)], stdout: "piped", stderr: "null" }).output().catch(() => undefined);
  const [rss, time] = new TextDecoder().decode(r?.stdout ?? new Uint8Array()).trim().split(/\s+/);
  return { gb: (Number(rss) || 0) / 2 ** 20, cpu: cpuSeconds(time ?? "") };
};
// Why the memory watchdog (tools/cue-budget/watchdog.sh) killed a pid, if it did: "over" (its own
// size, past the ceiling) or "pressure" (the machine's, it the largest).
const killedFor = (pid: number) => {
  const dir = Deno.env.get("CUE_WATCHDOG_DIR") ?? `${Deno.env.get("HOME")}/.cache/pronto/cue-watchdog`;
  // Read once and removed: a later process given the same pid is not taken for it.
  try { const why = Deno.readTextFileSync(`${dir}/killed/${pid}`).trim().split(" ")[0]; Deno.removeSync(`${dir}/killed/${pid}`); return why; } catch { return ""; }
};

// The run owner (PRONTO-684: every gate stops what it starts). A run is the command a claim runs and everything
// it starts, whatever it does to hide: a double fork, setsid, a parent that exits first, a platform binary.
// Not a process group, not a sample of the tree: the kernel's own attribution, read when the run ends.
//
//   macOS. The root is started by posix_spawn with responsibility_spawnattrs_setdisclaim, so the kernel gives it
//   itself as its responsible pid and every descendant inherits it; none can clear it. The members are the
//   processes of this uid whose responsible pid (responsibility_get_pid_responsible_for_pid) is the root.
//   Linux. This process is made a child subreaper (prctl PR_SET_CHILD_SUBREAPER), so every orphan re-parents to
//   it: the members are its descendants in /proc.
//   The root's exit is waited for with waitid(WNOWAIT), so its zombie, and its pid, stay ours until the members
//   are gone: no other process can carry the root's pid as its responsible pid meanwhile. The root is reaped last.
//
// Reads fail closed: a list that cannot be read, a live pid of this uid that cannot be read (but ESRCH, which is
// gone), a library or symbol that cannot be opened, fail the run, with their cause. Another uid's EPERM is skipped.
// The ledger, <pool>/runs/<rootpid>-<rootstart>, says which runs are live: a claim inside one does not own.
const ESRCH = 3, EPERM = 1;
export type PidRow = { pid: number; errno?: number; uid?: number; start?: number; ppid?: number; responsible?: number; zombie?: boolean;
  // Linux, for a child of the supervisor only: the PRONTO_RUN its environ carries, or that it could not be read.
  marker?: string; unreadable?: boolean };
// One read of the machine's processes: `listError` when the list itself failed; a row per listed pid, with the errno
// of what could not be read of it (start in µs: since the epoch on macOS, since boot on Linux).
export type PidTable = { os: "darwin" | "linux"; uid: number; listError?: string; rows: PidRow[] };
export type RunRecord = { rootpid: number; rootstart: number; superpid: number; superstart: number; uid: number; what: string; state: "running" | "done"; run?: string; runner?: string; left?: string[] };
export type Member = { pid: number; start: number; age?: number };
export type Plan = { members: Member[]; skipped: { pid: number; why: string }[]; failed: string[] };
const descendants = (rows: readonly PidRow[], tops: readonly number[]): Set<number> => {
  const kids = new Map<number, number[]>();
  for (const r of rows) if (r.errno === undefined && r.ppid !== undefined) kids.set(r.ppid, [...(kids.get(r.ppid) ?? []), r.pid]);
  const out = new Set<number>(), todo = [...tops];
  for (let p = todo.pop(); p !== undefined; p = todo.pop()) for (const k of kids.get(p) ?? []) if (!out.has(k)) { out.add(k); todo.push(k); }
  return out;
};
// Who a run's members are in `table`, for `record` (pure: the table and the clock are given).
// macOS: this uid's live processes whose responsible pid is the root, started at or after it, and, when the root's pid
// is now held by another process Q (a start time that is not the record's), before Q: what is attributed to a reused
// pid and started after its new holder is the holder's, never ours. Linux: the root's subtree, and the orphans re-parented
// to the supervisor (a subreaper) that carry its PRONTO_RUN marker, with theirs; never the supervisor's own children.
// A read error on a live pid of this uid is a failure (fail closed); ESRCH is a pid gone; another uid's, skipped.
export function planReap(table: PidTable, record: RunRecord, now: number): Plan {
  const plan: Plan = { members: [], skipped: [], failed: [] };
  if (table.listError !== undefined) { plan.failed.push(`the process list could not be read: ${table.listError}`); return plan; }
  const root = table.rows.find((r) => r.pid === record.rootpid);
  const holder = root && root.errno === undefined && root.start !== undefined && root.start !== record.rootstart ? root.start : undefined;
  const runId = `${record.superpid}-${record.superstart}`;
  const orphans = table.os === "linux" ? table.rows.filter((r) => r.errno === undefined && r.ppid === record.superpid && r.pid !== record.rootpid && r.marker === runId).map((r) => r.pid) : [];
  const under = table.os === "linux" ? new Set([...descendants(table.rows, [record.rootpid, ...orphans]), ...orphans]) : undefined;
  for (const r of table.rows) {
    if (r.pid === record.rootpid || r.pid === record.superpid) continue;
    if (r.errno !== undefined) {
      if (r.errno === ESRCH) plan.skipped.push({ pid: r.pid, why: "gone" });
      else if ((r.uid !== undefined && r.uid !== table.uid) || (r.uid === undefined && r.errno === EPERM)) plan.skipped.push({ pid: r.pid, why: "another account's" });
      else plan.failed.push(`pid ${r.pid} could not be read (errno ${r.errno})`);
      continue;
    }
    if (r.uid !== table.uid) { plan.skipped.push({ pid: r.pid, why: "another account's" }); continue; }
    if (r.zombie) { plan.skipped.push({ pid: r.pid, why: "a zombie" }); continue; }
    if (r.unreadable) { plan.skipped.push({ pid: r.pid, why: "its environ could not be read" }); continue; }
    if (r.start === undefined) { plan.failed.push(`pid ${r.pid} has no start time`); continue; }
    const mine = under ? under.has(r.pid) : r.responsible === record.rootpid && r.start >= record.rootstart && (holder === undefined || r.start < holder);
    if (mine) plan.members.push({ pid: r.pid, start: r.start, age: table.os === "darwin" ? Math.max(0, now - r.start / 1000) : undefined });
    else if (!under && r.responsible === record.rootpid) plan.skipped.push({ pid: r.pid, why: "started after the root's pid was reused" });
  }
  return plan;
}
const supervisorLive = (table: PidTable, record: RunRecord) => {
  const s = table.rows.find((r) => r.pid === record.superpid);
  return s !== undefined && s.errno === undefined && s.start === record.superstart && !s.zombie;
};
// The runs whose supervisor is gone (its pid and start no longer match), each with what it left (pure). A list that
// cannot be read fails every record, closed. A Linux run's members are found by the environ marker (not here).
export function reapDead(records: readonly RunRecord[], table: PidTable, now = Date.now()): { run: RunRecord; plan: Plan }[] {
  return records.filter((r) => r.rootpid > 0 && (table.listError !== undefined || !supervisorLive(table, r))).map((run) => ({
    run,
    plan: table.os === "linux" && table.listError === undefined
      ? { members: [], skipped: [{ pid: 0, why: "a dead supervisor's members are found by environ marker" }], failed: [] }
      : planReap(table, run, now),
  }));
}
// The live run a process is inside, if any (pure): macOS, its responsible pid is a root whose record is live; either
// OS, a live supervisor with a record is on its parent chain (which also covers the moment between the spawn and the
// record's final name). Neither reads the environment, so an `unset STACK_JOB` cannot defeat it. Throws on an unreadable table.
export function nestedIn(table: PidTable, self: number, records: readonly RunRecord[]): RunRecord | undefined {
  if (table.listError !== undefined) throw new Error(`the process list could not be read: ${table.listError}`);
  const by = new Map(table.rows.map((r) => [r.pid, r]));
  const me = by.get(self);
  if (!me || me.errno !== undefined) throw new Error(`this process (${self}) could not be read in the process list${me?.errno !== undefined ? ` (errno ${me.errno})` : ""}`);
  if (table.os === "darwin" && me.responsible !== undefined && me.responsible > 0 && me.responsible !== self) {
    const root = by.get(me.responsible);
    const rec = records.find((r) => r.rootpid === me.responsible && root !== undefined && root.errno === undefined && root.start === r.rootstart
      && by.get(r.superpid)?.errno === undefined && by.get(r.superpid)?.start === r.superstart);
    if (rec) return rec;
  }
  for (let p = me.ppid ?? 0, i = 0; p > 1 && i < 64; i++) {
    const row = by.get(p);
    const rec = records.find((r) => r.state === "running" && r.superpid === p && row !== undefined && row.errno === undefined && row.start === r.superstart);
    if (rec) return rec;
    p = row?.ppid ?? 0;
  }
  return undefined;
}

// The keeper's script (macOS), run by `deno eval`: start the command, write its pid to <dir>/cmd and, when it has exited,
// "<code> <signal>" to <dir>/done, and stay until <dir>/release exists (the supervisor lets go). It must be a third-party
// binary, as deno is: under a root that is an Apple one (sh, perl) the kernel makes every non-Apple process a descendant
// execs (deno, bash, postgres) responsible for itself, and with it everything it starts, so a keeper written in perl lost
// all of them (measured 2026-11-20). The signals that end a run are caught here and go to the command, which has them by default.
// If the supervisor dies instead (polled every half second), the keeper ends the run itself (orphaned); 12 h is only a backstop.
const KEEPER = String.raw`const [dir, slotUrl, sp, ss, ...cmd] = Deno.args;
const superpid = Number(sp), superstart = Number(ss);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const put = (f, text) => { Deno.writeTextFileSync(dir + "/" + f + ".tmp", text); Deno.renameSync(dir + "/" + f + ".tmp", dir + "/" + f); };
const exists = (f) => { try { Deno.statSync(dir + "/" + f); return true; } catch { return false; } };
for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) Deno.addSignalListener(s, () => {});
const nums = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGSEGV: 11, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15 };
let child = null, finished = false, code = 127;
try { child = new Deno.Command(cmd[0], { args: cmd.slice(1), stdin: "inherit", stdout: "inherit", stderr: "inherit" }).spawn(); }
catch (e) { console.error("slot: " + cmd[0] + ": " + e.message); put("cmd", "1"); put("done", "127 0"); finished = true; }
if (child) {
  put("cmd", String(child.pid));
  child.status.then((st) => { code = st.code; put("done", st.code + " " + (st.signal ? (nums[st.signal] ?? 1) : 0)); finished = true; });
}
// The supervisor is gone without letting go (it was killed, or exited with the run pending): this keeper ends the run,
// as the supervisor would: the command told TERM and, after 10 s, KILL; then what the run left; then its record.
const orphaned = async () => {
  const m = await import(slotUrl), sys = m.ownSys();
  if (child && !finished) {
    try { child.kill("SIGTERM"); } catch { /* gone */ }
    await Promise.race([child.status, sleep(10000)]);
    if (!finished) { try { child.kill("SIGKILL"); } catch { /* gone */ } await Promise.race([child.status, sleep(5000)]); }
  }
  const rec = m.recordOf(m.readRecords(), Deno.pid, superpid, superstart);
  if (rec) {
    await m.stopMembers(sys, rec);
    try { Deno.removeSync((Deno.env.get("STACK_POOL") ?? "/tmp/pronto-stacks") + "/runs/" + rec.rootpid + "-" + rec.rootstart); } catch { /* gone */ }
  }
  try { Deno.removeSync(dir, { recursive: true }); } catch { /* gone */ }
};
let sys, tick = 0;
for (const end = Date.now() + 12 * 3600_000; Date.now() < end; await sleep(50)) {
  if (exists("release")) {
    // Let go while the command still runs (the supervisor failed on its way): it is killed, so nothing waits on it.
    if (!finished && child) { try { child.kill("SIGKILL"); } catch { /* gone */ } await Promise.race([child.status, sleep(5000)]); }
    break;
  }
  if (++tick % 10 === 0) {
    try {
      sys ??= (await import(slotUrl)).ownSys();
      const r = sys.row(superpid);
      if (r.errno === 3 || (r.errno === undefined && (r.start !== superstart || r.zombie))) { await orphaned(); break; }
    } catch (e) { console.error("slot keeper: " + e.message); }
  }
}
Deno.exit(code);
`;

// What the owner asks of the machine. The real one is below; the logic above and teardown take any.
export interface Sys {
  os: "darwin" | "linux";
  uid: number;
  table(): PidTable;
  // One signal to one process, after checking its start time is still the one read: "sent", "gone", "changed" (the pid is another process now), or the error.
  signal(pid: number, start: number, sig: "SIGTERM" | "SIGKILL" | "SIGINT" | "SIGHUP"): string;
  command(pid: number): string;
  // Linux: reaps an orphan the subreaper inherited, once it has died.
  reap?(pid: number): void;
}
const sleepMs = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const ageText = (ms?: number) => ms === undefined ? "" : `age ${humanAge(ms)}, `;
// The members of a run now, with the failures of the read.
export const listMembers = (sys: Sys, record: RunRecord): Plan => planReap(sys.table(), record, Date.now());
const name = (sys: Sys, m: Member) => `pid ${m.pid} (${ageText(m.age)}${sys.command(m.pid) || "?"})`;
// Stops what a run left, once its root has exited: list the members, TERM, wait `termMs`, KILL, list again, and again
// (a member may start another as it dies). What is still there after that is `survivors`. `listed` is everything seen.
export async function stopMembers(sys: Sys, record: RunRecord, termMs = 5000, pollMs = 100): Promise<{ listed: string[]; survivors: string[]; failed: string[] }> {
  const listed = new Map<number, string>(), failed: string[] = [];
  const key = (m: Member) => `${m.pid}:${m.start}`;
  const look = () => { const p = listMembers(sys, record); for (const f of p.failed) if (!failed.includes(f)) failed.push(f); for (const m of p.members) if (!listed.has(m.pid)) listed.set(m.pid, name(sys, m)); return p.members; };
  const send = (ms: Member[], sig: "SIGTERM" | "SIGKILL") => { for (const m of ms) { const r = sys.signal(m.pid, m.start, sig); if (!["sent", "gone", "changed"].includes(r)) failed.push(`pid ${m.pid} could not be signalled (${r})`); } };
  let now = look();
  if (now.length) {
    send(now, "SIGTERM");
    const first = new Set(now.map(key));
    for (let waited = 0; waited < termMs; waited += pollMs) {
      await sleepMs(pollMs);
      if (sys.os === "linux") for (const pid of listed.keys()) sys.reap?.(pid);
      now = look().filter((m) => first.has(key(m)));
      if (!now.length) break;
    }
  }
  for (let round = 0; round < 5; round++) {
    now = look();
    if (!now.length) break;
    send(now, "SIGKILL");
    await sleepMs(200);
    if (sys.os === "linux") for (const pid of listed.keys()) sys.reap?.(pid);
  }
  now = look();
  return { listed: [...listed.values()], survivors: now.map((m) => name(sys, m)), failed };
}

// The record of the run a keeper (root pid `rootpid`) belongs to: its supervisor's pid and start must match too, since a
// "done" record of an older run that left survivors can carry the same, reused, root pid.
export const recordOf = (records: readonly RunRecord[], rootpid: number, superpid: number, superstart: number): RunRecord | undefined =>
  records.find((r) => r.rootpid === rootpid && r.superpid === superpid && r.superstart === superstart);
// The ledger: one file a live run, <pool>/runs/<rootpid>-<rootstart> (a `pending-` one between its spawn and its name).
const runsDir = () => `${pool}/runs`;
export function readRecords(dir = runsDir()): RunRecord[] {
  const out: RunRecord[] = [];
  let names: string[];
  try { names = [...Deno.readDirSync(dir)].map((e) => e.name); } catch (e) { if (e instanceof Deno.errors.NotFound) return out; throw e; }
  for (const n of names) {
    if (!/^(pending-)?[0-9]+-[0-9]+$/.test(n)) continue;
    try { const r = JSON.parse(Deno.readTextFileSync(`${dir}/${n}`)); if (Number.isInteger(r.superpid) && Number.isInteger(r.rootpid)) out.push(r); } catch { /* being written, or not ours */ }
  }
  return out;
}
const writeRecord = (file: string, r: RunRecord) => { Deno.writeTextFileSync(`${file}.tmp`, JSON.stringify(r)); Deno.renameSync(`${file}.tmp`, file); };

// The real machine: libSystem on a Mac, glibc's libc.so.6 on Linux (a musl image fails closed, naming it).
export interface RealSys extends Sys {
  // A command started with the responsibility disclaimed (macOS) or as a plain child (Linux).
  spawn(cmd: string[], env: Record<string, string>, cwd: string | undefined, opts?: { disclaim?: boolean; setsid?: boolean; pgroup?: boolean }): number;
  // The root of an owned run (see `Root`).
  root(cmd: string[], env: Record<string, string>, cwd: string | undefined, opts?: { pgroup?: boolean }): Promise<Root>;
  // Waits for the exit of a child, leaving it a zombie (waitid WNOWAIT): its pid stays ours.
  exited(pid: number): Promise<{ code: number; signal: number }>;
  // Reaps a child that exited.
  reap(pid: number): void;
  row(pid: number): PidRow;
}
// The root of a run: `pid` is what the members are attributed to (macOS) or the supervisor's own child (Linux), and
// `cmd` the command, whose exit `done` says. On macOS, the kernel re-points the responsible pid of every descendant to
// itself the moment the process it names exits (measured, 2026-11-20: even while its zombie is held), so the command is
// not the root: a keeper is (a small perl, disclaimed), the command its child, and the keeper does not exit until
// `end()` lets it go, after the members have been listed and stopped. Linux needs none: orphans re-parent to the subreaper.
export type Root = {
  pid: number; cmd: number; cmdStart?: number;
  done: Promise<{ code: number; signal: number }>;
  // Lets the root go, waits until it has exited, and reaps it: last, so its pid stayed ours throughout.
  end(): Promise<void>;
};
// deno-lint-ignore no-explicit-any
type Fn = (...a: any[]) => any;
let realSys: RealSys | undefined;
export function ownSys(): RealSys {
  if (realSys) return realSys;
  const os = Deno.build.os;
  if (os !== "darwin" && os !== "linux") throw new Error(`slot: the run owner supports macOS and Linux, not ${os}`);
  const common = {
    posix_spawn: { parameters: ["buffer", "buffer", "buffer", "buffer", "buffer", "buffer"], result: "i32" },
    posix_spawnattr_init: { parameters: ["buffer"], result: "i32" },
    posix_spawnattr_destroy: { parameters: ["buffer"], result: "i32" },
    posix_spawnattr_setflags: { parameters: ["buffer", "i16"], result: "i32" },
    posix_spawnattr_setsigdefault: { parameters: ["buffer", "buffer"], result: "i32" },
    posix_spawnattr_setsigmask: { parameters: ["buffer", "buffer"], result: "i32" },
    posix_spawn_file_actions_init: { parameters: ["buffer"], result: "i32" },
    posix_spawn_file_actions_destroy: { parameters: ["buffer"], result: "i32" },
    posix_spawn_file_actions_addchdir_np: { parameters: ["buffer", "buffer"], result: "i32" },
    sigemptyset: { parameters: ["buffer"], result: "i32" },
    sigaddset: { parameters: ["buffer", "i32"], result: "i32" },
    waitid: { parameters: ["i32", "u32", "buffer", "i32"], result: "i32" },
    waitid_nb: { name: "waitid", parameters: ["i32", "u32", "buffer", "i32"], result: "i32", nonblocking: true },
    getuid: { parameters: [], result: "u32" },
  } as const;
  let sym: Record<string, Fn>, libName: string;
  try {
    if (os === "darwin") {
      libName = "libSystem.B.dylib";
      sym = Deno.dlopen(libName, {
        ...common,
        responsibility_spawnattrs_setdisclaim: { parameters: ["buffer", "i32"], result: "i32" },
        responsibility_get_pid_responsible_for_pid: { parameters: ["i32"], result: "i32" },
        proc_listallpids: { parameters: ["pointer", "i32"], result: "i32" },
        proc_pidinfo: { parameters: ["i32", "i32", "u64", "buffer", "i32"], result: "i32" },
        errnoloc: { name: "__error", parameters: [], result: "pointer" },
      } as const).symbols as unknown as Record<string, Fn>;
    } else {
      libName = "libc.so.6";
      sym = Deno.dlopen(libName, {
        ...common,
        prctl: { parameters: ["i32", "u64", "u64", "u64", "u64"], result: "i32" },
        syscall: { parameters: ["i64", "i64", "i64", "i64", "i64"], result: "i64" },
        close: { parameters: ["i32"], result: "i32" },
        sysconf: { parameters: ["i32"], result: "i64" },
        errnoloc: { name: "__errno_location", parameters: [], result: "pointer" },
      } as const).symbols as unknown as Record<string, Fn>;
    }
  } catch (e) {
    throw new Error(`slot: the run owner could not open the process library (${os === "darwin" ? "libSystem" : "libc.so.6, glibc"}): ${e instanceof Error ? e.message : String(e)}`, { cause: e });
  }
  const errno = () => new Deno.UnsafePointerView(sym.errnoloc() as Deno.PointerObject).getInt32();
  const uid = sym.getuid() as number;
  const enc = new TextEncoder();
  const ptr = (b: ArrayBufferView) => Deno.UnsafePointer.of(b as Uint8Array)!;
  const cstr = (s: string) => enc.encode(`${s}\0`);
  const linux = os === "linux";
  const ticks = linux ? Number(sym.sysconf(2)) || 100 : 0;
  // A program found on `path` (the child's, as a shell finds it), or the path as given when it names one.
  const find = (prog: string, path: string): string => {
    if (prog.includes("/")) return prog;
    for (const d of path.split(":")) {
      if (!d) continue;
      try { const st = Deno.statSync(`${d}/${prog}`); if (st.isFile && ((st.mode ?? 0) & 0o111) !== 0) return `${d}/${prog}`; } catch { /* not there */ }
    }
    throw new Error(`slot: ${prog}: command not found (PATH ${path})`);
  };
  const darwinRow = (pid: number): PidRow => {
    const info = new Uint8Array(136);
    const n = sym.proc_pidinfo(pid, 3, 0n, info, 136) as number;
    if (n !== 136) return { pid, errno: errno() || -1 };
    const dv = new DataView(info.buffer);
    const row: PidRow = { pid, uid: dv.getUint32(20, true), ppid: dv.getUint32(16, true), zombie: dv.getUint32(4, true) === 5,
      start: Number(dv.getBigUint64(120, true)) * 1e6 + Number(dv.getBigUint64(128, true)) };
    return row;
  };
  const withResponsible = (row: PidRow): PidRow => {
    if (row.errno !== undefined || row.uid !== uid || row.zombie) return row;
    const r = sym.responsibility_get_pid_responsible_for_pid(row.pid) as number;
    return r > 0 ? { ...row, responsible: r } : { ...row, errno: errno() || -1 };
  };
  const linuxRow = (pid: number): PidRow => {
    try {
      const text = Deno.readTextFileSync(`/proc/${pid}/stat`);
      // pid (comm) state ppid ...: comm may hold spaces and parentheses, so from the last ")".
      const f = text.slice(text.lastIndexOf(")") + 2).split(" ");
      const row: PidRow = { pid, uid: Deno.statSync(`/proc/${pid}`).uid ?? undefined, zombie: f[0] === "Z" || f[0] === "X", ppid: Number(f[1]), start: Number(f[19]) * 1e6 / ticks };
      // A child of this process may be an orphan the subreaper took (marked by PRONTO_RUN) or one of its own (a `ps`, a `down`).
      if (row.ppid === Deno.pid && !row.zombie) {
        try { row.marker = /(?:^|\0)PRONTO_RUN=([^\0]*)/.exec(Deno.readTextFileSync(`/proc/${pid}/environ`))?.[1]; } catch { row.unreadable = true; }
      }
      return row;
    } catch (e) {
      return { pid, errno: e instanceof Deno.errors.NotFound ? ESRCH : e instanceof Deno.errors.PermissionDenied ? EPERM : -1 };
    }
  };
  const row = (pid: number) => linux ? linuxRow(pid) : withResponsible(darwinRow(pid));
  const table = (): PidTable => {
    if (linux) {
      let pids: number[];
      try { pids = [...Deno.readDirSync("/proc")].filter((e) => /^[0-9]+$/.test(e.name)).map((e) => Number(e.name)); } catch (e) { return { os: "linux", uid, listError: `/proc: ${e instanceof Error ? e.message : e}`, rows: [] }; }
      return { os: "linux", uid, rows: pids.map(linuxRow) };
    }
    let cap = (sym.proc_listallpids(null, 0) as number);
    if (!(cap > 0)) return { os: "darwin", uid, listError: `proc_listallpids sizing returned ${cap} (errno ${errno()})`, rows: [] };
    for (let tries = 0; tries < 5; tries++) {
      const buf = new Int32Array(cap + 256 + (cap >> 1));
      const got = sym.proc_listallpids(ptr(buf), buf.byteLength) as number;
      if (got <= 0) return { os: "darwin", uid, listError: `proc_listallpids returned ${got} (errno ${errno()})`, rows: [] };
      if (got < buf.length) return { os: "darwin", uid, rows: [...buf.subarray(0, got)].filter((p) => p > 0).map((p) => withResponsible(darwinRow(p))) };
      cap = buf.length * 2;
    }
    return { os: "darwin", uid, listError: "the process list kept growing while it was read", rows: [] };
  };
  const SIG: Record<"SIGTERM" | "SIGKILL" | "SIGINT" | "SIGHUP", number> = { SIGHUP: 1, SIGINT: 2, SIGKILL: 9, SIGTERM: 15 };
  const signal = (pid: number, start: number, sig: keyof typeof SIG): string => {
    const now = row(pid);
    if (now.errno === ESRCH) return "gone";
    if (now.errno !== undefined) return `errno ${now.errno} reading it`;
    if (now.start !== start) return "changed";
    if (now.zombie) return "gone";
    if (linux) {
      const fd = sym.syscall(434n, BigInt(pid), 0n, 0n, 0n) as number | bigint;
      if (Number(fd) < 0) return errno() === ESRCH ? "gone" : `pidfd_open: errno ${errno()}`;
      try {
        // The pid may have been another process when the pidfd was opened: its start time is checked once more, through it.
        if (row(pid).start !== start) return "changed";
        const r = Number(sym.syscall(424n, BigInt(fd), BigInt(SIG[sig]), 0n, 0n));
        return r === 0 ? "sent" : errno() === ESRCH ? "gone" : `pidfd_send_signal: errno ${errno()}`;
      } finally { sym.close(Number(fd)); }
    }
    try { Deno.kill(pid, sig); return "sent"; } catch (e) { return e instanceof Deno.errors.NotFound ? "gone" : e instanceof Error ? e.message : String(e); }
  };
  const command = (pid: number): string => {
    try {
      const o = new Deno.Command("ps", { args: ["-o", "command=", "-p", String(pid)], stdout: "piped", stderr: "null" }).outputSync();
      return new TextDecoder().decode(o.stdout).trim().slice(0, 160);
    } catch { return ""; }
  };
  const spawn: RealSys["spawn"] = (cmd, env, cwd, opts = {}) => {
    const path = find(cmd[0], env.PATH ?? "");
    const attr = new Uint8Array(512), fa = new Uint8Array(512), sigs = new Uint8Array(128), none = new Uint8Array(128), out = new Int32Array(1);
    const strings = [...cmd, ...Object.entries(env).map(([k, v]) => `${k}=${v}`)];
    const bytes = strings.map(cstr), total = bytes.reduce((n, b) => n + b.length, 0), arena = new Uint8Array(total);
    const base = Deno.UnsafePointer.value(ptr(arena)) as number | bigint;
    const addrs = new BigUint64Array(strings.length + 2);
    let at = 0;
    bytes.forEach((b, i) => { arena.set(b, at); addrs[i] = BigInt(base) + BigInt(at); at += b.length; });
    // argv: the program as the caller named it, then its arguments; envp: the environment; each ends in a null.
    const argc = cmd.length;
    const argv = new BigUint64Array(argc + 1), envp = new BigUint64Array(strings.length - argc + 1);
    for (let i = 0; i < argc; i++) argv[i] = addrs[i];
    for (let i = argc; i < strings.length; i++) envp[i - argc] = addrs[i];
    const check = (what: string, r: number) => { if (r !== 0) throw new Error(`slot: ${what} failed: ${r} (${Deno.build.os})`); };
    check("posix_spawnattr_init", sym.posix_spawnattr_init(attr));
    check("posix_spawn_file_actions_init", sym.posix_spawn_file_actions_init(fa));
    try {
      // The children start with the signals as Deno.Command gave them: SIGPIPE default (Deno ignores it), none blocked.
      sym.sigemptyset(sigs); sym.sigemptyset(none); sym.sigaddset(sigs, 13);
      sym.posix_spawnattr_setsigdefault(attr, sigs); sym.posix_spawnattr_setsigmask(attr, none);
      // POSIX_SPAWN_SETPGROUP 0x2 (a group of its own), SETSIGDEF 0x4, SETSIGMASK 0x8, and on Linux SETSID 0x80.
      check("posix_spawnattr_setflags", sym.posix_spawnattr_setflags(attr, (opts.pgroup ? 0x2 : 0) | 0x4 | 0x8 | (opts.setsid && linux ? 0x80 : 0)));
      if (opts.disclaim !== false && !linux) check("responsibility_spawnattrs_setdisclaim", sym.responsibility_spawnattrs_setdisclaim(attr, 1));
      if (cwd) check(`chdir to ${cwd}`, sym.posix_spawn_file_actions_addchdir_np(fa, cstr(cwd)));
      const r = sym.posix_spawn(out, cstr(path), fa, attr, argv, envp) as number;
      // The strings argv and envp point into are read by the call: kept reachable until it has returned.
      if (Deno.UnsafePointer.of(arena) === null || addrs.length === 0) throw new Error("slot: spawn arena lost");
      if (r !== 0) throw new Error(`slot: could not start ${cmd[0]}: errno ${r}${r === 2 ? " (no such file)" : r === 13 ? " (permission denied)" : r === 8 ? " (exec format error: a script without #!)" : ""}`);
      return out[0];
    } finally { sym.posix_spawnattr_destroy(attr); sym.posix_spawn_file_actions_destroy(fa); }
  };
  const siginfo = (info: Uint8Array) => {
    const dv = new DataView(info.buffer), code = dv.getInt32(8, true), status = dv.getInt32(linux ? 24 : 20, true);
    // CLD_EXITED 1: its code; killed (2) or dumped (3): its signal, and 128 + it as a shell reports.
    return code === 1 ? { code: status, signal: 0 } : { code: 128 + status, signal: status };
  };
  const exited = async (pid: number) => {
    const info = new Uint8Array(128);
    // 4 WEXITED, 0x20 (macOS) or 0x01000000 (Linux) WNOWAIT.
    for (let i = 0; i < 5; i++) if ((await sym.waitid_nb(1, pid, info, 4 | (linux ? 0x01000000 : 0x20)) as number) === 0) return siginfo(info);
    throw new Error(`slot: waitid on ${pid} failed`);
  };
  const reap = (pid: number) => { sym.waitid(1, pid, new Uint8Array(128), 4 | 1); };
  const root: RealSys["root"] = async (cmd, env, cwd, opts = {}) => {
    if (linux) {
      // Orphans re-parent to this process, so the command can be the root.
      if (sym.prctl(36, 1n, 0n, 0n, 0n) !== 0) throw new Error(`slot: prctl(PR_SET_CHILD_SUBREAPER) failed: errno ${errno()}`);
      const pid = spawn(cmd, env, cwd, { pgroup: opts.pgroup });
      return { pid, cmd: pid, cmdStart: row(pid).start, done: exited(pid), end: async () => { await exited(pid); reap(pid); } };
    }
    // The keeper talks through two files in a folder of its own: it writes `cmd` (the command's pid) and `done`
    // ("<code> <signal>"), and leaves when `release` appears.
    const dir = Deno.makeTempDirSync({ dir: runsDir(), prefix: "k-" });
    const pid = spawn([Deno.execPath(), "eval", "--no-config", "--no-lock", "-A", KEEPER, dir, import.meta.url, String(Deno.pid), String(row(Deno.pid).start), ...cmd], env, cwd, { pgroup: opts.pgroup });
    const read = (f: string) => { try { return Deno.readTextFileSync(`${dir}/${f}`).trim(); } catch { return undefined; } };
    const poll = async (f: string, ms: number) => {
      for (const end = Date.now() + ms; Date.now() < end;) {
        const v = read(f);
        if (v) return v;
        await sleepMs(20);
      }
      return undefined;
    };
    const gone = async (why: string) => { Deno.kill(pid, "SIGKILL"); await exited(pid).catch(() => {}); reap(pid); try { Deno.removeSync(dir, { recursive: true }); } catch { /* gone */ } throw new Error(why); };
    const first = await poll("cmd", 60_000);
    if (!(Number(first) > 0)) return await gone(`slot: the keeper of the run did not start its command (said ${JSON.stringify(first ?? "nothing")})`);
    // The keeper ends before it says "done" only if something killed it.
    const done = (async () => {
      for (;;) {
        const v = read("done");
        if (v) { const [code, signal] = v.split(" ").map(Number); return { code, signal }; }
        if (row(pid).errno === ESRCH) throw new Error("slot: the keeper of the run ended before its command did");
        await sleepMs(20);
      }
    })();
    done.catch(() => {});
    return {
      pid, cmd: Number(first), cmdStart: row(Number(first)).start, done,
      end: async () => {
        Deno.writeTextFileSync(`${dir}/release`, "x");
        await exited(pid);
        reap(pid);
        try { Deno.removeSync(dir, { recursive: true }); } catch { /* gone */ }
      },
    };
  };
  realSys = { os, uid, table, signal, command, row, spawn, root, exited, reap };
  return realSys;
}

export type OwnOpts = {
  what?: string;
  // How long the root has, once it is told to stop, before it is killed (ms; 120 s as every wait for a child here).
  grace?: number;
  // How long the members have to end on TERM, before KILL (ms; 5 s).
  termMs?: number;
  // The run is stopped as a signal would stop it, and ends 124, after this long (ms).
  timeoutMs?: number;
  env?: Record<string, string>;
  cwd?: string;
  // A file the root's "<pid> <start>" is written to as soon as it is started.
  rootOut?: string;
  // Called with the root's pid as soon as it is started.
  onSpawn?: (pid: number) => void;
  // How the caller stops its own run orderly (a stack's `down`), in place of the TERM to the root and its members.
  stop?: () => Promise<void>;
  // The root in a process group of its own (a signal to this process's group does not reach it).
  pgroup?: boolean;
  sys?: RealSys;
};
export type OwnResult = { code: number; signal: number; rootpid: number; owned: boolean; leftovers: string[]; failed: string[] };
const SIGNUMS: Record<string, number> = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGABRT: 6, SIGKILL: 9, SIGSEGV: 11, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15 };
// The number of a signal Deno names (a child's `status.signal`), 0 for none.
export const sigNumber = (name: string | null | undefined): number => name ? SIGNUMS[name] ?? 1 : 0;
// 130 for INT and TERM (as every listener here has ended), 129 for HUP, 124 for the timeout.
const signalCode = (s: string) => s === "SIGHUP" ? 129 : 130;
// Calls `on` with the signal's name at the first INT, TERM or HUP; returns what removes the listeners.
const onStop = (on: (sig: string) => void) => {
  const handlers = (["SIGINT", "SIGTERM", "SIGHUP"] as const).map((s) => [s, () => on(s)] as const);
  for (const [s, h] of handlers) Deno.addSignalListener(s, h);
  return () => { for (const [s, h] of handlers) Deno.removeSignalListener(s, h); };
};
// A command run as a plain child, as before the owner: inside a live run, the outer owner covers what it starts.
async function runPlain(cmd: string[], opts: OwnOpts, env: Record<string, string>): Promise<OwnResult> {
  const c = new Deno.Command(cmd[0], { args: cmd.slice(1), cwd: opts.cwd, env, stdin: "inherit", stdout: "inherit", stderr: "inherit", detached: opts.pgroup }).spawn();
  opts.onSpawn?.(c.pid);
  if (opts.rootOut) Deno.writeTextFileSync(opts.rootOut, `${c.pid}\n`);
  let stopped = 0;
  const handlers = new Map<string, () => void>();
  const stop = async (code: number) => {
    if (stopped) return;
    stopped = code;
    if (opts.stop) await opts.stop().catch(() => {}); else try { c.kill("SIGTERM"); } catch { /* gone */ }
    const gone = await Promise.race([c.status.then(() => true), sleepMs(opts.grace ?? 120_000).then(() => false)]);
    if (!gone) try { c.kill("SIGKILL"); } catch { /* gone */ }
  };
  for (const s of ["SIGINT", "SIGTERM", "SIGHUP"] as const) { const h = () => { stop(signalCode(s)); }; handlers.set(s, h); Deno.addSignalListener(s, h); }
  const timer = opts.timeoutMs ? setTimeout(() => { stop(124); }, opts.timeoutMs) : undefined;
  try {
    const st = await c.status;
    return { code: stopped || st.code, signal: sigNumber(st.signal), rootpid: c.pid, owned: false, leftovers: [], failed: [] };
  } finally {
    clearTimeout(timer);
    for (const [s, h] of handlers) Deno.removeSignalListener(s as Deno.Signal, h);
  }
}
// Runs `cmd` as the root of a run this process owns, and ends it as the design says: on a pass, a failure, a timeout,
// INT, TERM or HUP, TERM the members (the root too, which has its grace to run its own traps), and once the root has
// exited list what is left, TERM, wait, KILL, list again; what survives that fails the run, named. The root's zombie is
// reaped last. A passing root that left processes running still passes: each is said, as "left running by <what>".
export async function ownRun(cmd: string[], opts: OwnOpts = {}): Promise<OwnResult> {
  const what = opts.what ?? cmd.join(" ");
  const env = { ...Deno.env.toObject(), ...opts.env };
  const sys = opts.sys ?? ownSys();
  if (nestedIn(sys.table(), Deno.pid, readRecords())) return await runPlain(cmd, opts, env);
  // From here, before anything is awaited, a signal is this owner's: one that comes before the root exists is acted on once it does.
  let begin: ((code: number) => void) | undefined, early = 0;
  let removeListeners = onStop((s) => { if (begin) begin(signalCode(s)); else early ||= signalCode(s); });
  let root: Root | undefined, record: RunRecord | undefined, file = "", finished = false, stopCode = 0, pending = "";
  let timer: ReturnType<typeof setTimeout> | undefined, kill: ReturnType<typeof setTimeout> | undefined;
  const failed: string[] = [];
  // The command told `sig` directly, its pid and start time checked: whatever the table says, and whatever became of the keeper.
  const cmdSignal = (sig: "SIGTERM" | "SIGKILL") => {
    if (!root || root.cmdStart === undefined) return;
    const r = sys.signal(root.cmd, root.cmdStart, sig);
    if (!["sent", "gone", "changed"].includes(r)) say(`${what}: the command could not be told ${sig} (${r})`);
  };
  const cmdAlive = () => { const r = root ? sys.row(root.cmd) : undefined; return !!r && r.errno === undefined && r.start === root?.cmdStart && !r.zombie; };
  // The command, then every member, told `sig`, each after its start time is read again; a list that failed is said.
  const tell = (sig: "SIGTERM" | "SIGKILL") => {
    cmdSignal(sig);
    if (!record) return;
    const p = listMembers(sys, record);
    for (const f of p.failed) say(`${what}: ${f}`);
    for (const m of p.members) sys.signal(m.pid, m.start, sig);
  };
  try {
    await Deno.mkdir(runsDir(), { recursive: true, mode: 0o755 });
    requireOwnDir(pool);
    requireOwnDir(runsDir());
    const me = sys.row(Deno.pid);
    if (me.errno !== undefined || me.start === undefined) throw new Error(`slot: this process could not be read (errno ${me.errno}): a run cannot be owned`);
    const base = { superpid: Deno.pid, superstart: me.start, uid: sys.uid, what, state: "running" as const, run: env.GITHUB_RUN_ID, runner: env.RUNNER_NAME };
    // The record exists before the root does, so a claim the root makes at once finds the run it is inside.
    pending = `${runsDir()}/pending-${Deno.pid}-${me.start}`;
    writeRecord(pending, { ...base, rootpid: 0, rootstart: 0 });
    // PRONTO_RUN marks what this run starts, for the Linux members that re-parent to this process.
    root = await sys.root(cmd, { ...env, PRONTO_RUN: `${Deno.pid}-${me.start}` }, opts.cwd, { pgroup: opts.pgroup });
    const r = sys.row(root.pid);
    if (r.errno !== undefined || r.start === undefined) throw new Error(`slot: the root ${root.pid} could not be read (errno ${r.errno}): the run is not owned`);
    record = { ...base, rootpid: root.pid, rootstart: r.start };
    file = `${runsDir()}/${root.pid}-${r.start}`;
    writeRecord(file, record);
    Deno.removeSync(pending);
    opts.onSpawn?.(root.cmd);
    if (opts.rootOut) Deno.writeTextFileSync(opts.rootOut, `${root.pid} ${r.start} ${root.cmd}\n`);
    const grace = opts.grace ?? 120_000;
    const go = (code: number) => {
      if (stopCode) return;
      stopCode = code;
      (async () => {
        if (opts.stop) await opts.stop().catch((e) => say(`${what}: its own stop failed: ${e instanceof Error ? e.message : e}`));
        // As before the owner: the command first, to run its own traps in order (integrate-local.ts, rehearse.ts); its members
        // are stopped once it has exited, or killed with it when its grace has run out.
        else cmdSignal("SIGTERM");
        kill = setTimeout(() => tell("SIGKILL"), grace);
      })();
    };
    begin = go;
    if (early) go(early);
    if (opts.timeoutMs) timer = setTimeout(() => go(124), opts.timeoutMs);
    const status = await root.done;
    clearTimeout(timer); clearTimeout(kill);
    // The root still holds its place: what it started is listed now, and only then is it let go.
    const left = await stopMembers(sys, record, opts.termMs ?? 5000);
    failed.push(...left.failed);
    if (left.listed.length) say(`${what}: ${status.code === 0 && !stopCode ? "passed" : "ended"}, and left running by "${what}": ${left.listed.join("; ")}${left.survivors.length ? "" : " (stopped)"}`);
    for (const s of left.survivors) failed.push(`survived TERM and KILL: ${s}`);
    for (const f of failed) say(`${what}: ${f}`);
    finished = true;
    await root.end();
    if (left.survivors.length) writeRecord(file, { ...record, state: "done", left: left.survivors });
    else Deno.removeSync(file);
    return { code: stopCode || (failed.length ? status.code || 1 : status.code), signal: status.signal, rootpid: root.cmd, owned: true, leftovers: left.listed, failed };
  } finally {
    removeListeners();
    clearTimeout(timer); clearTimeout(kill);
    // An error on the way: what the run started is stopped all the same, and the root let go.
    if (root && !finished) {
      // The command is told TERM, given 5 s, and killed, with or without a record, a keeper or a readable table.
      cmdSignal("SIGTERM");
      for (let i = 0; i < 50 && cmdAlive(); i++) await sleepMs(100);
      tell("SIGKILL");
      if (record) await stopMembers(sys, record, 1000).catch(() => {});
      await root.end().catch(() => {});
      if (file) try { Deno.removeSync(file); } catch { /* gone */ }
    }
    if (pending) try { Deno.removeSync(pending); } catch { /* named, or never written */ }
  }
}

// ---- the owner's verbs: own, detach, member, leftovers
const splitArgs = (args: string[]) => {
  const at = args.indexOf("--");
  const flags = args.slice(0, at < 0 ? args.length : at);
  return { cmd: at < 0 ? [] : args.slice(at + 1), flag: (n: string) => flags.includes(n) ? flags[flags.indexOf(n) + 1] : undefined };
};
const seconds = (v: string | undefined) => v === undefined ? undefined : Number(v) * 1000;
// Runs one verb and ends the process; a failure of the owner's own (a library, a list) says its cause and ends 1.
export async function ownerVerb(verb: string, args: string[]): Promise<never> {
  const { cmd, flag } = splitArgs(args);
  try {
    if (verb === "own") {
      if (!cmd.length) { console.error("usage: deno run -A tests/slot.ts own [--what <label>] [--grace <s>] [--timeout <s>] [--root-out <file>] -- <command...>"); Deno.exit(2); }
      const grace = seconds(flag("--grace")), timeoutMs = seconds(flag("--timeout"));
      if ((grace !== undefined && !(grace >= 0)) || (timeoutMs !== undefined && !(timeoutMs > 0))) { console.error("slot own: --grace and --timeout are seconds"); Deno.exit(2); }
      Deno.exit((await ownRun(cmd, { what: flag("--what"), grace, timeoutMs, rootOut: flag("--root-out") })).code);
    }
    if (verb === "detach") {
      // A disclaimed spawn that joins no run (colima's VM outlives the run that started it): its responsible pid is itself, so no owner takes it for a member.
      const what = flag("--what");
      if (!cmd.length || !what) { console.error('usage: deno run -A tests/slot.ts detach --what "<label>" -- <command...>'); Deno.exit(2); }
      const sys = ownSys();
      const pid = sys.spawn(cmd, Deno.env.toObject(), undefined, { disclaim: true, setsid: true });
      say(`detached "${what}": pid ${pid}, in no run`);
      const forward = (s: Deno.Signal) => () => { try { Deno.kill(pid, s); } catch { /* gone */ } };
      for (const s of ["SIGINT", "SIGTERM", "SIGHUP"] as const) Deno.addSignalListener(s, forward(s));
      const st = await sys.exited(pid);
      sys.reap(pid);
      Deno.exit(st.code);
    }
    if (verb === "member") {
      const [root, pid] = [Number(args[0]), Number(args[1])];
      if (!(root > 0) || !(pid > 0)) { console.error("usage: deno run -A tests/slot.ts member <root pid> <pid>"); Deno.exit(2); }
      const t = ownSys().table();
      if (t.listError) { console.error(`slot member: ${t.listError}`); Deno.exit(2); }
      const row = t.rows.find((r) => r.pid === pid);
      if (!row || row.errno !== undefined) Deno.exit(1);
      if (t.os === "darwin") Deno.exit(pid !== root && row.responsible === root ? 0 : 1);
      const rec = readRecords().find((r) => r.rootpid === root);
      Deno.exit(rec && descendants(t.rows, [rec.rootpid]).has(pid) && pid !== root ? 0 : 1);
    }
    if (verb === "leftovers") {
      // Reports what runs whose supervisor is gone left behind; it exits 0 whatever it finds (it does not yet fail a gate).
      const sys = ownSys(), t = sys.table(), dead = reapDead(readRecords(), t);
      let n = 0;
      for (const { run, plan } of dead) {
        for (const m of plan.members) { n++; console.log(`leftover of run ${run.rootpid}-${run.rootstart} "${run.what}" (supervisor ${run.superpid} gone): ${name(sys, m)}`); }
        for (const f of plan.failed) console.log(`run ${run.rootpid}-${run.rootstart} "${run.what}": ${f}`);
      }
      if (t.listError) console.log(`the process list could not be read: ${t.listError}`);
      say(`${n} leftover process(es) of ${dead.length} dead run(s)`);
      Deno.exit(0);
    }
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    Deno.exit(1);
  }
  Deno.exit(2);
}


if (import.meta.main && ["--weight", "--what", "--mem", "--mem-claim", "--cores-claim", "--wait-out", "--mem-learn", "--cores-learn"].includes(Deno.args[0] ?? "")) {
  // A job: its weight claimed (--mem: cue memory and --cores-claim cores from the cue budget instead), no stack, the command run where it is.
  const split = Deno.args.indexOf("--");
  const opts = Deno.args.slice(0, split < 0 ? Deno.args.length : split);
  const cmd = split < 0 ? [] : Deno.args.slice(split + 1);
  const opt = (name: string) => opts[opts.indexOf(name) + 1];
  // --mem-claim is --mem by its other name (the claim, in GB; either makes the job a cue claim).
  const mem = opts.includes("--mem-claim") ? Number(opt("--mem-claim")) : opts.includes("--mem") ? Number(opt("--mem")) : 0;
  const cores = opts.includes("--cores-claim") ? Number(opt("--cores-claim")) : 0;
  const waitOut = opts.includes("--wait-out") ? opt("--wait-out") : undefined;
  const learn = opts.includes("--mem-learn") ? opt("--mem-learn") : undefined;
  const coresLearn = opts.includes("--cores-learn") ? opt("--cores-learn") : undefined;
  // Without --weight: STACK_WEIGHT, else a --mem job weighs no cores (the wrappers from before it did not name one).
  const weight = Number(opts.includes("--weight") ? opt("--weight") : Deno.env.get("STACK_WEIGHT") ?? (mem > 0 ? 0 : weights.stack));
  if (!cmd.length || !(mem >= 0) || !(cores >= 0) || !(weight > 0 || (weight === 0 && mem > 0))) {
    console.error('usage: deno run -A tests/slot.ts --weight <n> [--mem <GB>] [--cores-claim <n>] [--wait-out <file>] [--mem-learn <file>] --what "<label>" -- <command...>');
    Deno.exit(2);
  }
  const what = opts.includes("--what") ? opt("--what") : cmd.join(" ");
  // Before the command runs (waiting in the line) a signal only gives the claim back; once it runs, its owner (ownRun) ends it.
  let slot: Slot | undefined, owned = false;
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    Deno.addSignalListener(signal, () => {
      if (owned) return;
      slot?.release();
      Deno.exit(signal === "SIGHUP" ? 129 : 130);
    });
  }
  let peak = 0, cpu = 0, wall = 0, waited = 0, status: { success: boolean; code: number; signal: string | null };
  for (let attempt = 1; ; attempt++) {
    slot = await claim(Deno.pid, what, weight, true, true, mem, cores);
    // The seconds from its ticket to its admission, over every attempt, for the wrapper's log.
    waited += (slot.admitted - slot.queued) / 1000;
    if (waitOut) await Deno.writeTextFile(waitOut, `${Math.round(waited)}\n`).catch(() => {});
    const held = slot;
    // What it holds, every second, for its peak: the next run's --mem and a watchdog kill's verdict; and the
    // CPU seconds it has used, for the cores it keeps busy.
    let running = true, spawned = 0, childPid = 0;
    // A cue claim's record also says what it holds if that is more than it claimed, so the budget counts it at its real size.
    const record = `${held.dir}/weight`;
    let written = mem;
    const sample = async () => {
      const r = await residentOf(childPid);
      if (!running) return;
      peak = Math.max(peak, r.gb); cpu = Math.max(cpu, r.cpu);
      const want = Math.round(Math.max(mem, r.gb) * 100) / 100;
      if (mem > 0 && want !== written) {
        try {
          const text = await Deno.readTextFile(record);
          if (text.includes(" mem=")) {
            await Deno.writeTextFile(`${record}.${Deno.pid}`, text.replace(/ mem=[0-9.]+/, ` mem=${want}`));
            if (running) { await Deno.rename(`${record}.${Deno.pid}`, record); written = want; } else await Deno.remove(`${record}.${Deno.pid}`);
          }
        } catch { /* the record is gone: released */ }
      }
    };
    let inflight: Promise<void> = Promise.resolve();
    const tick = () => { inflight = sample().catch(() => {}); };
    let sampler: ReturnType<typeof setInterval> | undefined;
    // The command runs as the root of a run this process owns: when it ends, so does everything it started. Its
    // weight is given back only once none of it is running (ownRun waits for that, and KILLs what ignores TERM).
    cpu = 0;
    owned = true;
    const ran = await ownRun(cmd, {
      what, env: { STACK_JOB: String(Deno.pid) },
      onSpawn: (pid) => {
        childPid = pid;
        // The process the claim runs, for a holder that outlives it (a stuck claim holds no memory after a minute).
        Deno.writeTextFileSync(`${held.dir}/child`, String(pid));
        // From its spawn: the wait for the lock and the cores is not its time.
        spawned = Date.now();
        sampler = learn || coresLearn || mem > 0 ? (tick(), setInterval(tick, 1000)) : undefined;
      },
    }).finally(() => { owned = false; });
    running = false;
    wall = (Date.now() - spawned) / 1000;
    clearInterval(sampler);
    await inflight;
    slot.release();
    slot = undefined;
    status = { success: ran.code === 0, code: ran.code, signal: ran.signal === 9 ? "SIGKILL" : null };
    // A signal to this process ended the run (ownRun's 130, 129 or 124): the claim is given back above, and the code is the run's.
    if (mem > 0 && attempt === 1 && status.signal === "SIGKILL" && killedFor(ran.rootpid) === "pressure") {
      say(`${what}: the memory watchdog killed it under the machine's pressure at ${round(peak)} GB; in line again`);
      continue;
    }
    break;
  }
  // Its peak, for the next run's claim. A run that failed or was killed may have stopped before its
  // peak (a missing file, a bad flag): its peak only raises what was learned. One that ended before
  // a sample held next to nothing: learned as such, so it runs outside the lock.
  if (learn) {
    if (!(peak > 0)) peak = 0.05;
    const before = status.success ? 0 : Number((await Deno.readTextFile(learn).catch(() => "")).split(" ")[0]) || 0;
    if (learn.includes("/")) await Deno.mkdir(learn.replace(/\/[^/]*$/, ""), { recursive: true }).catch(() => {});
    await Deno.writeTextFile(learn, `${round(Math.max(peak, before))} ${what}\n`).catch(() => {});
  }
  // The cores it kept busy on average, for the next run's --weight: only from a run of 5 s or more (a
  // shorter one measures its start), and a run that failed only raises it, as the peak is.
  // A wrapper with nowhere to learn passes /dev/null (pronto's cue, its cache unwritable): nothing is learned.
  if (coresLearn && !coresLearn.startsWith("/dev/null") && wall >= 5 && cpu > 0) {
    // Only a first measurement has nothing before it; a file that cannot be read or written fails the run, so a
    // success means the next run's weight was saved.
    const prior = status.success ? "" : await Deno.readTextFile(coresLearn).catch((e) => { if (e instanceof Deno.errors.NotFound) return ""; throw e; });
    const before = Number(prior.trim()) || 0;
    try {
      // A bare filename has no folder to make (mkdir of it would make a directory of that name).
      const dir = coresLearn.includes("/") ? coresLearn.replace(/\/[^/]*$/, "") : "";
      if (dir) await Deno.mkdir(dir, { recursive: true });
      await Deno.writeTextFile(coresLearn, `${Math.round(Math.max(cpu / wall, before) * 100) / 100}\n`);
    } catch (e) {
      console.error(`slot: the measured weight was not saved to ${coresLearn}: ${(e as Error).message}`);
      Deno.exit(status.code || 1);
    }
  }
  Deno.exit(status.code);
}

if (import.meta.main) {
  if (!Deno.args.length) { console.error("usage: deno run -A tests/slot.ts launch [--watch] | <command...> | status | renew [n|pid] | sweep-browsers | own | detach | member | leftovers | --weight <n> --what <label> -- <command...>"); Deno.exit(2); }
  if (["own", "detach", "member", "leftovers"].includes(Deno.args[0])) await ownerVerb(Deno.args[0], Deno.args.slice(1));
  if (Deno.args[0] === "sweep-browsers") {
    const swept = await sweepBrowsers();
    say(`${swept.length} orphaned browser(s) swept`);
    Deno.exit(0);
  }
  if (Deno.args[0] === "status" || Deno.args[0] === "renew") {
    // renew writes deadlines into the pool: only into one that is ours (PRONTO-762), as claim checks.
    if (Deno.args[0] === "renew") requireOwnDir(pool);
    const asked = Deno.args[1] === undefined ? 0 : Number(Deno.args[1]);
    let found = 0;
    const names: string[] = [];
    try { for (const e of Deno.readDirSync(pool)) if (/^(slot|job)-[0-9]+$/.test(e.name)) names.push(e.name); } catch { /* no pool */ }
    if (Deno.args[0] === "status") {
      const f = await foreignHold();
      if (f) console.log(`release hold from ${Deno.env.get("STACK_HOLD_POOL")}: pid ${f.pid} ${f.what}`);
    }
    for (const name of names.sort((a, b) => Number(a.split("-")[1]) - Number(b.split("-")[1]))) {
      const pid = await holder(name);
      if (!await alive(pid)) continue;
      const owner = (await Deno.readTextFile(`${pool}/${name}/owner`).catch(() => "")).trim();
      const deadline = Number(await Deno.readTextFile(`${pool}/${name}/deadline`).catch(() => "0"));
      if (Deno.args[0] === "status") {
        const w = await weighs(name, pid);
        console.log(`${name} pid ${pid} ${owner}${w.mem > 0 ? ` mem ${round(w.mem)} GB cores ${round(w.cores)}` : ""}${deadline ? ` deadline ${brt(deadline)}` : ""}`);
        continue;
      }
      if (!deadline || (asked && asked !== pid && `slot-${asked}` !== name)) continue;
      const next = deadlineOf("launch", Date.now(), launchTtl());
      if (!next) { say(`${name}: STACK_LAUNCH_TTL is 0, no deadline to push`); continue; }
      await Deno.writeTextFile(`${pool}/${name}/deadline`, String(next));
      say(`${name} (pid ${pid}) renewed to ${brt(next)}`);
      found++;
    }
    if (Deno.args[0] === "renew" && !found) { console.error("no live launch with a deadline" + (asked ? ` for ${asked}` : "")); Deno.exit(1); }
    Deno.exit(0);
  }
  const args = /(^|\/)saytw$/.test(Deno.args[0]) && Deno.args[1] === "launch@local" ? ["launch", ...Deno.args.slice(2)] : Deno.args;
  // integrate@host: generate and build here, as its own --generate would, then its suites in the slot's
  // copy (`integrating`): a generate there would write the literal ports back.
  const isSaytw = /(^|\/)saytw$/.test(Deno.args[0]);
  const gated = isSaytw && Deno.args[1] === "integrate@local";
  const hostGate = isSaytw && (Deno.args[1] === "integrate@host" || gated);
  const gateSteps = gated ? gate(app) : undefined;
  if (gateSteps && !await gateSteps.secrets()) { console.error("integrate@local: check-secrets failed: the secrets the app's release reads are not all in place"); Deno.exit(1); }
  // Under a claim of its own (a job: no stack, no ports), so the build takes its weight from the budget
  // like any heavy work; the stack's slot is claimed after, once generate has written its definition.
  if (args !== Deno.args || hostGate) {
    const prep = await claim(Deno.pid, `generate and build for ${args.join(" ")}`, weights.stack, true, true);
    for (const verb of ["generate", "build"]) {
      say(`${verb}, in the checkout, as ${hostGate ? "integrate@host" : "launch@local"} does before its stack`);
      const { code } = await new Deno.Command("./saytw", { args: [verb], cwd: app, stdin: "null", stdout: "inherit", stderr: "inherit" }).output();
      if (code) { prep.release(); Deno.exit(code); }
    }
    prep.release();
  }
  // The tree as it is when its stack starts: generate and build have written what they write.
  const before = gateSteps?.mode === "all" ? await gateSteps.key() : "";
  const slot = await claim(Deno.pid, args.join(" "), Number(Deno.env.get("STACK_WEIGHT") ?? commandWeight(args, Deno.env.toObject())));
  let stopping: (() => Promise<void>) | undefined;
  // Where the command was run from: the owner dir an expiry names (the cwd, not the slot's copy).
  const checkout = Deno.cwd();
  // Once its command runs, its owner (ownRun) takes the signal: the command and what it started are ended there, and the code is 130 (129 for HUP).
  let owned = false;
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    Deno.addSignalListener(signal, async () => { if (owned) return; await stopping?.(); slot.release(); await Deno.remove(`${slot.dir.replace(/\/app$/, "")}/deadline`).catch(() => {}); Deno.exit(signal === "SIGHUP" ? 129 : 130); });
  }
  let code: number;
  if (args[0] === "launch") {
    const tmp = await runDir("slot.");
    const made = await prepare(slot, tmp);
    owned = true;
    const s = stack(slot, tmp, made, { stop: async () => { await stopping?.(); } });
    // The served folder is made anew: omnishell's addressing refuses a tree that already holds its
    // `_immutable-` copies, so a second `prepare` over the first's folder served nothing new.
    const failed = async (why: string) => { say(why); await stopping?.(); slot.release(); await Deno.remove(`${slot.dir.replace(/\/app$/, "")}/deadline`).catch(() => {}); Deno.exit(1); };
    const unwatch = args.includes("--watch") ? watch(slot, s.pc, s.env, async () => { await Deno.remove(`${tmp}/work/served`, { recursive: true }).catch((e) => { if (!(e instanceof Deno.errors.NotFound)) throw e; }); return prepare(slot, tmp); }, failed) : undefined;
    stopping = async () => { say("the stack going down"); unwatch?.(); await s.down(); };
    // The launch ends after its TTL unless renewed (`renew`): the deadline is a file beside the slot's pid.
    const slotDir = slot.dir.replace(/\/app$/, ""), started = brt(Date.now());
    const deadlineFile = `${slotDir}/deadline`;
    const first = deadlineOf("launch", Date.now(), launchTtl());
    if (first) await Deno.writeTextFile(deadlineFile, String(first));
    say(`the stack coming up at ${slot.env.APP_URL}, its log ${tmp}/process-compose.log; stop it with a signal to ${Deno.pid}${first ? `; it ends at ${brt(first)} unless renewed (deno run -A tests/slot.ts renew ${slot.n})` : ""}`);
    if (first) {
      const timer = setInterval(async () => {
        const deadline = Number(await Deno.readTextFile(deadlineFile).catch(() => "0"));
        if (!expired({ kind: "launch", deadline }, Date.now())) return;
        clearInterval(timer);
        const line = `the launch timed out and is stopped: ${args.join(" ")}, slot ${slot.n}, pid ${Deno.pid}, started ${started}, owner dir ${checkout}`;
        say(line);
        await Deno.writeTextFile(`${slotDir}/owner`, `${line}\n`, { append: true }).catch(() => {});
        await stopping?.();
        slot.release();
        await Deno.remove(deadlineFile).catch(() => {});
        Deno.exit(0);
      }, Number(Deno.env.get("STACK_LAUNCH_POLL_MS") ?? 5000));
      Deno.unrefTimer(timer);
    }
    code = (await s.child.status).code;
    await sweep(slot.door);
    if (code === 0) await Deno.remove(tmp, { recursive: true }).catch(() => {});
    else if (code !== 130 && code !== 129) console.error(whyEnded(await Deno.readTextFile(`${tmp}/process-compose.log`).catch(() => ""), await Deno.readTextFile(`${tmp}/processes.log`).catch(() => "")));
  } else {
    const [cmd, ...rest] = args;
    // Not ORIGIN or APP_URL: a command that brings a stack up (integrate-local.ts) moves every port to
    // a free one, the door's too, and the stack's default origin follows its door; the slot's would name
    // a door nothing binds.
    const { ORIGIN: _o, APP_URL: _u, ...ports } = slot.env;
    const tmp = hostGate || gateSteps ? await runDir("gate.") : "";
    if (gateSteps) await gateSteps.upgrade(slot.dir, tmp);
    const script = hostGate ? integrating(await Deno.readTextFile(`${slot.dir}/.bayt/Taskfile.integrate.yaml`)) : "";
    // INTEGRATE_LOCAL_RUN marks every host-tier integrate run (integrate@host and its alias), as integrate-local.ts's
    // tag did: Studio's builder reads it to run on the model's recordings and a clone of the repo, not the live model.
    // The command runs as the root of a run this process owns: a signal ends it, and what it started, in ownRun.
    const env = hostGate
      ? { ...ports, PATH: misePath(), TMPDIR: tmp, MISE_ENV: "host", SAYT_PLATFORM: "host", INTEGRATE_LOCAL_RUN: crypto.randomUUID() }
      : { ...ports, PATH: misePath() };
    const argv = hostGate ? ["sh", "-c", 'exec mise x -- nu -c "$1"', "sh", gateSteps ? slowVisual(script) : script] : [cmd, ...rest];
    owned = true;
    code = (await ownRun(argv, { what: args.join(" "), cwd: slot.dir, env })).code;
    if (tmp) await Deno.remove(tmp, { recursive: true }).catch(() => {});
    // A pass stamps the tree as it was before the run, if it still is (gcp/local-gate-key.nu).
    if (gateSteps?.mode === "all" && code === 0) {
      const after = await gateSteps.key();
      if (!before || before !== after) say(`${before ? "the tree changed during the run" : "the tree's key cannot be read"}: the pass is not recorded`);
      else if (!await gateSteps.stamp(before)) { say("the pass could not be stamped"); code = 1; }
    }
  }
  slot.release();
  await Deno.remove(`${slot.dir.replace(/\/app$/, "")}/deadline`).catch(() => {});
  Deno.exit(code);
}
