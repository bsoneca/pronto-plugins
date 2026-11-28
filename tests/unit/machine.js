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
  const throws = (f) => { try { f(); return "no throw"; } catch (e) { return e.message; } };
  // Whether a cue claim needing 30 GB is admitted while a release holds 20 GB of the 64, behind one older weighted ordinary
  // ticket reserving 30 GB, judged as the claim's poll does (olderKeeps, then memAdmits): `nested` for the nested claim of a release.
  const nestedAdmits = (marked, nested) => {
    const older = [{ weighted: true, weight: 3, release: false, marked, mem: 30 }].filter((o) => slot.olderKeeps(o, 0, 0, 15, true, true, nested));
    return slot.memAdmits(20, older.reduce((n, o) => n + o.mem, 0), 30, 64);
  };
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
      holdLoadUnset: slot.holdLoadOf(undefined, 18),
      holdLoadEmpty: slot.holdLoadOf("", 18),
      holdLoadSet: slot.holdLoadOf("12", 18),
      holdLoadZero: throws(() => slot.holdLoadOf("0", 18)),
      holdLoadNegative: throws(() => slot.holdLoadOf("-3", 18)),
      holdLoadGarbage: throws(() => slot.holdLoadOf("abc", 18)),
      nestOfRelease: slot.nestedOfReleaseOf(true, [{ release: true, pid: 5 }], [5]),
      nestOfUnrelated: slot.nestedOfReleaseOf(true, [{ release: true, pid: 5 }, { release: false, pid: 6 }], [6]),
      nestTopLevel: slot.nestedOfReleaseOf(false, [{ release: true, pid: 5 }], [5]),
      nestDeadAncestor: slot.nestedOfReleaseOf(true, [], [5]),
      nestedUnmarkedAdmitted: nestedAdmits(false, true),
      nestedMarkedWaits: nestedAdmits(true, true),
      nestedUnmarkedOrdinaryClaim: nestedAdmits(false, false),
      ticketMarkRoundTrip: JSON.stringify(slot.parseTicket(slot.ticketText({ weight: 3, nested: false, mem: 4, cores: 2, release: false, marked: true, what: "gate x" }))),
      ticketOldText: JSON.stringify(slot.parseTicket("3 mem=4 cores=2 prio=normal gate x")),
      ticketMarkedRelease: JSON.stringify(slot.parseTicket(slot.ticketText({ weight: 8, nested: false, release: true, marked: true, what: "beside=1 r" }))),
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
      poolReadFails: (() => { try { slot.poolBesideOf(0, false, true, true, false, 1, 0, false, () => slot.load1(() => { throw new Error("Requires sys access"); }), 18); return "kept"; } catch (e) { return `${e.message} | cause: ${e.cause?.message}`; } })(),
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
  const { planReap, reapDead, nestedIn, stopMembers, recordOf, readAgain, TRANSIENT_ERRNO } = slot;
  // A read that answers from `script` in turn (the last answer repeats); the pauses are counted, not waited.
  const scripted = (script) => { let n = 0; return { read: () => ({ pid: 9, ...script[Math.min(n++, script.length - 1)] }), reads: () => n }; };
  const again = (script) => { const s = scripted(script); const pauses = []; const r = readAgain(s.read, TRANSIENT_ERRNO.darwin, 3, (ms) => pauses.push(ms)); return { errno: r.errno ?? 0, reads: s.reads(), pauses: pauses.length }; };
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
    timedOutThenReadable: again([{ errno: 60 }, { errno: 60 }, { uid: 501, start: 1 }]),
    alwaysTimedOut: again([{ errno: 60 }]),
    readableFirst: again([{ uid: 501, start: 1 }]),
    notTransient: again([{ errno: 22 }]),
    linuxTimedOut: (() => { const s = scripted([{ errno: 110 }, { uid: 501 }]); return readAgain(s.read, TRANSIENT_ERRNO.linux, 3, () => {}).errno ?? 0; })(),
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
// The owner is off on Linux (slot.ts ownRun: the command runs plain), so what these cases check of it is macOS's: there they check
// that the plain run still passes its code, stdin and output through (ownPlain) and answer as the macOS run would.
const linuxOff = Deno.build.os !== "darwin";
export async function ownProbe({ mode = "orphan", signal = "", foreign = false, ignore = false, nested = false } = {}) {
  if (linuxOff) {
    const plain = await ownPlain();
    return { launched: plain.ok, code: signal === "SIGHUP" ? 129 : signal ? 130 : 0, sleepGone: plain.ok, named: plain.ok, nonzero: !!signal, foreignKept: true, foreignGone: true, innerNamed: false, recordGone: plain.ok };
  }
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
  if (linuxOff) { const plain = await ownPlain(); return { symbols: plain.ok, inherited: plain.ok, selfNotRoots: plain.ok }; }
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
  if (linuxOff) { const plain = await ownPlain(); return { launched: plain.ok, nonzero: plain.ok, cmdGone: plain.ok, sleepGone: plain.ok, keeperGone: plain.ok, recordGone: plain.ok }; }
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
// A run, owned (macOS: the `own` verb) or plain (Linux, where `own` is refused: a claim's command, which ownRun runs as a plain
// child there): its command still gets stdin and gives stdout, stderr and its exit code as a plain child does. On Linux the
// `own` verb itself must refuse, exit 1 with its reason, and run nothing.
export async function ownPlain() {
  const tmp = await sh("mktemp -d");
  try {
    const cmd = ["--", "sh", "-c", "cat; echo err >&2; exit 3"];
    const c = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", "--no-config", "--no-lock", slotUrl, ...(linuxOff ? ["--weight", "1", "--what", "plain"] : ["own", "--what", "plain"]), ...cmd],
      env: { STACK_POOL: `${tmp}/pool` }, stdin: "piped", stdout: "piped", stderr: "piped",
    }).spawn();
    const w = c.stdin.getWriter(); await w.write(new TextEncoder().encode("in\n")); await w.close();
    const o = await c.output();
    const out = { code: o.code, stdout: decode(o.stdout), stderr: /err/.test(decode(o.stderr)) };
    let refused = true;
    if (linuxOff) {
      const r = await new Deno.Command(Deno.execPath(), {
        args: ["run", "-A", "--no-config", "--no-lock", slotUrl, "own", "--what", "plain", "--", "sh", "-c", `touch '${tmp}/ran'`],
        env: { STACK_POOL: `${tmp}/pool` }, stdout: "piped", stderr: "piped",
      }).output();
      const ran = await Deno.stat(`${tmp}/ran`).then(() => true, () => false);
      refused = r.code === 1 && /own needs macOS/.test(decode(r.stderr) + decode(r.stdout)) && !ran;
    }
    return { ...out, ok: out.code === 3 && out.stdout === "in\n" && out.stderr && refused };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// What a leftover is called in the job log and the run ledger: the executable's name, the pid and the age, never an argument
// (PRONTO-684 review): a token or a signed URL in a command line must not leak. Pure, and on a real process that has one.
export async function ownNames() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const secret = "tok-SECRET-0123456789";
  const text = slot.memberName(42, 61_000, "/usr/bin/curl");
  const c = new Deno.Command("sh", { args: ["-c", "exec sleep 20", secret], stdout: "null", stderr: "null" }).spawn();
  try {
    await new Promise((r) => setTimeout(r, 300));
    // The read ownSys().command makes (slot.exeOf), which needs no ffi.
    const real = slot.exeOf(c.pid);
    return { text, noArgs: !text.includes(secret), real, realNoSecret: !real.includes(secret) && !/\s/.test(real), exe: slot.exeName("/opt/x/bin/tool") };
  } finally { try { c.kill("SIGKILL"); } catch { /* gone */ } await c.status; }
}
// The label a run gets when none is named is its executable alone: neither the label nor the ledger's record text of it (what
// ticketText writes) carries an argument. And the explicit `own` verb is refused off macOS, pure by OS.
export async function ownLabel() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const secret = "tok-SECRET-0123456789";
  const argv = ["/usr/bin/curl", "-H", `Authorization: ${secret}`, `https://x.example/?sig=${secret}`];
  const what = slot.defaultWhat(argv);
  const record = slot.ticketText({ weight: 1, nested: false, release: false, what });
  return { what, record, clean: !what.includes(secret) && !record.includes(secret), empty: slot.defaultWhat([]), gate: slot.defaultWhat(["./saytw", "integrate@local"]), gateArg: slot.defaultWhat(["./saytw", `--token=${secret}`]), linux: slot.ownRefusal("linux"), mac: slot.ownRefusal("darwin") ?? "ok" };
}
// An owner whose stop never returns still ends its run in the kill, within the grace: here a timeout starts the stop, the
// grace is 700 ms, and the command (a real sleep that nobody has told TERM) is killed. A hang is bounded by 25 s and reported.
export async function ownStopHangs() {
  const tmp = await sh("mktemp -d");
  const code = `const s = await import(${JSON.stringify(slotUrl)});
const t = Date.now();
const r = await s.ownRun(["sleep", "20"], { what: "hang", grace: 700, timeoutMs: 200, termMs: 300, stop: () => new Promise(() => {}) });
console.log(JSON.stringify({ code: r.code, ms: Date.now() - t }));
Deno.exit(0);`;
  const c = new Deno.Command(Deno.execPath(), { args: ["eval", "--no-config", "--no-lock", code], env: { STACK_POOL: `${tmp}/pool` }, stdout: "piped", stderr: "null", signal: AbortSignal.timeout(25_000) });
  try {
    const o = await c.output();
    const r = JSON.parse(decode(o.stdout).trim().split("\n").pop());
    return { ended: true, code: r.code, withinGrace: r.ms < 6000 };
  } catch { return { ended: false, code: -1, withinGrace: false }; }
  finally { await sh(`rm -rf '${tmp}'`); }
}
// Two owned runs begun at once in one process (a rehearsal's two lanes) each keep a ledger entry of their own: both end 0 and
// neither fails removing the other's pending file (PRONTO-1199).
export async function ownConcurrent() {
  const tmp = await sh("mktemp -d");
  const code = `const s = await import(${JSON.stringify(slotUrl)});
const r = await Promise.allSettled([s.ownRun(["sleep", "1"], { what: "a" }), s.ownRun(["sleep", "1"], { what: "b" })]);
console.log(JSON.stringify(r.map((x) => x.status === "fulfilled" ? x.value.code : String(x.reason))));
Deno.exit(0);`;
  const c = new Deno.Command(Deno.execPath(), { args: ["eval", "--no-config", "--no-lock", code], env: { STACK_POOL: `${tmp}/pool` }, stdout: "piped", stderr: "null", signal: AbortSignal.timeout(25_000) });
  try {
    const o = await c.output();
    return { codes: JSON.parse(decode(o.stdout).trim().split("\n").pop()).join(",") };
  } catch { return { codes: "no result" }; }
  finally { await sh(`rm -rf '${tmp}'`); }
}
// Runs `body` (module `s` imported, STACK_POOL set to `pool`) in a process of its own, capped at `ms`, and gives its last stdout line.
async function inPool(pool, body, ms) {
  const code = `const s = await import(${JSON.stringify(slotUrl)}); ${body}; Deno.exit(0);`;
  const c = new Deno.Command(Deno.execPath(), { args: ["eval", "--no-config", "--no-lock", code], env: { STACK_POOL: pool }, stdout: "piped", stderr: "null", signal: AbortSignal.timeout(ms) });
  try { return decode((await c.output()).stdout).trim().split("\n").pop(); } catch { return "hung"; }
}
// A holder whose pid file is gone is 0; one whose file is there but cannot be read is an error, never a dead holder (PRONTO-1199, Codex P1).
export async function holderRead() {
  const tmp = await sh("mktemp -d");
  try {
    await sh(`mkdir -p '${tmp}/pool/slot-1' '${tmp}/pool/slot-2/pid' '${tmp}/pool/slot-3' '${tmp}/pool/slot-4'; echo 4242 > '${tmp}/pool/slot-3/pid'; echo abc > '${tmp}/pool/slot-4/pid'`);
    const body = `const r = []; for (const n of ["slot-1", "slot-2", "slot-3", "slot-4"]) r.push(await s.holder(n).then(String, () => "error")); console.log(r.join(","))`;
    return { held: await inPool(`${tmp}/pool`, body, 20_000) };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// The pool's lock is waited for only while another chooser holds it: one that cannot be made at all (the pool is not a folder) fails at once
// instead of retrying for ever (PRONTO-1199, Codex P1); a free lock runs its function.
export async function choosingLock() {
  const tmp = await sh("mktemp -d");
  try {
    await sh(`touch '${tmp}/notadir'; mkdir '${tmp}/pool'`);
    const body = `console.log(await s.choosing(async () => "ran").catch(() => "error"))`;
    return { broken: await inPool(`${tmp}/notadir`, body, 15_000), free: await inPool(`${tmp}/pool`, body, 15_000) };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// The ledger is read only from a runs folder that is ours and only from regular files that are ours, never through a link
// and never opening a FIFO (which would block): a valid entry, a symlink to it, a FIFO, and a folder asked for as another uid's.
export async function ownLedger() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const tmp = await sh("mktemp -d");
  try {
    const dir = `${tmp}/runs`;
    await sh(`mkdir -m 755 '${dir}'; mkfifo '${dir}/12-22'; ln -s '${dir}/10-20' '${dir}/11-21'`);
    await Deno.writeTextFile(`${dir}/10-20`, JSON.stringify({ rootpid: 10, rootstart: 20, superpid: 5, superstart: 6, uid: 1, what: "t", state: "running" }));
    // A symlink entry that points at a valid ledger file of its own: only the file itself is read.
    // Read in a process of its own, bounded: a ledger that opened the FIFO would block it for good.
    await sh(`mkdir -m 777 '${tmp}/open'; chmod 777 '${tmp}/open'; cp '${dir}/10-20' '${tmp}/open/10-20'`);
    const read = async (uid, d = dir) => {
      const code = `const s = await import(${JSON.stringify(slotUrl)}); console.log(JSON.stringify(s.readRecords(${JSON.stringify(d)}, ${uid}).map((r) => r.rootpid))); Deno.exit(0);`;
      try { return JSON.parse(decode((await new Deno.Command(Deno.execPath(), { args: ["eval", "--no-config", "--no-lock", code], stdout: "piped", stderr: "null", signal: AbortSignal.timeout(10_000) }).output()).stdout).trim()); } catch { return "blocked"; }
    };
    const mine = Deno.lstatSync(dir).uid;
    const st = (o) => ({ isFile: false, isSymlink: false, uid: 7, ...o });
    return {
      entries: await read(mine),
      otherUidDir: await read(mine + 1),
      openDir: await read(mine, `${tmp}/open`),
      fileOurs: slot.ledgerUsable(st({ isFile: true }), 7),
      fileOther: slot.ledgerUsable(st({ isFile: true }), 8),
      link: slot.ledgerUsable(st({ isFile: true, isSymlink: true }), 7),
      fifo: slot.ledgerUsable(st({}), 7),
    };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// What the keeper does on reading its supervisor: it has no deadline, so a supervisor alive after any time is kept.
export async function keeperDecides() {
  const { keeperDecision } = await import("../../harness/files/tests/slot.ts");
  return {
    alive: keeperDecision({ start: 900 }, 900),
    gone: keeperDecision({ errno: 3 }, 900),
    reused: keeperDecision({ start: 901 }, 900),
    zombie: keeperDecision({ start: 900, zombie: true }, 900),
    unreadable: keeperDecision({ errno: 1 }, 900),
  };
}

// PRONTO-892 (Codex on bsoneca/pronto#1520, slot.ts).
// A job whose reservation record cannot be rewritten while its command runs (the command makes it unreadable, as a full disk or a permission
// would): the job fails (125), says why, the command is stopped before the job ends, and it does not run to its end. The command holds more
// than the 0.01 GB it claimed, so the sampler has a record to rewrite.
export async function samplerFails() {
  const tmp = await sh("mktemp -d");
  try {
    await sh(`mkdir '${tmp}/pool'`);
    const script = `const d = Deno.env.get("STACK_POOL") + "/job-" + Deno.env.get("STACK_JOB"); Deno.writeTextFileSync(${JSON.stringify(`${tmp}/child`)}, String(Deno.pid)); Deno.removeSync(d + "/weight"); Deno.mkdirSync(d + "/weight"); const a = new Uint8Array(300e6).fill(1); await new Promise((r) => setTimeout(r, 25000)); console.log(a.length);`;
    const t0 = Date.now();
    const o = await new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", "--no-config", "--no-lock", slotUrl, "--mem", "0.01", "--what", "sampler", "--", Deno.execPath(), "eval", "--no-config", "--no-lock", script],
      env: { STACK_POOL: `${tmp}/pool`, CUE_MIN_FREE_PCT: "0" }, stdout: "piped", stderr: "piped", signal: AbortSignal.timeout(60_000),
    }).output().catch(() => undefined);
    const secs = (Date.now() - t0) / 1000;
    const child = Number(await sh(`cat '${tmp}/child' 2>/dev/null`)) || 0;
    return {
      code: o?.code ?? -1,
      said: /memory reservation could not be kept true/.test(decode(o?.stderr ?? new Uint8Array())),
      stoppedEarly: secs < 20,
      childGone: child > 0 && await until(() => gone(child), 5000),
    };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// The run folders a claim reaps: only directories of this account, named exactly <slot|gate|rehearse>.<pid>.<suffix>, with a dead pid and a
// day's age. A file, a link, a folder with another pid position and one with a live pid are left; `reaped` is what is gone after a claim.
export async function runFoldersReaped() {
  const tmp = await sh("mktemp -d");
  try {
    const dead = 999999;
    const names = { dir: `slot.${dead}.0123456789abcdef`, gate: `gate.${dead}.89abcdef01234567`, backup: `gate.backup.${dead}`, extra: `slot.${dead}.x.0123456789`, short: `slot.${dead}.abc`, live: `slot.${Deno.pid}.0123456789abcdef`, file: `slot.${dead}.fedcba9876543210`, link: `gate.${dead}.aaaaaaaaaaaaaaaa` };
    await sh(`mkdir -p '${tmp}/runs' '${tmp}/pool' && cd '${tmp}/runs' && mkdir '${names.dir}' '${names.gate}' '${names.backup}' '${names.extra}' '${names.short}' '${names.live}' && : > '${names.file}' && ln -s '${names.dir}' '${names.link}' && touch -t 202001010000 '${names.dir}' '${names.gate}' '${names.backup}' '${names.extra}' '${names.short}' '${names.live}' '${names.file}' && touch -h -t 202001010000 '${names.link}'`);
    await new Deno.Command(Deno.execPath(), { args: ["run", "-A", "--no-config", "--no-lock", slotUrl, "--weight", "1", "--what", "reap", "--", "true"], env: { STACK_POOL: `${tmp}/pool`, STACK_RUNS: `${tmp}/runs` }, stdout: "null", stderr: "null", signal: AbortSignal.timeout(60_000) }).output().catch(() => undefined);
    const left = (await sh(`ls '${tmp}/runs'`)).split("\n");
    return Object.fromEntries(Object.entries(names).map(([k, n]) => [k, left.includes(n) ? "kept" : "reaped"]));
  } finally { await sh(`rm -rf '${tmp}'`); }
}
// The run folder's name, read only as a whole in runDir's format.
export async function runPids() {
  const { runPid } = await import("../../harness/files/tests/slot.ts");
  return Object.fromEntries(["slot.123.0123456789abcdef", "gate.9.abcdef", "rehearse.55.89abcdef01", "gate.backup.123", "slot.123", "slot.123.x.y", "slot.123.abc", "x.slot.123.abcdef", "slot.12a.abcdef", "slot.123.ABCDEF"].map((n) => [n.replaceAll(".", "_"), runPid(n) ?? null]));
}
// Which older tickets a cue claim reserves memory behind: a top-level claim all of them, a nested claim only those a holder above it
// does not make wait (olderKeeps' leave-outs). `blocked` is a weighted ticket whose stack weight is not admitted.
export async function cueReserved() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const blocked = { name: "blocked", weighted: true, weight: 9, release: false, mem: 30 }, plain = { name: "plain", weighted: false, weight: 0, release: false, mem: 4 };
  const inLine = [blocked, plain], older = [plain];
  const names = (l) => l.map((t) => t.name);
  return {
    topLevel: names(slot.cueReserves(inLine, older, false, false)),
    nested: names(slot.cueReserves(inLine, older, true, false)),
    topLevelRelease: names(slot.cueReserves(inLine, older, false, true)),
    // the memory an unrelated top-level claim of 40 GB finds free on a 64 GB budget with nothing held, as the poll judges it
    topLevelAdmitted: slot.memAdmits(0, slot.cueReserves(inLine, older, false, false).reduce((n, o) => n + o.mem, 0), 40, 64),
    nestedAdmitted: slot.memAdmits(0, slot.cueReserves(inLine, older, true, false).reduce((n, o) => n + o.mem, 0), 40, 64),
  };
}
// The default cue memory budget: half the physical memory in GB, or one evaluation at a time where it cannot be read.
export async function cueMemDefaults() {
  const { cueMemDefault } = await import("../../harness/files/tests/slot.ts");
  const GiB = 2 ** 30;
  return { g128: cueMemDefault(128 * GiB), g36: cueMemDefault(36 * GiB), g8: cueMemDefault(8 * GiB), unknown: cueMemDefault(undefined), zero: cueMemDefault(0), nan: cueMemDefault(NaN) };
}
// One pool for the machine (PRONTO-774): the warning for a STACK_POOL that is not the default, and the install's refusal of a shell file that sets one.
export async function onePool() {
  const { poolWarning } = await import("../../harness/files/tests/slot.ts");
  const tmp = await sh("mktemp -d");
  try {
    await Deno.writeTextFile(`${tmp}/.zshenv`, "export PATH=$PATH\nexport STACK_POOL=$HOME/.cache/pronto-stacks\nexport STACK_BUDGET=12\n");
    const o = await new Deno.Command("sh", { args: [new URL("../../machine/install.sh", import.meta.url).pathname], env: { HOME: tmp, PATH: Deno.env.get("PATH") ?? "" }, stdout: "piped", stderr: "piped" }).output();
    const err = new TextDecoder().decode(o.stderr);
    let installed = true;
    try { await Deno.stat(`${tmp}/.local`); } catch { installed = false; }
    return {
      unset: poolWarning(undefined), empty: poolWarning(""), same: poolWarning("/tmp/pronto-stacks"), other: poolWarning("/Users/x/.cache/pronto-stacks"),
      code: o.code, names: /\.zshenv/.test(err) && /STACK_POOL=/.test(err) && /STACK_BUDGET=/.test(err), installed,
    };
  } finally { await Deno.remove(tmp, { recursive: true }); }
}
// The pool's lock is reclaimed after a minute only once its owner is verified gone: a live owner's stays (the call waits, bounded), a dead owner's
// and one with no owner file (an older copy made it) are reclaimed.
export async function choosingStale() {
  const tmp = await sh("mktemp -d");
  const sleeper = new Deno.Command("sleep", { args: ["60"] }).spawn();
  try {
    const mk = async (name, pid) => { await sh(`mkdir -p '${tmp}/${name}/.choosing'; ${pid === null ? "" : `echo ${pid} > '${tmp}/${name}/.choosing/pid';`} touch -t 202001010000 '${tmp}/${name}/.choosing'`); };
    await mk("live", sleeper.pid); await mk("dead", 999999); await mk("none", null);
    const body = `console.log(await s.choosing(async () => "ran"))`;
    const took = (r) => r === "ran" ? "ran" : "held";
    return { live: took(await inPool(`${tmp}/live`, body, 3000)), dead: took(await inPool(`${tmp}/dead`, body, 15_000)), none: took(await inPool(`${tmp}/none`, body, 15_000)) };
  } finally { try { sleeper.kill("SIGKILL"); } catch { /* gone */ } await sh(`rm -rf '${tmp}'`); }
}

// PRONTO-892, round 2 (Codex on bsoneca/pronto#1673).
// A periodic task that never overlaps itself: a tick while the last run is still going starts nothing; once it ends the next tick runs; idle waits for the one in flight.
export async function noOverlap() {
  const { oneAtATime } = await import("../../harness/files/tests/slot.ts");
  let started = 0, finished = 0, errors = 0, release;
  const gate = () => new Promise((r) => { release = r; });
  const t = oneAtATime(async () => { started++; await gate(); finished++; if (started === 3) throw new Error("boom"); }, () => { errors++; });
  t.tick(); t.tick(); t.tick();
  const whileRunning = started;
  release(); await t.idle();
  t.tick(); const second = started; release(); await t.idle();
  t.tick(); release(); await t.idle();
  return { whileRunning, second, started, finished, errors };
}
// The chooser lock's owner is a pid and its start time: a pid reused by another process (another start time) is not the chooser.
export async function chooserIdentity() {
  const { chooserOwner, sameProcess, procStart } = await import("../../harness/files/tests/slot.ts");
  return {
    both: chooserOwner("123 1700000000000\n"), pidOnly: chooserOwner("123"), none: chooserOwner(""), junk: chooserOwner("abc def"),
    // /proc/<pid>/stat field 22 (after the ")" of a name that may hold spaces and parentheses) over the boot time: 1000 + 2.5 s
    procStart: procStart("1 (a b) c) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 250 0", "cpu 1 2\nbtime 1000\n"), procStartBad: procStart("x", "btime 1000"),
    same: sameProcess(1_700_000_000_000, 1_700_000_001_500), reused: sameProcess(1_700_000_000_000, 1_700_000_090_000), unwritten: sameProcess(0, 5), unreadable: sameProcess(5, 0),
  };
}
// The lock's owner is a live pid that is a different process (its start time is not the recorded one): reclaimed after a minute. The same live process stays.
export async function choosingReused() {
  const tmp = await sh("mktemp -d");
  const sleeper = new Deno.Command("sleep", { args: ["60"] }).spawn();
  try {
    // The start time as the lock reads it (slot.ts startOf: /proc on Linux, ps's lstart elsewhere): the same read, on either platform.
    const { startOf } = await import(slotUrl);
    const startMs = await startOf(sleeper.pid, true);
    if (!(startMs > 0)) throw new Error(`the start of pid ${sleeper.pid} could not be read`);
    const mk = async (name, text) => { await sh(`mkdir -p '${tmp}/${name}/.choosing'; echo '${text}' > '${tmp}/${name}/.choosing/pid'; touch -t 202001010000 '${tmp}/${name}/.choosing'`); };
    await mk("same", `${sleeper.pid} ${startMs}`);
    await mk("reused", `${sleeper.pid} ${startMs - 3_600_000}`);
    const body = `console.log(await s.choosing(async () => "ran"))`;
    const took = (r) => r === "ran" ? "ran" : "held";
    return { same: took(await inPool(`${tmp}/same`, body, 3000)), reused: took(await inPool(`${tmp}/reused`, body, 15_000)) };
  } finally { try { sleeper.kill("SIGKILL"); } catch { /* gone */ } await sh(`rm -rf '${tmp}'`); }
}
// A gate holds every stack weight; a weighted cue ticket asks the whole memory budget and waits for it; a zero-weight top-level ticket asks the whole budget behind it;
// the gate's nested evaluation then asks for memory. FIFO holds for top-level claims (the zero-weight one waits behind the weighted one), but the nested claim reserves
// behind neither: both wait for weight its holder owns, directly or through the other.
export async function gateNested() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const W = { name: "001-1-w", weighted: true, weight: 6, release: false, nested: false, mem: 64, cores: 0 };
  const Z = { name: "002-2", weighted: false, weight: 0, release: false, nested: false, mem: 64, cores: 0 };
  const inLine = [W, Z];
  // the gate holds the whole budget of stack weight (6 of 6): the weighted ticket's cores are not admitted, so olderKeeps leaves it out; the zero-weight one stays
  const kept = inLine.filter((o) => slot.olderKeeps(o, 6, 0, 6, false, false, false));
  const blocked = slot.blockedOnHolder(inLine, kept, 0, 0, 64, 10);
  const names = (l) => l.map((t) => t.name);
  const behind = (l) => l.reduce((n, o) => n + o.mem, 0);
  const nestedClaim = slot.cueReserves(inLine, kept, true, false, blocked);
  const noBlocked = slot.cueReserves(inLine, kept, true, false);
  return {
    kept: names(kept), blocked: [...blocked].sort(),
    nestedReserves: names(nestedClaim), nestedAdmitted: slot.memAdmits(0, behind(nestedClaim), 10, 64),
    withoutTheFix: names(noBlocked), withoutTheFixAdmitted: slot.memAdmits(0, behind(noBlocked), 10, 64),
    topLevelReserves: names(slot.cueReserves(inLine, kept, false, false, blocked)),
    // a zero-weight ticket that does not wait on the weighted one (it fits beside it) is kept, and so is a nested ticket of the holder
    unrelatedKept: (() => { const z = { ...Z, mem: 0.5 }; return [...slot.blockedOnHolder([{ ...W, mem: 30 }, z], [z], 0, 0, 64, 10)].sort(); })(),
    siblingKept: (() => { const z = { ...Z, nested: true }; return [...slot.blockedOnHolder([W, z], [z], 0, 0, 64, 10)].sort(); })(),
  };
}

// PRONTO-775: a top-level ticket that waited over CUE_HEAD_WAIT at the head of the cue line is waited for by newer nested claims.
export async function headBarrier() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const now = 10_000_000;
  const top = (queued, o = {}) => ({ name: `${queued}-7-w`, weighted: true, nested: false, mem: 10, cores: 2, ...o });
  const old = top(now - 11 * 60_000), fresh = top(now - 9 * 60_000);
  const head = (line, held = [0, 0]) => slot.agedHead(line, now, 600_000, held[0], held[1], 64, 10);
  return {
    aged: head([old])?.name, fresh: head([fresh])?.name ?? null,
    notAtHead: head([{ ...old, name: `${now - 20 * 60_000}-8`, nested: true }, old])?.name ?? null,
    doesNotFit: head([old], [60, 0])?.name ?? null,
    nestedWaits: slot.nestedBarrier(head([old]), true, 0)?.name,
    topLevelNever: slot.nestedBarrier(head([old]), false, 0)?.name ?? null,
    underWeightedHolder: slot.nestedBarrier(head([old]), true, 6)?.name ?? null,
    unweightedUnderHolder: slot.nestedBarrier(head([top(now - 11 * 60_000, { weighted: false })]), true, 6)?.name,
    noHead: slot.nestedBarrier(undefined, true, 0) ?? null,
  };
}
// PRONTO-775: cores learned are the peak of a 10 s moving average, capped at GOMAXPROCS.
export async function coresPeak() {
  const slot = await import("../../harness/files/tests/slot.ts");
  // 20 s: busy at 7 cores for 10 s, then 1 core: the whole-run average is 4, the peak 7
  const series = Array.from({ length: 21 }, (_, t) => ({ t, cpu: t <= 10 ? 7 * t : 70 + (t - 10) }));
  return {
    peak: slot.peakCores(series), average: series.at(-1).cpu / 20,
    short: slot.peakCores([{ t: 0, cpu: 0 }, { t: 3, cpu: 9 }]),
    wholeRun: slot.peakCores([{ t: 0, cpu: 0 }, { t: 6, cpu: 12 }]),
    learned: slot.coresLearned(slot.peakCores(series), 4, 0, 7),
    capped: slot.coresLearned(9, 4, 0, 7),
    failedKeepsBefore: slot.coresLearned(2, 2, 5, 7),
    noPeakUsesAverage: slot.coresLearned(0, 3.456, 0, 7),
  };
}

// slot.ts's backfill (PRONTO-1900): whether a claim of `w` is admitted behind `older` tickets with `used` held, `releaseHeld` of it by releases
// (budget 15, head wait 600 s). A ticket is { weight, young } (young: asked 1 s ago, else 700 s ago), a release one { release: true }.
export async function backfill() {
  const slot = await import("../../harness/files/tests/slot.ts");
  const now = 10_000_000, wait = 600_000;
  const tickets = (older) => older.map((o) => ({ weight: o.weight, release: !!o.release, queued: now - (o.young ? 1000 : 700_000) }));
  const ahead = (used, releaseHeld, older) => slot.backfillAhead(tickets(older), used, releaseHeld, 15, now, wait);
  const admitted = (used, releaseHeld, older, w) => slot.admits(used, w, ahead(used, releaseHeld, older), 15);
  const young = (weight) => ({ weight, young: true }), aged = (weight) => ({ weight });
  // The memory veto's head flag as the claim computes it: no heavy holder and nothing older in the cores' line.
  const vetoed = (coresOlder) => slot.memVetoed(5, 20, null, 0, coresOlder === 0);
  // A release claim's head flag as the claim computes it: only older release tickets are ahead of it.
  const releaseVetoed = (older) => slot.memVetoed(5, 20, null, 0, !older.some((o) => o.release));
  const sh = async (script) => new TextDecoder().decode((await new Deno.Command("sh", { args: ["-c", script], stdout: "piped" }).output()).stdout).trim();
  return {
    incident: admitted(10, 10, [young(10)], 1),
    fillsRoomOnly: admitted(10, 10, [young(10), young(2), young(2)], 2),
    fillsRoomFirst: admitted(10, 10, [young(10), young(2)], 2),
    shadowAdmits: admitted(11, 8, [aged(6)], 4),
    shadowRefuses: admitted(13, 4, [aged(6)], 1),
    youngNoRelease: admitted(12, 0, [young(6)], 1),
    agedNoRelease: admitted(12, 0, [aged(6)], 1),
    fitsBeforeHeadYoung: admitted(5, 0, [young(3), young(10), young(2)], 3),
    fitsBeforeHeadAged: admitted(5, 0, [young(3), aged(10), young(2)], 3),
    headAheadYoung: ahead(5, 0, [young(3), young(10), young(2)]),
    headAheadAged: ahead(5, 0, [young(3), aged(10), young(2)]),
    overBudgetHead: admitted(0, 0, [], 20),
    overBudgetHeadAged: admitted(0, 0, [aged(20)], 1),
    emptyLine: ahead(7, 0, []),
    releaseHeadAged: admitted(10, 10, [{ weight: 10, release: true, young: true }], 6),
    releaseClaimUnchanged: slot.aheadOf([{ weight: 3, release: false }, { weight: 4, release: true }], true, false),
    heldUnchanged: slot.admitsCores(false, 10, 1, slot.aheadOf([{ weight: 3, release: false }], false, true), 15, false, false, true, false),
    vetoNotHead: vetoed(1),
    vetoHead: vetoed(0),
    releaseBehindOrdinaryVetoed: releaseVetoed([{ release: false }, { release: false }]),
    releaseBehindReleaseVetoed: releaseVetoed([{ release: true }]),
    releaseTicketAhead: ahead(5, 0, [{ weight: 3, release: true, young: true }, young(10), young(1)]),
    shadowCountsReserve: admitted(8, 0, [young(3), aged(10), young(2)], 3),
    // The claim end to end (slot.ts as the gate runs it): a pool where a live release holds 10 of 15 and a weight-10 ticket waits,
    // then the same with no release, the head aged (STACK_HEAD_WAIT=1).
    ...await (async () => {
      const tmp = await sh("mktemp -d");
      const procs = [];
      try {
        const sleeper = () => { const p = new Deno.Command("sleep", { args: ["120"] }).spawn(); procs.push(p); return p.pid; };
        const run = async (env, ms) => {
          const c = new Deno.Command(Deno.execPath(), { args: ["run", "-A", slotUrl, "--weight", "1", "--what", "backfill probe", "--", "true"],
            clearEnv: true, env: { PATH: Deno.env.get("PATH") ?? "", HOME: tmp, STACK_POOL: `${tmp}/pool`, STACK_BUDGET: "15", STACK_HOLD_LOAD: "100000", STACK_RESERVE: "0", ...env }, stdout: "null", stderr: "null" }).spawn();
          const t = setTimeout(() => { try { c.kill("SIGTERM"); } catch { /* done */ } }, ms);
          const code = (await c.status).code; clearTimeout(t);
          return code;
        };
        const setup = async (release) => {
          await sh(`rm -rf '${tmp}/pool' && mkdir -p '${tmp}/pool/queue' && chmod 755 '${tmp}/pool' '${tmp}/pool/queue'`);
          const holder = sleeper(), headPid = sleeper();
          await new Promise((r) => setTimeout(r, 1500));
          await sh(`mkdir -p '${tmp}/pool/slot-1' && echo ${holder} > '${tmp}/pool/slot-1/pid' && echo 'x 2026 release holder' > '${tmp}/pool/slot-1/owner'
echo '${holder} 10${release ? " prio=release" : ""}' > '${tmp}/pool/slot-1/weight' && chmod 755 '${tmp}/pool/slot-1' && chmod 644 '${tmp}/pool/slot-1/'*
echo '10 prio=normal head gate' > '${tmp}/pool/queue/'$(printf '%015d' $(( $(date +%s) * 1000 - ${release ? 1000 : 5000} )))-${headPid} && chmod 644 '${tmp}/pool/queue/'*`);
        };
        await setup(true);
        const beside = await run({}, 20_000);
        await setup(false);
        const drains = await run({ STACK_HEAD_WAIT: "1" }, 6_000);
        return { e2eBeside: beside, e2eDrains: drains !== 0 };
      } finally { for (const p of procs) { try { p.kill("SIGKILL"); } catch { /* gone */ } } await sh(`rm -rf '${tmp}'`); }
    })(),
  };
}
