// The machine suite's measures (machine/: the cue wrapper and vetted.ts), moved with them from
// bsoneca/pronto's tools/machine (PRONTO-484). Each runs the real script on a small CUE module.
// vetted.ts (../../machine/vetted.ts) run on a small CUE module (fixtures/cuemod; its fake-cue stands in
// for the cue binary, which the key only reads the size and time of), its store a fresh folder made and removed
// by the shell (the runner may not write). Each call of `vetted` is one run of the script.
const fixture = new URL("./fixtures/cuemod", import.meta.url).pathname;
const vetted = new URL("../../machine/vetted.ts", import.meta.url).pathname;
const sh = async (script) => new TextDecoder().decode((await new Deno.Command("sh", { args: ["-c", script], stdout: "piped" }).output()).stdout).trim();
async function vettedRun(args, env, input = "") {
  const c = new Deno.Command(Deno.execPath(), { args: ["run", "-A", "--no-config", "--no-lock", vetted, ...args], cwd: fixture, env, stdin: "piped", stdout: "piped", stderr: "null" }).spawn();
  const w = c.stdin.getWriter(); await w.write(new TextEncoder().encode(input)); await w.close();
  const o = await c.output();
  return { code: o.code, out: new TextDecoder().decode(o.stdout) };
}
// The plan of a vet before and after a `record` of a 12 s run, and the entry's file.
export async function vetRoundTrip() {
  const store = await sh("mktemp -d");
  try {
    const env = { CUE_VETTED_DIR: store };
    const fake = `${fixture}/fake-cue`;
    const first = (await vettedRun(["plan", fake, "vet", "."], env)).out.trim();
    const key = /^key (\w+)$/m.exec(first)?.[1] ?? "";
    await vettedRun(["record", fake, "vet", "."], { ...env, CUE_RUN_SECS: "12" }, `${key}\n`);
    const second = (await vettedRun(["plan", fake, "vet", "."], env)).out.trim();
    return { first, second, entry: await sh(`cat '${store}/${key}'`) };
  } finally { await sh(`rm -rf '${store}'`); }
}
// export-key (a miss), export-store of a 7 s run twice (the second prunes, after an orphan's seconds file was
// put there), export-key (a hit) and export-saved, then what the store holds.
export async function exportRoundTrip() {
  const store = await sh("mktemp -d");
  try {
    const env = { CUE_EXPORTED_DIR: store };
    const fake = `${fixture}/fake-cue`;
    const key = await vettedRun(["export-key", fake, "export", "."], env);
    const path = key.out.trim();
    await vettedRun(["export-store", fake, path, `${fixture}/out.json`, "export", "."], { ...env, CUE_RUN_SECS: "7" });
    await sh(`echo 1 > '${store}/orphan.secs'`);
    await vettedRun(["export-store", fake, path, `${fixture}/out.json`, "export", "."], { ...env, CUE_RUN_SECS: "7" });
    const hit = await vettedRun(["export-key", fake, "export", "."], env);
    const saved = await vettedRun(["export-saved", path], env);
    const files = [...Deno.readDirSync(store)].map((e) => e.name.replace(/^[0-9a-f]{64}/, "entry")).sort();
    return { keyExit: key.code, hitExit: hit.code, saved: saved.out, files };
  } finally { await sh(`rm -rf '${store}'`); }
}
// The wrapper (../../machine/cue) on a copy of the small module, its real cue a stand-in that prints how many
// times it was run (so a replay prints the first run's bytes, an evaluation new ones), every cache in a fresh HOME.
// CUE_UNKNOWN_GB=0 makes the first run's claim 0, the direct path an export under CUE_DIRECT_GB takes (PRONTO-11);
// CUE_REPLAY_MIN_S=0 lets an export that took no time be replayed, except in `small`, where it is left at 5 s.
export async function wrapperExport() {
  const tmp = await sh("mktemp -d");
  const budget = new URL("../../machine/", import.meta.url).pathname;
  try {
    await sh(`mkdir '${tmp}/w' '${tmp}/home' && cp '${budget}cue' '${budget}vetted.ts' '${tmp}/w/' && : > '${tmp}/w/slot.ts' && cp -R '${fixture}' '${tmp}/mod' && rm '${tmp}/mod/fake-cue'
printf '#!/bin/sh\nn=$(($(cat "$0.n" 2>/dev/null || echo 0) + 1)); echo $n > "$0.n"; echo "run $n"\n' > '${tmp}/real-cue' && chmod +x '${tmp}/real-cue'`);
    const env = { PATH: `${Deno.env.get("PATH")}`, HOME: `${tmp}/home`, CUE_BUDGET_REAL: `${tmp}/real-cue`, CUE_UNKNOWN_GB: "0", CUE_REPLAY_MIN_S: "0" };
    const run = async (args, more = {}) => {
      const o = await new Deno.Command(`${tmp}/w/cue`, { args, cwd: `${tmp}/mod`, env: { ...env, ...more }, clearEnv: true, stdout: "piped", stderr: "piped" }).output();
      return { code: o.code, out: new TextDecoder().decode(o.stdout), err: new TextDecoder().decode(o.stderr) };
    };
    const first = await run(["export", ".", "--out", "json"]);
    const second = await run(["export", ".", "--out", "json"]);
    const off = await run(["export", ".", "--out", "json"], { CUE_EXPORTED: "off" });
    const small = await run(["export", ".", "--out", "json"], { CUE_REPLAY_MIN_S: "5" });
    const file = await run(["export", ".", "--out", "json", "-o", `${tmp}/o.json`]);
    await sh(`printf 'package a\ny: 2\n' > '${tmp}/mod/b.cue'`);
    const changed = await run(["export", ".", "--out", "json"]);
    const replayed = (r) => r.err.includes("not evaluated again");
    return {
      first: first.out, second: second.out, secondReplayed: replayed(second), firstReplayed: replayed(first),
      off: off.out, small: small.out, file: file.out, changed: changed.out, changedReplayed: replayed(changed),
      codes: [first, second, off, small, file, changed].map((r) => r.code),
      log: (await sh(`cut -f2,3 '${tmp}/home/.cache/pronto/cue-cache.log'`)).split("\n"),
    };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// slot.ts's read of another account's release (PRONTO-762): heldByForeign over entries as readForeign reads them, the
// parsing of STACK_HOLD_UID, the trust of this account's own pool, and readForeign on real folders.
export async function foreignHold() {
  const slot = await import("../../machine/slot.ts");
  const { heldByForeign, releaseTicketOf, holdUid, dirTrust, readForeign } = slot;
  const now = Date.parse("2026-11-19T12:00:00Z"), uid = 501, hours = 12;
  const record = (more = {}) => ({ ticket: false, dirKind: "dir", dirUid: uid, dirMode: 0o755, fileKind: "file", fileUid: uid, fileMode: 0o644, pid: 4242, text: "4242 3 prio=release", written: now - 60_000, alive: true, started: now - 3600_000, what: "release brawl-chess", ...more });
  const ticket = (more = {}) => record({ ticket: true, text: "3 release=1 a release", written: now - 5_000, ...more });
  const held = (more) => heldByForeign([record(more)], uid, now, hours) !== undefined;
  const heldTicket = (more) => heldByForeign([ticket(more)], uid, now, hours) !== undefined;
  const sh = async (script) => new TextDecoder().decode((await new Deno.Command("sh", { args: ["-c", script], stdout: "piped" }).output()).stdout).trim();
  const tmp = await sh("mktemp -d");
  try {
    const own = Number(await sh("id -u"));
    // A pool on disk: a record of a live process (this one), a symlinked and a group-writable one beside it.
    const pool = `${tmp}/pool`;
    await sh(`mkdir -p '${pool}/job-${Deno.pid}' '${pool}/job-7' '${pool}/job-8' '${pool}/queue' && cd '${pool}' && chmod 755 . queue job-*
for d in job-${Deno.pid} job-7 job-8; do echo ${Deno.pid} > $d/pid; echo "x 2026-11-19 release w" > $d/owner; chmod 644 $d/pid $d/owner; done
echo "${Deno.pid} 3 prio=release" > job-${Deno.pid}/weight; chmod 644 job-${Deno.pid}/weight
echo "${Deno.pid} 3 prio=release" > '${tmp}/real-weight'
ln -s '${tmp}/real-weight' job-7/weight
echo "${Deno.pid} 3 prio=release" > job-8/weight; chmod 664 job-8/weight`);
    const withFake = async (dir) => (await readForeign(dir, own, -1)) !== undefined; // self -1: as if another account were reading
    const live = await withFake(pool);
    await sh(`rm -rf '${pool}/job-${Deno.pid}'`);
    const onlyBad = await withFake(pool); // the symlinked and the group-writable record alone hold nothing
    await sh(`echo "3 release=1 queued" > '${pool}/queue/${Date.now()}-${Deno.pid}'; chmod 644 '${pool}/queue/'*`);
    const waiting = await withFake(pool);
    await sh(`chmod 664 '${pool}/queue/'*`);
    const waitingGroupWritable = await withFake(pool);
    await sh(`chmod 644 '${pool}/queue/'*; chmod 775 '${pool}'`);
    const groupWritablePool = await withFake(pool);
    await sh(`chmod 755 '${pool}'`);
    const ownUidRefused = (await readForeign(pool, own, own)) !== undefined; // the real reader: want is its own uid
    // This account's own pool: a mode 777 one and a good one.
    await sh(`mkdir '${tmp}/open' '${tmp}/shut' && chmod 777 '${tmp}/open' && chmod 755 '${tmp}/shut'`);
    // requireOwnDir with this account's uid (from id -u: the suite runs without --allow-sys, which Deno.uid() needs).
    const tries = (p) => { try { slot.requireOwnDir(p, own); return true; } catch { return false; } };
    return {
      live, onlyBad, waiting, waitingGroupWritable, groupWritablePool, ownUidRefused,
      ownGood: tries(`${tmp}/shut`), ownOpen: tries(`${tmp}/open`),
      dead: held({ alive: false }),
      reused: held({ started: now }),
      reusedWithinSlack: held({ started: now - 60_000 + 1500 }),
      unknownStart: held({ started: 0 }),
      symlinkFile: held({ fileKind: "symlink" }),
      symlinkDir: held({ dirKind: "symlink" }),
      wrongUid: held({ fileUid: 502 }),
      wrongDirUid: held({ dirUid: 502 }),
      groupWritableFile: held({ fileMode: 0o664 }),
      otherWritableDir: held({ dirMode: 0o757 }),
      older: held({ written: now - 13 * 3600_000 }),
      weightZero: held({ text: "4242 0 prio=release" }),
      notRelease: held({ text: "4242 3" }),
      otherPid: held({ text: "4243 3 prio=release" }),
      badPid: held({ pid: NaN, text: "NaN 3 prio=release" }),
      none: heldByForeign([], uid, now, hours) !== undefined,
      ticketLive: heldTicket({}),
      ticketDead: heldTicket({ alive: false }),
      ticketReused: heldTicket({ started: now }),
      ticketOld: heldTicket({ written: now - 13 * 3600_000 }),
      ticketPlain: heldTicket({ text: "3 a gate" }),
      ticketWeightZero: heldTicket({ text: "0 release=1 w" }),
      ticketFields: releaseTicketOf("2 nested=1 mem=3 cores=2 release=1 x"),
      ticketAfterWhat: releaseTicketOf("2 mem=3 cores=2 do release=1"),
      ticketPrio: releaseTicketOf("2 nested=1 mem=3 cores=2 prio=release x"),
      ticketPrioNormal: releaseTicketOf("2 mem=3 cores=2 prio=normal release=1 x"),
      ticketPrioWeight0: releaseTicketOf("0 prio=release x"),
      heldPrioTicket: heldTicket({ text: "3 prio=release a release" }),
      uidUnset: holdUid(undefined, 1000) ?? -1, uidEmpty: holdUid("", 1000) ?? -1, uidSigned: holdUid("-1", 1000) ?? -1, uidText: holdUid("5x", 1000) ?? -1,
      uidOwn: holdUid("1000", 1000) ?? -1, uidOther: holdUid("501", 1000) ?? -1, uidZero: holdUid("0", 1000) ?? -1,
      trustSymlink: dirTrust({ isDirectory: true, isSymlink: true, uid: 1000, mode: 0o755 }, 1000),
      trustOther: dirTrust({ isDirectory: true, isSymlink: false, uid: 501, mode: 0o755 }, 1000),
      trust777: dirTrust({ isDirectory: true, isSymlink: false, uid: 1000, mode: 0o777 }, 1000),
      trust775: dirTrust({ isDirectory: true, isSymlink: false, uid: 1000, mode: 0o775 }, 1000),
      trustGood: dirTrust({ isDirectory: true, isSymlink: false, uid: 1000, mode: 0o755 }, 1000),
      claimWeight0: slot.admitsCores(false, 0, 0, 0, 15, false, false, true),
      claimWeight3: slot.admitsCores(false, 0, 3, 0, 15, false, false, true),
      besideUnder: slot.besideRelease(1, 0, 7, 18),
      besideOver: slot.besideRelease(1, 0, 18, 18),
      besideWaiting: slot.besideRelease(1, 1, 7, 18),
      besideUnknown: slot.besideRelease(1, 0, null, 18),
      besideNoRelease: slot.besideRelease(0, 0, 7, 18),
      admitUnder: slot.admitsCores(false, 8, 3, 0, 15, false, false, true, slot.besideRelease(1, 0, 7, 18)),
      holdOver: slot.admitsCores(false, 8, 3, 0, 15, false, false, true, slot.besideRelease(1, 0, 20, 18)),
      besideFull: slot.admitsCores(false, 13, 3, 0, 15, false, false, true, true),
      besideRunnerFull: slot.admitsCores(false, 13, 3, 0, 15, true, false, true, true),
      besideAhead: slot.admitsCores(false, 8, 3, 6, 15, false, false, true, true),
      besideForeign: slot.besideRelease(1, 0, 7, 18, true),
      heldBeside: slot.heldByRelease(true, 10, false),
      heldRelease: slot.heldByRelease(true, 6, true),
      heldWeight0: slot.heldByRelease(true, 0, false),
      loadRead: slot.load1(() => [7, 5, 4]),
      olderBesideKeeps: slot.olderKeeps({ weighted: true, weight: 3, release: false }, 8, 0, 15, true, true),
      olderHeldSkipped: slot.olderKeeps({ weighted: true, weight: 3, release: false }, 8, 0, 15, true, false),
      olderBesideFull: slot.olderKeeps({ weighted: true, weight: 9, release: false }, 8, 0, 15, true, true),
      olderReleaseKept: slot.olderKeeps({ weighted: true, weight: 3, release: true }, 8, 0, 15, true, false),
      poolWeight0Low: slot.poolBesideOf(0, false, true, true, false, 1, 0, false, () => 7, 18),
      poolWeight0Foreign: slot.poolBesideOf(0, false, true, true, false, 1, 0, true, () => 7, 18),
      poolWeight0NoOlder: slot.poolBesideOf(0, false, true, false, false, 1, 0, false, () => { throw new Error("read"); }, 18),
      poolRelease: slot.poolBesideOf(0, true, true, true, false, 1, 0, false, () => { throw new Error("read"); }, 18),
      poolWeighted: slot.poolBesideOf(3, false, true, true, true, 1, 0, false, () => { throw new Error("read"); }, 18),
      poolReadFails: slot.poolBesideOf(0, false, true, true, false, 1, 0, false, () => { throw new Error("denied"); }, 18),
      loadFails: (() => { try { slot.load1(() => { throw new Error("Requires sys access"); }); return "read"; } catch (e) { return `${e.message} | cause: ${e.cause?.message}`; } })(),
      loadEmpty: (() => { try { slot.load1(() => []); return "read"; } catch (e) { return e.message; } })(),
    };
  } finally { await sh(`rm -rf '${tmp}'`); }
}

// The run owner (harness/files/tests/slot.ts, PRONTO-684): who a run's members are, as data (no processes), and the
// owner on real ones. A table is the machine's processes as one read of them gave; a pid in a case is only ever one a
// marker file or an exact owner pid named, and every case stops all it started on every path.
const slotUrl = new URL("../../harness/files/tests/slot.ts", import.meta.url).pathname;
export async function ownPure() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const { planReap, reapDead, nestedIn, stopMembers, recordOf } = slot;
  const row = (pid, more = {}) => ({ pid, uid: 501, start: 1000, ppid: 1, responsible: 1, zombie: false, ...more });
  const table = (rows, more = {}) => ({ os: "darwin", uid: 501, rows, ...more });
  const rec = { rootpid: 100, rootstart: 1000, superpid: 50, superstart: 900, uid: 501, what: "t", state: "running" };
  const pids = (p) => p.members.map((m) => m.pid);
  const root = row(100, { responsible: 100 });
  // The root's pid reused: Q holds it now, started at 5000. What is attributed to 100 and began after Q is Q's.
  const reused = table([row(100, { start: 5000, responsible: 100 }), row(102, { start: 1100, responsible: 100 }), row(103, { start: 5100, responsible: 100 })]);
  const q = table([row(100, { start: 5000, responsible: 100 }), row(103, { start: 5100, responsible: 100 }), row(104, { start: 5200, responsible: 100 })]);
  const errs = planReap(table([root, { pid: 104, errno: 22, uid: 501 }, { pid: 105, errno: 22 }, { pid: 106, errno: 3 }, { pid: 107, errno: 1 }, { pid: 108, errno: 22, uid: 0 }, row(109, { responsible: 100, start: 1100 })]), rec, 2000);
  const failedOnly = (rows) => planReap(table([root, ...rows]), rec, 2000).failed.length;
  const live = row(50, { start: 900 });
  const dead = { ...rec, rootpid: 200, rootstart: 1000, superpid: 60, superstart: 900 };
  const reusedSuper = { ...rec, rootpid: 300, rootstart: 1000, superpid: 70, superstart: 900 };
  const dr = reapDead([rec, dead, reusedSuper], table([live, root, row(201, { responsible: 200, start: 1100 }), row(70, { start: 7000 }), row(301, { responsible: 300, start: 1100 })]), 2000);
  const linux = (rows) => ({ os: "linux", uid: 501, rows });
  // The supervisor's own children (115: a `ps`; 116: its environ unreadable) are not the run's; a marked orphan (114) is, and its child.
  const lin = planReap(linux([row(50, { start: 900, ppid: 1 }), row(100, { ppid: 50 }), row(110, { ppid: 100 }), row(111, { ppid: 110 }), row(112, { ppid: 1 }), row(113, { ppid: 50, uid: 0 }),
    row(114, { ppid: 50, marker: "50-900" }), row(115, { ppid: 50 }), row(116, { ppid: 50, unreadable: true }), row(117, { ppid: 114 }), row(118, { ppid: 50, marker: "50-901" }), row(119, { ppid: 1, marker: "50-900" })]), rec, 2000);
  const outer = { ...rec, rootpid: 300, rootstart: 1000, superpid: 70, superstart: 900 };
  const mine = (rows, self = 400) => nestedIn(table(rows), self, [outer]);
  const nestedThrows = (() => { try { nestedIn(table([], { listError: "x" }), 400, []); return false; } catch { return true; } })();
  // stopMembers on a machine that changes under it: the member read at start 1100 is another process (1200) by the time it is signalled.
  const sent = [];
  let reads = 0;
  const sys = {
    os: "darwin", uid: 501,
    table: () => table(reads++ === 0 ? [root, row(101, { responsible: 100, start: 1100 })] : [root]),
    signal: (pid, start, sig) => { if (start !== 1200) return "changed"; sent.push(`${pid}:${sig}`); return "sent"; },
    command: () => "x",
  };
  const stopped = await stopMembers(sys, rec, 300, 10);
  // And a survivor: still there after KILL, it is named and fails.
  const stubborn = { ...sys, table: () => table([root, row(101, { responsible: 100, start: 1100 })]), signal: () => "sent", command: () => "stubborn" };
  const left = await stopMembers(stubborn, rec, 50, 10);
  // And a signal that cannot be sent fails, closed.
  const denied = await stopMembers({ ...stubborn, signal: () => "Operation not permitted" }, rec, 20, 10);
  return {
    basic: pids(planReap(table([root, row(101, { responsible: 100, start: 1100 }), row(102, { responsible: 7, start: 1100 }), row(103, { responsible: 100, start: 1100, uid: 0 })]), rec, 2000)),
    beforeRoot: pids(planReap(table([root, row(101, { responsible: 100, start: 999 })]), rec, 2000)),
    zombie: pids(planReap(table([root, row(101, { responsible: 100, start: 1100, zombie: true })]), rec, 2000)),
    reusedOurs: pids(planReap(reused, rec, 2000)),
    reusedNamedSkipped: planReap(reused, rec, 2000).skipped.map((s) => `${s.pid}`),
    reusedHoldersOwn: pids(planReap(q, rec, 2000)),
    reusedHoldersOwnDead: pids(reapDead([rec], q, 2000)[0].plan),
    errMembers: pids(errs),
    errFailed: errs.failed,
    errSkipped: errs.skipped.map((s) => `${s.pid}:${s.why}`),
    esrchFails: failedOnly([{ pid: 106, errno: 3 }]),
    eperm: failedOnly([{ pid: 107, errno: 1 }]),
    otherUidRead: failedOnly([{ pid: 108, errno: 13, uid: 0 }]),
    ownUidRead: failedOnly([{ pid: 104, errno: 13, uid: 501 }]),
    listError: planReap(table([], { listError: "proc_listallpids returned -1 (errno 1)" }), rec, 2000).failed,
    age: planReap(table([root, row(101, { responsible: 100, start: 1_000_000 })]), { ...rec, rootstart: 1000 }, 3000)[ "members" ][0].age,
    deadRuns: dr.map((d) => `${d.run.rootpid}:${pids(d.plan)}`),
    deadListError: reapDead([rec], table([], { listError: "x" }), 2000).map((d) => d.plan.failed.length),
    linuxMembers: pids(lin),
    // The supervisor (50) is gone: what carries its marker, now init's, is its run's to reap.
    linuxDead: reapDead([rec], linux([row(100, { ppid: 1 }), row(119, { ppid: 1, marker: "50-900" }), row(120, { ppid: 1 })]), 2000).map((d) => pids(d.plan)),
    // The root pid is reused (start 5000, not the record's): its child is not the run's; an orphan under another subreaper (7) is.
    linuxDeadReused: reapDead([rec], linux([row(100, { ppid: 1, start: 5000 }), row(121, { ppid: 100 }), row(122, { ppid: 7, marker: "50-900" })]), 2000).map((d) => pids(d.plan)),
    linuxUnreadable: lin.skipped.filter((s) => /environ/.test(s.why)).map((s) => s.pid),
    nestedByResponsible: mine([row(70, { start: 900 }), row(300, { start: 1000, responsible: 300 }), row(400, { responsible: 300, ppid: 1 })])?.rootpid ?? 0,
    nestedRootReused: mine([row(70, { start: 900 }), row(300, { start: 4000, responsible: 300 }), row(400, { responsible: 300, ppid: 1 })])?.rootpid ?? 0,
    nestedSupervisorGone: mine([row(300, { start: 1000, responsible: 300 }), row(400, { responsible: 300, ppid: 1 })])?.rootpid ?? 0,
    nestedByAncestry: mine([row(70, { start: 900 }), row(80, { ppid: 70, responsible: 5 }), row(400, { ppid: 80, responsible: 5 })])?.rootpid ?? 0,
    nestedSupervisorReused: mine([row(70, { start: 901 }), row(400, { ppid: 70, responsible: 5 })])?.rootpid ?? 0,
    notNested: mine([row(400, { ppid: 1, responsible: 5 })])?.rootpid ?? 0,
    nestedThrows,
    movedSent: sent, movedSurvivors: stopped.survivors, movedFailed: stopped.failed,
    stubbornSurvivors: left.survivors.length, stubbornNamed: left.survivors[0].replace(/age [0-9hm]+/, "age N"), stubbornListed: left.listed.length,
    deniedFailed: denied.failed.length > 0,
    // Two records share a root pid (a done one of an older run, and this run's): the keeper's supervisor picks its own.
    recordOfOwn: recordOf([{ ...rec, superpid: 40, superstart: 800, state: "done" }, rec], 100, 50, 900)?.superpid ?? 0,
    recordOfOld: recordOf([{ ...rec, superpid: 40, superstart: 800, state: "done" }, rec], 100, 40, 800)?.state ?? "",
    recordOfNone: recordOf([{ ...rec, superpid: 40, superstart: 800, state: "done" }], 100, 50, 900)?.superpid ?? 0,
  };
}

// The owner on real processes (macOS and Linux). `own` is slot.ts's verb, run as a process of its own so a signal can
// be sent to it. A sleeper (/bin/sleep, an Apple binary) is detached by a short-lived parent with a double fork and
// setsid and writes its pid to a marker; the root then ends (the run passes) or waits for a signal.
const decode = (b) => new TextDecoder().decode(b);
// Gone: no process, or a zombie (a signalled process whose parent has not reaped it yet).
const gone = async (pid) => { const st = await sh(`ps -o stat= -p ${pid} 2>/dev/null`); return st === "" || st.startsWith("Z"); };
const until = async (what, ms = 15000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await what()) return true; await new Promise((r) => setTimeout(r, 50)); } return false; };
const rootPids = (f) => { try { const [k, , c] = Deno.readTextFileSync(f).trim().split(" ").map(Number); return [k, c].filter((n) => n > 0); } catch { return []; } };
const readPid = (f) => { try { const n = Number(Deno.readTextFileSync(f).trim().split(" ")[0]); return n > 0 ? n : 0; } catch { return 0; } };
// The root's script: detach a sleeper (marker $M), then wait for the sleeper's pid to be written; `pass` ends, else it waits.
const rootScript = (pass) => `perl -MPOSIX -e 'fork and exit; POSIX::setsid(); $SIG{TERM}="IGNORE" if $ENV{IGN}; open F, ">$ENV{M}.tmp"; print F $$; close F; rename "$ENV{M}.tmp", $ENV{M}; exec "/bin/sleep", "300"'
i=0; while [ ! -s "$M" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
${pass ? "exit 0" : "exec /bin/sleep 300"}`;
export async function ownProbe({ mode = "orphan", signal = "", foreign = false, ignore = false, nested = false } = {}) {
  const tmp = await sh("mktemp -d");
  const owners = [], sleepers = [];
  const out = { launched: false, code: -1, sleepGone: false, named: false, nonzero: false, foreignKept: true, foreignGone: true, innerNamed: false, recordGone: false };
  const spawnOwner = (tag, script, more = {}) => {
    const m = `${tmp}/${tag}.sleeper`;
    const c = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", "--no-config", "--no-lock", slotUrl, "own", "--what", tag, "--grace", "10", "--root-out", `${tmp}/${tag}.root`, "--", "sh", "-c", script],
      env: { STACK_POOL: `${tmp}/pool`, M: m, ...more }, stdout: "piped", stderr: "piped",
    }).spawn();
    owners.push(c.pid);
    return { c, m };
  };
  try {
    let other;
    if (foreign) other = spawnOwner("other", rootScript(false));
    const inner = nested ? `deno_run=${JSON.stringify(Deno.execPath())}; "$deno_run" run -A --no-config --no-lock '${slotUrl}' own --what inner -- sh -c "$INNER"; ` : "";
    const script = nested ? `${inner}exit 0` : rootScript(mode === "orphan" && !signal);
    const mine = spawnOwner("t", script, { ...(ignore ? { IGN: "1" } : {}), ...(nested ? { INNER: rootScript(true) } : {}) });
    const started = await until(() => readPid(mine.m) > 0 && (!foreign || readPid(other.m) > 0));
    const sleeper = readPid(mine.m);
    if (sleeper) sleepers.push(sleeper);
    if (foreign && readPid(other.m)) sleepers.push(readPid(other.m));
    out.launched = started;
    if (signal) Deno.kill(mine.c.pid, signal);
    const o = await mine.c.output();
    out.code = o.code;
    out.nonzero = o.code !== 0;
    const err = decode(o.stderr);
    out.named = /left running by "t"/.test(err);
    out.innerNamed = /left running by "inner"/.test(err);
    out.sleepGone = sleeper > 0 && await until(() => gone(sleeper), 3000);
    out.recordGone = (await sh(`ls '${tmp}/pool/runs' 2>/dev/null | wc -l`)) === "0" || foreign;
    if (foreign) {
      const fp = readPid(other.m);
      out.foreignKept = fp > 0 && !(await gone(fp));
      // Now the other run is ended, by its owner's exact pid, and its sleeper goes with it.
      Deno.kill(other.c.pid, "SIGTERM");
      await other.c.output();
      out.foreignGone = fp > 0 && await until(() => gone(fp), 3000);
    }
  } finally {
    // Every path: each owner we started still running is stopped, then every sleeper a marker named, by exact pid.
    for (const pid of owners) { if (!(await gone(pid))) { try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } } }
    // The keepers and the commands the owners wrote to --root-out ("<keeper> <start> <command>"), by those exact pids.
    for (const tag of ["t", "other"]) for (const pid of rootPids(`${tmp}/${tag}.root`)) { if (!(await gone(pid))) { try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } } }
    for (const pid of sleepers) { if (!(await gone(pid)) && /sleep/.test(await sh(`ps -o command= -p ${pid}`))) { try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } } }
    await sh(`rm -rf '${tmp}'`);
  }
  return out;
}
// The responsibility calls exist and are inherited across setsid: a root started by the owner's spawn, a sleeper
// detached by a double fork and setsid, and the table says the sleeper is the root's (macOS: its responsible pid; Linux: a descendant).
export async function ownSpi() {
  const tmp = await sh("mktemp -d");
  try {
    const fixture = new URL("./fixtures/own_spi.ts", import.meta.url).pathname;
    // In a process of its own: the machine calls need --allow-ffi, which a unit run does not give.
    const o = await new Deno.Command(Deno.execPath(), { args: ["run", "-A", "--no-config", "--no-lock", fixture, tmp], env: { STACK_POOL: `${tmp}/pool` }, stdout: "piped", stderr: "piped" }).output();
    try { return JSON.parse(decode(o.stdout).trim().split("\n").pop()); } catch { throw new Error(`the own_spi fixture printed no JSON (exit ${o.code}): ${decode(o.stderr).slice(-600)}`); }
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// The owner's own end cases. A keeper killed: the command it ran is still stopped (the owner signals it directly) and the
// run fails. A supervisor killed: the keeper notices within a second or two and ends the run itself (command, members, record).
async function ownFailure(kill) {
  const tmp = await sh("mktemp -d");
  const pids = [];
  const out = { launched: false, nonzero: false, cmdGone: false, sleepGone: true, keeperGone: false, recordGone: false };
  try {
    const m = `${tmp}/sleeper`;
    const script = kill === "keeper" ? "exec /bin/sleep 300" : rootScript(false);
    const c = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", "--no-config", "--no-lock", slotUrl, "own", "--what", "t", "--grace", "10", "--root-out", `${tmp}/t.root`, "--", "sh", "-c", script],
      env: { STACK_POOL: `${tmp}/pool`, M: m }, stdout: "piped", stderr: "piped",
    }).spawn();
    pids.push(c.pid);
    out.launched = await until(() => rootPids(`${tmp}/t.root`).length === 2 && (kill === "keeper" || readPid(m) > 0));
    const [keeper, cmd] = rootPids(`${tmp}/t.root`);
    const sleeper = readPid(m);
    pids.push(keeper, cmd, sleeper);
    Deno.kill(kill === "keeper" ? keeper : c.pid, "SIGKILL");
    if (kill === "supervisor") {
      out.cmdGone = await until(() => gone(cmd), 25000);
      out.sleepGone = await until(() => gone(sleeper), 5000);
      out.keeperGone = await until(() => gone(keeper), 5000);
    }
    // Whatever is left is stopped by exact pid, so the owner's pipes close and its output can be read.
    if (kill === "keeper") {
      const o = await c.output();
      out.nonzero = o.code !== 0;
      out.cmdGone = await until(() => gone(cmd), 3000);
      out.keeperGone = await gone(keeper);
    }
    out.recordGone = await until(async () => (await sh(`ls '${tmp}/pool/runs' 2>/dev/null | wc -l`)) === "0", 5000);
    if (kill === "supervisor") { for (const pid of pids) if (!(await gone(pid))) { try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } } await c.output(); }
  } finally {
    for (const pid of pids) { if (pid > 0 && !(await gone(pid))) { try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } } }
    await sh(`rm -rf '${tmp}'`);
  }
  return out;
}
export const ownKeeperKilled = () => ownFailure("keeper");
export const ownSupervisorKilled = () => ownFailure("supervisor");
// A child killed by SIGKILL reads as signal 9 (the memory watchdog's pressure retry tests for it), through a nested claim too.
export async function ownSignals() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const st = await new Deno.Command("sh", { args: ["-c", "kill -9 $$"], stdout: "null", stderr: "null" }).output();
  return { killed: slot.sigNumber(st.signal), term: slot.sigNumber("SIGTERM"), none: slot.sigNumber(null), hup: slot.sigNumber("SIGHUP") };
}
