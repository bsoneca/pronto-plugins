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
      loadFails: (() => { try { slot.load1(() => { throw new Error("Requires sys access"); }); return "read"; } catch (e) { return e.message; } })(),
    };
  } finally { await sh(`rm -rf '${tmp}'`); }
}
