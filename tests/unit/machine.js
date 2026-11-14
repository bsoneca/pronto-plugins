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
