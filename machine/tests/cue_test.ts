// The cue wrapper (../cue, machine/cue: the one a Mac installs, and pronto-fork's runtime root), against a fake cue: what passes through at once,
// what claims memory and cores from the pool, and what it learns. Each case has its own PATH, HOME and pool.
import { strict as assert } from "node:assert";

const assertEquals = (a: unknown, b: unknown, why?: string) => assert.deepStrictEqual(a, b, why);
const assertMatch = (s: string, re: RegExp, why?: string) => assert.match(s, re, why);

const wrapper = new URL("../cue", import.meta.url).pathname;
const runtime = wrapper.replace(/\/cue$/, "");
const deno = Deno.execPath().replace(/\/deno$/, "");

// A fake cue that says what it was asked, echoes its stdin for `export -`, holds `mb` MB (as RSS: it
// becomes a deno that fills a buffer, one process as cue is) or sleeps `sleep` s, noting a TERM.
const fake = async (dir: string, mb = 0, sleep = 0) => {
  await Deno.mkdir(`${dir}/bin`, { recursive: true });
  await Deno.writeTextFile(`${dir}/bin/cue`, `#!/bin/sh
echo "s $* $(date +%s)" >> "${dir}/times"
echo "real cue $*"
[ "$CUE_BUDGET_WRAPPED" ] && echo wrapped
[ "$GOMAXPROCS" ] && echo "gomaxprocs $GOMAXPROCS"
[ "$2" = - ] && cat
[ ${mb} -gt 0 ] && exec "${deno}/deno" eval 'const a = new Uint8Array(${mb} * 2 ** 20); a.fill(1); await new Promise((r) => setTimeout(r, 1500)); console.log(a[7])'
[ ${sleep} -gt 0 ] && { trap 'echo got TERM >> "${dir}/signals"; exit 143' TERM; sleep ${sleep} & wait; }
echo "e $* $(date +%s)" >> "${dir}/times"
exit 0
`);
  await Deno.chmod(`${dir}/bin/cue`, 0o755);
};

const run = async (dir: string, args: string[], env: Record<string, string> = {}, stdin?: string, cwd = dir) => {
  const child = new Deno.Command(wrapper, {
    args,
    cwd,
    env: { PATH: `${runtime}:${dir}/bin:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, STACK_POOL: `${dir}/pool`, CUE_MIN_FREE_PCT: "0", ...env },
    clearEnv: true,
    stdin: stdin === undefined ? "null" : "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  if (stdin !== undefined) {
    const w = child.stdin.getWriter();
    await w.write(new TextEncoder().encode(stdin));
    await w.close();
  }
  const out = await child.output();
  const text = (b: Uint8Array) => new TextDecoder().decode(b);
  return { code: out.code, stdout: text(out.stdout), stderr: text(out.stderr) };
};

const learned = async (dir: string) => {
  const files = [];
  for await (const e of Deno.readDir(`${dir}/.cache/pronto/cue-mem`)) if (e.isFile && !/\.(cores|secs)$/.test(e.name)) files.push(await Deno.readTextFile(`${dir}/.cache/pronto/cue-mem/${e.name}`));
  return files;
};

Deno.test("a command that evaluates nothing runs at once, and never claims", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  const r = await run(dir, ["fmt", "x.cue"]);
  assertEquals(r.code, 0);
  assertMatch(r.stdout, /^real cue fmt x\.cue/);
  assertEquals(r.stderr, "", "no slot line: it never reached the pool");
});

Deno.test("an evaluation never seen claims CUE_UNKNOWN_GB, then learns its peak and runs outside the pool", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 64);
  const first = await run(dir, ["export", "./spec"], { CUE_UNKNOWN_GB: "3" });
  assertEquals(first.code, 0);
  assertMatch(first.stderr, /slot: cue \.: weight [0-9.]+ of [0-9.]+ \(cue memory [0-9.]+ GB, [0-9.]+ cores\)/);
  const [peak] = (await learned(dir))[0].split(" ");
  assert.ok(Number(peak) > 0.05 && Number(peak) < 1, `learned ${peak} GB for a cue holding ~64 MB`);
  const second = await run(dir, ["export", "./spec"]);
  assertEquals(second.code, 0);
  assertEquals(second.stderr.includes("slot:"), false, "learned under CUE_DIRECT_GB: no claim");
  assertMatch((await learned(dir))[0], /^0\.[0-9]+ cue export \.\/spec/, "measured again by time");
});

Deno.test("an evaluation learned large claims that memory, a quarter more, from the cue budget", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await run(dir, ["vet", "-c", "./spec"], { CUE_UNKNOWN_GB: "1" });
  const file = (await Array.fromAsync(Deno.readDir(`${dir}/.cache/pronto/cue-mem`))).find((e) => e.isFile)!.name;
  await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${file}`, "2 cue vet -c ./spec\n");
  const r = await run(dir, ["vet", "-c", "./spec"]);
  assertMatch(r.stderr, /slot: cue \.: weight [0-9.]+ of [0-9.]+ \(cue memory 2\.5 GB, [0-9.]+ cores\)/);
});

Deno.test("stdin reaches cue on both paths", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  const claimed = await run(dir, ["export", "-"], { CUE_UNKNOWN_GB: "1" }, "a: 1\n");
  assertMatch(claimed.stdout, /a: 1/);
  const direct = await run(dir, ["export", "-"], {}, "b: 2\n");
  assertEquals(direct.stderr.includes("slot:"), false);
  assertMatch(direct.stdout, /b: 2/, "a background command loses its stdin unless kept");
});

Deno.test("a cue run by a cue is its parent's, and a CUE_BUDGET=off one claims nothing", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  const inner = await run(dir, ["export", "./spec"], { CUE_BUDGET_WRAPPED: "1" });
  assertEquals(inner.stderr, "");
  const off = await run(dir, ["export", "./spec"], { CUE_BUDGET: "off" });
  assertEquals(off.stderr, "");
});

Deno.test("a signal to the wrapper reaches cue on the direct path", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await run(dir, ["eval", "./spec"], { CUE_UNKNOWN_GB: "1" });
  // Learned small now; the next run is direct, and is stopped mid-run.
  await fake(dir, 0, 30);
  const child = new Deno.Command(wrapper, {
    args: ["eval", "./spec"],
    cwd: dir,
    env: { PATH: `${runtime}:${dir}/bin:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, STACK_POOL: `${dir}/pool` },
    clearEnv: true,
    stdout: "null",
    stderr: "null",
  }).spawn();
  await new Promise((r) => setTimeout(r, 1500));
  child.kill("SIGTERM");
  await child.status;
  await new Promise((r) => setTimeout(r, 500));
  assertMatch(await Deno.readTextFile(`${dir}/signals`), /got TERM/, "cue would run on, orphaned, unbudgeted");
});

Deno.test("two wrappers on one PATH (a machine's and a runtime's) claim once and reach cue", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await Deno.mkdir(`${dir}/machine/cue-budget`, { recursive: true });
  await Deno.copyFile(wrapper, `${dir}/machine/cue`);
  await Deno.chmod(`${dir}/machine/cue`, 0o755);
  // The slot pool beside the wrapper: cue-budget/slot.ts in a runtime, slot.ts in machine/.
  const slot = await Deno.stat(`${runtime}/cue-budget/slot.ts`).then(() => `${runtime}/cue-budget/slot.ts`, () => `${runtime}/slot.ts`);
  await Deno.copyFile(slot, `${dir}/machine/cue-budget/slot.ts`);
  // Its own argument, so a loop left behind is found and stopped.
  const spec = `./spec-${crypto.randomUUID()}`;
  const child = new Deno.Command(`${dir}/machine/cue`, {
    args: ["export", spec],
    cwd: dir,
    env: { PATH: `${dir}/machine:${runtime}:${dir}/bin:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, STACK_POOL: `${dir}/pool`, CUE_UNKNOWN_GB: "1" },
    clearEnv: true,
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const out = child.output();
  // Two that skip only themselves exec each other for ever.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const done = await Promise.race([out.then(() => true), new Promise<boolean>((r) => (timer = setTimeout(() => r(false), 20_000)))]);
  clearTimeout(timer);
  if (!done) {
    // exec keeps the pid: the loop is this child, whichever wrapper it is in now.
    try { child.kill("SIGKILL"); } catch { /* gone already */ }
    await out.catch(() => {});
    assert.fail("the wrappers handed cue to each other until killed");
  }
  const { code, stdout, stderr } = await out;
  const text = (b: Uint8Array) => new TextDecoder().decode(b);
  assertEquals(code, 0);
  assertMatch(text(stdout), new RegExp(`^real cue export ${spec.replace(/[.]/g, "\\.")}`));
  assertEquals(text(stderr).match(/slot: cue/g)?.length, 1, "one claim, not one per wrapper");
});

Deno.test("a vet re-vets only the packages whose inputs changed since one passed", async () => {
  // The module is the case's folder: run() puts its bin (the fake cue) on PATH and its HOME there.
  const dir = (await Deno.makeTempDir()) + "/m";
  await Deno.mkdir(dir);
  await fake(dir);
  await Deno.mkdir(`${dir}/cue.mod`, { recursive: true });
  await Deno.writeTextFile(`${dir}/cue.mod/module.cue`, `module: "t.example/m@v0"\nlanguage: version: "v0.16.0"\n`);
  for (const p of ["a", "b", "c"]) await Deno.mkdir(`${dir}/${p}`);
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 1\n`);
  await Deno.writeTextFile(`${dir}/b/b.cue`, `package b\nimport "t.example/m/a"\ny: a.x\n`);
  await Deno.writeTextFile(`${dir}/c/c.cue`, `package c\nz: _ @embed(file="z.json")\n`);
  await Deno.writeTextFile(`${dir}/c/z.json`, `1`);
  await Deno.writeTextFile(`${dir}/c/notes.cue`, `// no package clause: not a package of its own\n`);
  const vet = (env: Record<string, string> = {}) =>
    run(dir, ["vet", "-c", "./..."], { CUE_DIRECT_GB: "0", CUE_UNKNOWN_GB: "0.1", ...env });
  const first = await vet();
  assertEquals(first.code, 0);
  assertMatch(first.stdout, /real cue vet -c \.\/a \.\/b \.\/c/);
  const again = await vet();
  assertEquals(again.code, 0);
  assertEquals(again.stdout, "", "every package passed before: cue is not run");
  assertMatch(again.stderr, /passed before with these same inputs/);
  // An edit to a reaches b, which imports it; c is untouched.
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 2\n`);
  const edited = await vet();
  assertMatch(edited.stdout, /real cue vet -c \.\/a \.\/b\n/);
  // An embedded file is an input too.
  await Deno.writeTextFile(`${dir}/c/z.json`, `2`);
  assertMatch((await vet()).stdout, /real cue vet -c \.\/c\n/);
  // A vet that fails records nothing; CUE_VETTED=off vets every time.
  await Deno.writeTextFile(`${dir}/bin/cue`, `#!/bin/sh\necho "real cue $*"\nexit 1\n`);
  await Deno.writeTextFile(`${dir}/b/b.cue`, `package b\nimport "t.example/m/a"\ny: a.x + 1\n`);
  assertEquals((await vet()).code, 1);
  assertEquals((await vet()).code, 1, "a failed vet was not recorded");
  await fake(dir);
  assertEquals((await vet()).code, 0);
  assertMatch((await vet({ CUE_VETTED: "off" })).stdout, /real cue vet -c \.\/\.\.\./);
});

Deno.test("an export is printed from a passing one with the same inputs, tags deciding which files count", async () => {
  const dir = (await Deno.makeTempDir()) + "/m";
  await Deno.mkdir(dir);
  await fake(dir);
  await Deno.mkdir(`${dir}/cue.mod`, { recursive: true });
  await Deno.writeTextFile(`${dir}/cue.mod/module.cue`, `module: "t.example/m@v0"\nlanguage: version: "v0.16.0"\n`);
  await Deno.mkdir(`${dir}/a`);
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 1\n`);
  await Deno.writeTextFile(`${dir}/a/l1.cue`, `@if(l1)\npackage a\ny: 1\n`);
  await Deno.writeTextFile(`${dir}/a/l2.cue`, `@if(l2)\npackage a\ny: 2\n`);
  const env = { CUE_DIRECT_GB: "0", CUE_UNKNOWN_GB: "0.1" };
  const exp = (args: string[], more: Record<string, string> = {}) => run(dir, ["export", "./a", ...args], { ...env, ...more });
  const first = await exp(["-t", "l1", "--out", "json"]);
  assertEquals(first.code, 0);
  assertMatch(first.stdout, /^real cue export \.\/a -t l1 --out json\n/);
  const again = await exp(["-t", "l1", "--out", "json"]);
  assertEquals(again.stdout, first.stdout, "the kept output is printed as cue printed it");
  assertMatch(again.stderr, /printed from a passing export/);
  // A file the tags leave out is not an input; one they keep is.
  await Deno.writeTextFile(`${dir}/a/l2.cue`, `@if(l2)\npackage a\ny: 3\n`);
  assertMatch((await exp(["-t", "l1", "--out", "json"])).stderr, /printed from a passing export/);
  await Deno.writeTextFile(`${dir}/a/l1.cue`, `@if(l1)\npackage a\ny: 4\n`);
  assertEquals((await exp(["-t", "l1", "--out", "json"])).stderr.includes("printed from a passing export"), false);
  // A package importing a's with its major version and package (\`mod@v0:pkg\`, as pronto's reads do) is keyed by a's files.
  await Deno.mkdir(`${dir}/a/obs`);
  await Deno.writeTextFile(`${dir}/a/obs/o.cue`, `package obs\nimport a "t.example/m/a@v0:a"\nr: a.x\n`);
  const obs = () => run(dir, ["export", "./a/obs", "-e", "r"], env);
  await obs();
  assertMatch((await obs()).stderr, /printed from a passing export/);
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 5\n`);
  assertEquals((await obs()).stderr.includes("printed from a passing export"), false, "an edit to the imported package is a miss");
  // A failing export keeps nothing; -o and CUE_EXPORTED=off run as asked.
  await Deno.writeTextFile(`${dir}/bin/cue`, `#!/bin/sh\necho "real cue $*"\nexit 1\n`);
  assertEquals((await exp(["-e", "x"])).code, 1);
  assertEquals((await exp(["-e", "x"])).code, 1, "a failed export was not kept");
  await fake(dir);
  assertMatch((await exp(["-e", "x"])).stdout, /^real\ cue\ export\ \.\/a\ \-e\ x\n/);
  assertMatch((await exp(["-e", "x"], { CUE_EXPORTED: "off" })).stdout, /^real\ cue\ export\ \.\/a\ \-e\ x\n/);
  assertMatch((await exp(["-o", "out.json"])).stdout, /^real\ cue\ export\ \.\/a\ \-o\ out\.json\n/);
  assertMatch((await exp(["-o", "out.json"])).stdout, /^real\ cue\ export\ \.\/a\ \-o\ out\.json\n/, "-o is never printed from the cache");
  assertMatch((await exp(["-oout.json"])).stdout, /^real cue export \.\/a -oout\.json\n/);
  assertMatch((await exp(["-oout.json"])).stdout, /^real cue export \.\/a -oout\.json\n/, "nor a glued -o");
});

Deno.test("an export run at once, outside the pool, is printed from a passing one with the same inputs (PRONTO-11)", async () => {
  const dir = (await Deno.makeTempDir()) + "/m";
  await Deno.mkdir(dir);
  await Deno.mkdir(`${dir}/bin`);
  // A cue that prints how many times it ran: a replay prints the first run's bytes, an evaluation new ones.
  await Deno.writeTextFile(`${dir}/bin/cue`, `#!/bin/sh\nn=$(($(cat "${dir}/n" 2>/dev/null || echo 0) + 1)); echo $n > "${dir}/n"; echo "run $n"\n`);
  await Deno.chmod(`${dir}/bin/cue`, 0o755);
  await Deno.mkdir(`${dir}/cue.mod`);
  await Deno.writeTextFile(`${dir}/cue.mod/module.cue`, `module: "t.example/m@v0"\nlanguage: version: "v0.16.0"\n`);
  await Deno.writeTextFile(`${dir}/a.cue`, `package a\nx: 1\n`);
  // CUE_UNKNOWN_GB=0: the first run's claim is 0, the direct path an export learned under CUE_DIRECT_GB takes.
  const env = { CUE_UNKNOWN_GB: "0", CUE_REPLAY_MIN_S: "0" };
  const exp = (more: Record<string, string> = {}, args: string[] = []) => run(dir, ["export", ".", "--out", "json", ...args], { ...env, ...more });
  const first = await exp();
  assertEquals([first.code, first.stdout, first.stderr.includes("slot:")], [0, "run 1\n", false]);
  const second = await exp();
  assertEquals(second.stdout, "run 1\n", "the same bytes, not evaluated");
  assertMatch(second.stderr, /not evaluated again/);
  assertEquals((await exp({ CUE_EXPORTED: "off" })).stdout, "run 2\n", "CUE_EXPORTED=off evaluates");
  assertEquals((await exp({ CUE_REPLAY_MIN_S: "5" })).stdout, "run 3\n", "one that took less CPU than a hit costs is evaluated");
  assertEquals((await exp({}, ["-o", "out.json"])).stdout, "run 4\n", "-o evaluates");
  await Deno.writeTextFile(`${dir}/b.cue`, `package a\ny: 2\n`);
  assertEquals((await exp()).stdout, "run 5\n", "a changed input evaluates");
});

const sh = async (cwd: string, ...args: string[]) => {
  const o = await new Deno.Command("git", { args, cwd, stdout: "piped", stderr: "piped" }).output();
  assert.equal(o.code, 0, new TextDecoder().decode(o.stderr));
  return new TextDecoder().decode(o.stdout).trim();
};

Deno.test("an evaluation in a temporary copy keeps its id across copies", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 64);
  const [a, b] = [await Deno.makeTempDir({ dir: "/tmp", prefix: "copy-" }), await Deno.makeTempDir({ dir: "/tmp", prefix: "copy-" })];
  for (const c of [a, b]) await Deno.mkdir(`${c}/apps/x/spec`, { recursive: true });
  const first = await run(dir, ["export", "./spec"], { CUE_UNKNOWN_GB: "3" }, undefined, `${a}/apps/x`);
  assertMatch(first.stderr, /slot: cue /);
  const second = await run(dir, ["export", "./spec"], {}, undefined, `${b}/apps/x`);
  assertEquals(second.code, 0);
  assertEquals(second.stderr.includes("slot:"), false, "same evaluation: learned, no claim");
  assertEquals((await learned(dir)).length, 1);
  for (const c of [a, b]) await Deno.remove(c, { recursive: true });
});

Deno.test("an absolute path argument in two worktrees of one repository keys as one", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 64);
  const repo = await Deno.makeTempDir({ prefix: "repo-" });
  await sh(repo, "init", "-q");
  await Deno.writeTextFile(`${repo}/x.cue`, "a: 1\n");
  await sh(repo, "add", "x.cue");
  await sh(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x");
  const wt = await Deno.makeTempDir({ prefix: "wt-" });
  await sh(repo, "worktree", "add", "-q", "-b", "other", `${wt}/b`);
  const first = await run(dir, ["export", `${repo}/x.cue`], { CUE_UNKNOWN_GB: "3" });
  assertMatch(first.stderr, /slot: cue /);
  const second = await run(dir, ["export", `${wt}/b/x.cue`]);
  assertEquals(second.code, 0);
  assertEquals(second.stderr.includes("slot:"), false, "same repository and place: no claim");
  assertEquals((await learned(dir)).length, 1);
  await Deno.remove(wt, { recursive: true });
  await Deno.remove(repo, { recursive: true });
});

Deno.test("a plain evaluation's id is what it was", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  const repo = await Deno.makeTempDir({ dir: new URL(".", import.meta.url).pathname, prefix: "plain-" });
  await sh(repo, "init", "-q");
  await Deno.mkdir(`${repo}/sub/spec`, { recursive: true });
  await run(dir, ["export", "./spec"], { CUE_UNKNOWN_GB: "1" }, undefined, `${repo}/sub`);
  const common = await sh(`${repo}/sub`, "rev-parse", "--path-format=absolute", "--git-common-dir");
  const key = `${common}\nsub/ export ./spec`;
  const { createHash } = await import("node:crypto");
  const id = createHash("md5").update(key).digest("hex");
  const names = [];
  for await (const e of Deno.readDir(`${dir}/.cache/pronto/cue-mem`)) if (e.isFile) names.push(e.name);
  assert.ok(names.includes(id), `${names} should include ${id}`);
  await Deno.remove(repo, { recursive: true });
});

// Two evaluations of ./spec from the given cwds, sharing one HOME: how many ids they learned, and whether the second claimed.
const twice = async (cwdA: string, cwdB: string, argsA = ["export", "./spec"], argsB = argsA) => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 64);
  await run(dir, argsA, { CUE_UNKNOWN_GB: "3" }, undefined, cwdA);
  const second = await run(dir, argsB, {}, undefined, cwdB);
  return { claimed: second.stderr.includes("slot:"), ids: (await learned(dir)).length };
};

Deno.test("distinct temporary names stay distinct", async () => {
  const [a, b] = ["/tmp/cuetest-plugins", "/tmp/cuetest-runtime"];
  for (const c of [a, b]) await Deno.mkdir(`${c}/spec`, { recursive: true });
  try {
    const r = await twice(a, b);
    assertEquals(r.ids, 2, "plugins and runtime are two evaluations");
    assertEquals(r.claimed, true);
  } finally {
    for (const c of [a, b]) await Deno.remove(c, { recursive: true });
  }
});

Deno.test("a separator-less random temporary folder keeps one id", async () => {
  const [a, b] = ["/tmp/a1b2c3d4e5", "/tmp/f6e5d4c3b2"];
  for (const c of [a, b]) await Deno.mkdir(`${c}/spec`, { recursive: true });
  try {
    const r = await twice(a, b);
    assertEquals(r.claimed, false);
    assertEquals(r.ids, 1);
  } finally {
    for (const c of [a, b]) await Deno.remove(c, { recursive: true });
  }
});

// release.nu passes `mktemp -t roles.XXXXXX.json` to cue export: Studio's Publish ran ~15 such evaluations, each a new id
// claiming CUE_UNKNOWN_GB in the cue lock, and waited minutes behind large ones for 40 MB evaluations (PRONTO-736).
Deno.test("a mktemp file with its random part in the middle keeps one id; a fixed name stays itself", async () => {
  const d = await Deno.makeTempDir({ dir: "/tmp", prefix: "cuetest-" });
  await Deno.mkdir(`${d}/spec`, { recursive: true });
  const [a, b, c, e] = ["/tmp/roles.c4qN0s.json", "/tmp/roles.awAixC.json", "/tmp/one.tar.json", "/tmp/two.tar.json"];
  for (const f of [a, b, c, e]) await Deno.writeTextFile(f, "{}");
  try {
    const r = await twice(`${d}`, `${d}`, ["export", "./spec", a], ["export", "./spec", b]);
    assertEquals(r.claimed, false, "roles.<random>.json is one file to the key, a random part without a digit (mixed case) too");
    assertEquals(r.ids, 1);
    const fixed = await twice(`${d}`, `${d}`, ["export", "./spec", c], ["export", "./spec", e]);
    assertEquals(fixed.ids, 2, "a middle of one case without a digit is a name, not a random part");
  } finally {
    for (const f of [a, b, c, e]) await Deno.remove(f);
    await Deno.remove(d, { recursive: true });
  }
});

const repoWith = async (path: string, file: string) => {
  await Deno.mkdir(path, { recursive: true });
  await sh(path, "init", "-q");
  await Deno.writeTextFile(`${path}/${file}`, "a: 1\n");
  await sh(path, "add", file);
  await sh(path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x");
};

Deno.test("a CI runner's clones are one evaluation", async () => {
  const root = await Deno.makeTempDir({ prefix: "runners-" });
  try {
    const [a, b] = [`${root}/actions-runners/r1/_work/p/p`, `${root}/actions-runners/r2/_work/p/p`];
    for (const c of [a, b]) await repoWith(c, "x.cue");
    const r = await twice(root, root, ["export", `${a}/x.cue`], ["export", `${b}/x.cue`]);
    assertEquals(r.claimed, false);
    assertEquals(r.ids, 1);
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});

Deno.test("an output file not yet written keys by its place in the repository", async () => {
  const repo = await Deno.makeTempDir({ prefix: "repo-" });
  const wt = await Deno.makeTempDir({ prefix: "wt-" });
  try {
    await repoWith(repo, "x.cue");
    await sh(repo, "worktree", "add", "-q", "-b", "other", `${wt}/b`);
    const r = await twice(repo, repo, ["export", "-o", `${repo}/out.json`], ["export", "-o", `${wt}/b/out.json`]);
    assertEquals(r.claimed, false);
    assertEquals(r.ids, 1);
  } finally {
    await Deno.remove(wt, { recursive: true });
    await Deno.remove(repo, { recursive: true });
  }
});

// The wrapper claims cue memory and cue cores, never the stacks' weight (PRONTO-838, reverting the weight half of
// PRONTO-761); its parallelism is bounded by GOMAXPROCS. The pool is small (STACK_BUDGET=6) so a full pool is easy to hold.
const poolEnv = { STACK_BUDGET: "6" };
const envOf = (dir: string, more: Record<string, string> = {}) =>
  ({ PATH: `${runtime}:${dir}/bin:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: dir, STACK_POOL: `${dir}/pool`, CUE_MIN_FREE_PCT: "0", ...more });
const text = (b: Uint8Array) => new TextDecoder().decode(b);
// The wrapper started, not waited for: its output is read when it ends.
const start = (dir: string, args: string[], more: Record<string, string> = {}) => {
  const child = new Deno.Command(wrapper, { args, cwd: dir, env: envOf(dir, more), clearEnv: true, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  const done = child.output().then((o) => ({ code: o.code, stdout: text(o.stdout), stderr: text(o.stderr) }));
  return { child, done };
};
// What the pool's jobs hold now: their weight records, "<pid> <weight>[ cue][ in=<holder>]".
const jobs = async (dir: string) => {
  const out: string[] = [];
  try { for await (const e of Deno.readDir(`${dir}/pool`)) if (e.name.startsWith("job-")) out.push((await Deno.readTextFile(`${dir}/pool/${e.name}/weight`).catch(() => "")).trim()); } catch { /* no pool yet */ }
  return out;
};
const until = async <T>(f: () => Promise<T | undefined | false>, what: string, ms = 20_000): Promise<T> => {
  for (const end = Date.now() + ms; Date.now() < end;) { const v = await f(); if (v) return v; await new Promise((r) => setTimeout(r, 100)); }
  throw new Error(`timed out waiting for ${what}`);
};
// The learned files of the evaluations a case has seen: their names (the ids), without the cores' and seconds' beside them.
const learnedNames = async (dir: string) => {
  const names: string[] = [];
  try { for await (const e of Deno.readDir(`${dir}/.cache/pronto/cue-mem`)) if (e.isFile && !/\.(cores|secs)$/.test(e.name)) names.push(e.name); } catch { /* none yet */ }
  return names;
};
const learnedName = async (dir: string) => {
  const [name] = await learnedNames(dir);
  if (!name) throw new Error("nothing learned");
  return name;
};
// An evaluation primed: seen once (so its memory is learned), its memory set to `gb` and its cores to `cores`.
const prime = async (dir: string, args: string[], cores?: number, gb = 2) => {
  const before = await learnedNames(dir);
  await run(dir, args, { CUE_UNKNOWN_GB: "1" });
  const name = (await learnedNames(dir)).find((n) => !before.includes(n));
  if (!name) throw new Error("nothing new learned");
  await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${name}`, `${gb} cue ${args.join(" ")}\n`);
  if (cores !== undefined) await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${name}.cores`, `${cores}\n`);
  return name;
};
// A holder of `weight` in the pool: a live process, as slot.ts's own job would be.
const hold = async (dir: string, weight: number) => {
  const sleeper = new Deno.Command("sleep", { args: ["60"], stdout: "null", stderr: "null" }).spawn();
  const d = `${dir}/pool/job-${sleeper.pid}`;
  await Deno.mkdir(d, { recursive: true });
  await Deno.writeTextFile(`${d}/weight`, `${sleeper.pid} ${weight}`);
  await Deno.writeTextFile(`${d}/pid`, String(sleeper.pid));
  return { pid: sleeper.pid, release: async () => { try { sleeper.kill("SIGKILL"); } catch { /* gone */ } await sleeper.status; } };
};

Deno.test("a learned evaluation claims cue memory and cores, weight 0 in the pool, its parallelism capped by GOMAXPROCS", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 3);
  await prime(dir, ["export", "./spec"], 4);
  const w = start(dir, ["export", "./spec"], poolEnv);
  const [record] = await until(async () => { const j = await jobs(dir); return j.length ? j : undefined; }, "the claim's record");
  assertMatch(record, /^[0-9]+ 0 cue mem=2\.5 cores=4$/);
  const r = await w.done;
  assertEquals(r.code, 0);
  assertMatch(r.stderr, /slot: cue \.: weight 0 of 6 \(cue memory [0-9.]+ GB, [0-9.]+ cores\)/);
  assertMatch(r.stdout, /gomaxprocs 6\n/, "its parallelism is capped at the cap (the budget here, under CUE_MAX_CORES)");
});

Deno.test("GOMAXPROCS is the cap whatever is learned; a set GOMAXPROCS stays", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  // Learned at 5 cores, or never seen: the cap (the budget here, under CUE_MAX_CORES).
  await prime(dir, ["export", "./a"], 5);
  assertMatch((await run(dir, ["export", "./a"], poolEnv)).stdout, /gomaxprocs 6\n/, "learned under the cap: the cap");
  const unseen = await run(dir, ["export", "./b"], { ...poolEnv, CUE_UNKNOWN_GB: "1" });
  assertMatch(unseen.stderr, /weight 0 of 6 \(cue memory [0-9.]+ GB, [0-9.]+ cores\)/);
  assertMatch(unseen.stdout, /gomaxprocs 6\n/, "never seen: the cap");
  // The cap is the smaller of CUE_MAX_CORES and the budget, whatever was learned.
  await prime(dir, ["export", "./big"], 40);
  const big = await run(dir, ["export", "./big"], { ...poolEnv, CUE_MAX_CORES: "3" });
  assertMatch(big.stderr, /weight 0 of 6/);
  assertMatch(big.stdout, /gomaxprocs 3\n/);
  const set = await run(dir, ["export", "./big"], { ...poolEnv, GOMAXPROCS: "2" });
  assertMatch(set.stdout, /gomaxprocs 2\n/, "a GOMAXPROCS already set stays");
});

Deno.test("an evaluation is admitted while the pool's weight is full, and waits only for cue memory", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 3);
  await prime(dir, ["export", "./spec"], 3);
  // A holder of the whole budget (a runner job, admitted outside it, or a gate) does not block the cue.
  const holder = await hold(dir, 6);
  try {
    const r = await run(dir, ["export", "./spec"], poolEnv);
    assertEquals(r.code, 0);
    assertMatch(r.stderr, /weight 0 of 6 \(cue memory [0-9.]+ GB, [0-9.]+ cores\)/);
    assert.ok(!/waiting:/.test(r.stderr), "it did not wait for the holder's weight");
    assertMatch(r.stdout, /^real cue export \.\/spec/);
  } finally {
    await holder.release();
  }
  // Two evaluations of 2.5 GB each beside a 4 GB budget: the second waits for the first, holding nothing.
  await prime(dir, ["export", "./one"], 3);
  await prime(dir, ["export", "./two"], 3);
  await fake(dir, 0, 8);
  const small = { ...poolEnv, CUE_MEM_GB: "4" };
  const first = start(dir, ["export", "./one"], small);
  await until(async () => (await jobs(dir)).some((j) => / cue mem=/.test(j)) ? true : undefined, "the first holds its memory");
  const second = start(dir, ["export", "./two"], small);
  await until(async () => (await names(`${dir}/pool/cue-queue`)).length ? true : undefined, "the second waits in the cue line");
  assertEquals((await jobs(dir)).filter((j) => / cue mem=/.test(j)).length, 1, "it holds nothing while it waits");
  const [a, b] = await Promise.all([first.done, second.done]);
  assertEquals([a.code, b.code], [0, 0]);
  assertMatch(b.stderr, /waiting: .*cue memory: 2\.5 of 4 GB held/);
});

Deno.test("an evaluation inside a holder weighs none, and adds none to the pool", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 3);
  await prime(dir, ["export", "./spec"], 4);
  const holder = await hold(dir, 3);
  try {
    const w = start(dir, ["export", "./spec"], { ...poolEnv, STACK_JOB: String(holder.pid) });
    const both = await until(async () => { const j = await jobs(dir); return j.length === 2 ? j : undefined; }, "both records");
    const total = both.reduce((n, r) => n + Number(r.split(" ")[1]), 0);
    assertEquals(total, 3, "the pool's weight stays the holder's");
    assert.ok(both.some((r) => / 0 cue mem=2\.5 cores=4 in=/.test(r) && r.endsWith(` in=${holder.pid}`)), both.join("; "));
    const r = await w.done;
    assertMatch(r.stderr, new RegExp(`weight 0 of 6 \\(inside ${holder.pid}: admitted at once, within its weight\\) \\(cue memory`));
  } finally {
    await holder.release();
  }
});

Deno.test("a cue inside a holder is not stuck behind a cue that waits for that holder", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  const slot = await Deno.stat(`${runtime}/cue-budget/slot.ts`).then(() => `${runtime}/cue-budget/slot.ts`, () => `${runtime}/slot.ts`);
  // H holds the whole pool and, after a while, runs a cue of its own (a gate's generate); a top-level cue
  // asked for the lock before that, and so is older in the line.
  const h = new Deno.Command(`${deno}/deno`, {
    args: ["run", "-A", "--no-config", "--no-lock", slot, "--weight", "6", "--what", "H", "--", "sh", "-c", `sleep 3; "${wrapper}" export ./nested`],
    cwd: dir, env: envOf(dir, poolEnv), clearEnv: true, stdin: "null", stdout: "piped", stderr: "piped",
  }).spawn();
  const hDone = h.output();
  await until(async () => (await jobs(dir)).length ? true : undefined, "H's claim");
  const top = start(dir, ["export", "./top"], { ...poolEnv, CUE_UNKNOWN_GB: "1" });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const done = await Promise.race([Promise.all([hDone, top.done]).then(() => true), new Promise<boolean>((r) => (timer = setTimeout(() => r(false), 40_000)))]);
  clearTimeout(timer);
  if (!done) {
    for (const c of [h, top.child]) try { c.kill("SIGKILL"); } catch { /* gone */ }
    await hDone.catch(() => {});
    assert.fail("the nested cue waited behind the top-level one, which waited for H: a deadlock");
  }
  const [hr, tr] = await Promise.all([hDone, top.done]);
  assertEquals([hr.code, tr.code], [0, 0]);
  assertMatch(text(hr.stdout), /real cue export \.\/nested/);
  assertMatch(tr.stdout, /real cue export \.\/top/);
});

// A fake cue that spins two workers for `s` seconds, as a large evaluation does, and notes the cores it really
// kept busy (its CPU seconds over its seconds, ${dir}/self): a loaded machine gives it fewer than two.
const spinner = async (dir: string, s: number) => {
  await Deno.mkdir(`${dir}/bin`, { recursive: true });
  await Deno.writeTextFile(`${dir}/bin/cue`, `#!/bin/sh
exec "${deno}/deno" eval 'const src = "const t = Date.now(); while (Date.now() - t < ${s * 1000}) {}"; const u = URL.createObjectURL(new Blob([src], { type: "text/javascript" })); for (let i = 0; i < 2; i++) new Worker(u, { type: "module" }); await new Promise((r) => setTimeout(r, ${s * 1000 + 200})); const c = Deno.cpuUsage(); Deno.writeTextFileSync("${dir}/self", ((c.user + c.system) / 1e6 / (performance.now() / 1000)).toFixed(2)); Deno.exit(0)'
`);
  await Deno.chmod(`${dir}/bin/cue`, 0o755);
};
const coresOf = async (dir: string) => Number((await Deno.readTextFile(`${dir}/.cache/pronto/cue-mem/${await learnedName(dir)}.cores`)).trim());
const selfOf = async (dir: string) => Number(await Deno.readTextFile(`${dir}/self`));

Deno.test("the cores an evaluation kept busy are learned, from slot.ts when claimed and from time when run at once", async () => {
  // Claimed: an evaluation of 6 s that keeps two cores busy learns about 2.
  const claimed = await Deno.makeTempDir();
  await spinner(claimed, 6);
  assertEquals((await run(claimed, ["export", "./spec"], { CUE_UNKNOWN_GB: "1" })).code, 0);
  const c = await coresOf(claimed);
  assert.ok(c > 0 && Math.abs(c - await selfOf(claimed)) < 0.6, `learned ${c} cores for a cue that kept ${await selfOf(claimed)} busy`);
  // At once (learned small, outside the pool): the same, from time's CPU and wall seconds.
  const direct = await Deno.makeTempDir();
  await spinner(direct, 6);
  assertEquals((await run(direct, ["export", "./spec"], { CUE_UNKNOWN_GB: "0" })).code, 0);
  const d = await coresOf(direct);
  assert.ok(d > 0 && Math.abs(d - await selfOf(direct)) < 0.6, `learned ${d} cores from time for a cue that kept ${await selfOf(direct)} busy`);
  // Learned at 2 cores and 30 CPU seconds, it is claimed though it held under CUE_DIRECT_GB.
  const name = await learnedName(direct);
  await Deno.writeTextFile(`${direct}/.cache/pronto/cue-mem/${name}.cores`, "2.5\n");
  await Deno.writeTextFile(`${direct}/.cache/pronto/cue-mem/${name}.secs`, "40\n");
  assertMatch((await run(direct, ["export", "./spec"])).stderr, /slot: cue \./);
  // A run under 5 s teaches nothing.
  const quick = await Deno.makeTempDir();
  await fake(quick);
  await run(quick, ["export", "./spec"], { CUE_UNKNOWN_GB: "1" });
  assertEquals((await Array.fromAsync(Deno.readDir(`${quick}/.cache/pronto/cue-mem`))).filter((e) => e.isFile && e.name.endsWith(".cores")).length, 0);
});

Deno.test("a cue found only as a mise shim is started again through mise exec, once", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await Deno.mkdir(`${dir}/mise/shims`, { recursive: true });
  await Deno.mkdir(`${dir}/stub`);
  await Deno.writeTextFile(`${dir}/mise/shims/cue`, "#!/bin/sh\necho shim; exit 9\n");
  // mise exec: the PATH mise builds (the machine's folder, the tool's cue), then the command.
  await Deno.writeTextFile(`${dir}/stub/mise`, `#!/bin/sh
echo "$CUE_BUDGET_VIA_MISE" >> "${dir}/mise-calls"
[ "$1" = exec ] && shift
[ "$1" = -- ] && shift
PATH="${runtime}:${dir}/bin:${deno}:/usr/bin:/bin:/usr/sbin:/sbin" exec "$@"
`);
  for (const f of [`${dir}/mise/shims/cue`, `${dir}/stub/mise`]) await Deno.chmod(f, 0o755);
  const r = await run(dir, ["export", "./spec"], { PATH: `${runtime}:${dir}/mise/shims:${dir}/stub:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, CUE_UNKNOWN_GB: "1" });
  assertEquals(r.code, 0);
  assertMatch(r.stdout, /^real cue export \.\/spec/);
  assertEquals((await Deno.readTextFile(`${dir}/mise-calls`)).trim(), "1", "one mise exec, marked");
  // With the marker already set, a mise that did not help is not asked again.
  const again = await run(dir, ["export", "./spec"], { PATH: `${runtime}:${dir}/mise/shims:${dir}/stub:${deno}:/usr/bin:/bin:/usr/sbin:/sbin`, CUE_BUDGET_VIA_MISE: "1" });
  assertEquals(again.code, 127);
  assertMatch(again.stderr, /no cue on PATH/);
});

Deno.test("the watchdog slows a cue outside the pool that keeps many cores busy for two passes, and never one under a holder", async () => {
  const dir = await Deno.makeTempDir();
  const watchdog = new URL("../watchdog.sh", import.meta.url).pathname;
  // Three workers spinning: ~300 % CPU on an idle machine, over the 30 % this test asks for on a loaded one. Its parent is this test, which stands in for a pool holder in the second half.
  const spin = new Deno.Command(`${deno}/deno`, {
    args: ["eval", 'const u = URL.createObjectURL(new Blob(["const t = Date.now(); while (Date.now() - t < 12000) {}"], { type: "text/javascript" })); for (let i = 0; i < 3; i++) new Worker(u, { type: "module" }); await new Promise((r) => setTimeout(r, 12200)); Deno.exit(0)'],
    stdout: "null", stderr: "null",
  }).spawn();
  try {
    await new Promise((r) => setTimeout(r, 2500));
    const pass = async (state: string, pools: string) => {
      const o = await new Deno.Command("bash", {
        args: [watchdog],
        env: { HOME: dir, CUE_WATCHDOG_MAX_GB: "100000", CUE_WATCHDOG_LEVEL: "100", CUE_WATCHDOG_SWAP_GB_NOW: "0", CUE_WATCHDOG_NAME: "deno", CUE_WATCHDOG_ONLY_PIDS: String(spin.pid), CUE_WATCHDOG_DRY: "1", CUE_WATCHDOG_HOT_PCT: "30", CUE_WATCHDOG_LOG: `${dir}/log`, CUE_WATCHDOG_DIR: `${dir}/${state}`, CUE_WATCHDOG_POOLS: pools },
        clearEnv: true, stdout: "piped", stderr: "piped",
      }).output();
      assertEquals(o.code, 0, text(o.stderr));
      return await Deno.readTextFile(`${dir}/log`).catch(() => "");
    };
    assertEquals(await pass("a", `${dir}/none`), "", "hot for one pass: nothing yet");
    assertMatch(await pass("a", `${dir}/none`), /would slow pid=[0-9]+ .*reason=hot cpu=[0-9.]+%/, "hot for two: slowed, logged like a kill");
    const once = await pass("a", `${dir}/none`);
    assertEquals(once.split("\n").filter(Boolean).length, 1, "once, not every pass");
    // Under a live pool holder (the process above it): admitted by the budget, left alone.
    await Deno.mkdir(`${dir}/pool/job-${Deno.pid}`, { recursive: true });
    await Deno.writeTextFile(`${dir}/pool/job-${Deno.pid}/pid`, String(Deno.pid));
    await pass("b", `${dir}/pool`);
    assertEquals((await pass("b", `${dir}/pool`)).split("\n").filter(Boolean).length, 1, "a cue under a holder is never slowed");
  } finally {
    try { spin.kill("SIGKILL"); } catch { /* gone */ }
    await spin.status;
  }
});

const slotPath = await Deno.stat(`${runtime}/cue-budget/slot.ts`).then(() => `${runtime}/cue-budget/slot.ts`, () => `${runtime}/slot.ts`);
const names = async (d: string) => { try { return (await Array.fromAsync(Deno.readDir(d))).map((e) => e.name).sort(); } catch { return []; } };

Deno.test("queued top-level cues wait in the cue line only, reserving no cores in the pool's line", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 6);
  for (const k of ["a", "b", "c"]) await prime(dir, ["export", `./${k}`], 7);
  const env = { STACK_BUDGET: "8" };
  const procs: { child: Deno.ChildProcess; done: Promise<{ code: number; stdout: string; stderr: string }> }[] = [];
  try {
    for (const k of ["a", "b", "c"]) { procs.push(start(dir, ["export", `./${k}`], env)); await new Promise((r) => setTimeout(r, 300)); }
    await until(async () => (await names(`${dir}/pool/cue-queue`)).length >= 1 ? true : undefined, "a cue waiting in the cue line");
    assertEquals(await names(`${dir}/pool/queue`), [], "no cue reserves cores");
    // A job beside them is not held back by the cues: the pool's weight is its own.
    const job = await new Deno.Command(`${deno}/deno`, { args: ["run", "-A", "--no-config", "--no-lock", slotPath, "--weight", "8", "--what", "job", "--", "true"], cwd: dir, env: envOf(dir, env), clearEnv: true, stdout: "piped", stderr: "piped" }).output();
    assertEquals(job.code, 0);
    assert.ok(!/waiting:/.test(text(job.stderr)), text(job.stderr));
    const results = await Promise.all(procs.map((p) => p.done));
    assertEquals(results.map((r) => r.code), [0, 0, 0]);
  } finally {
    for (const p of procs) try { p.child.kill("SIGKILL"); } catch { /* done */ }
  }
});

Deno.test("a cue inside a holder, through a slot.ts from before the -w tickets, is not made to wait behind a top-level one", async () => {
  const dir = await Deno.makeTempDir();
  const root = new URL("../..", import.meta.url).pathname;
  // A copy from before the -w tickets: this one with the ticket pattern every earlier copy has (ci's checkout is
  // shallow, so no older commit is there to read).
  const current = await Deno.readTextFile(`${root}/harness/files/tests/slot.ts`);
  const old = current.replace("/^[0-9]+-([0-9]+)(?:-w)?$/", "/^[0-9]+-([0-9]+)$/");
  assert(old !== current, "the ticket pattern is where the old copy differs");
  await Deno.mkdir(`${dir}/old/tests`, { recursive: true });
  await Deno.writeTextFile(`${dir}/old/tests/slot.ts`, old);
  const holder = await hold(dir, 3);
  try {
    // A top-level cue waiting in the cue line: older than the claim below, live, and named as a new one names it.
    await Deno.mkdir(`${dir}/pool/cue-queue`, { recursive: true });
    await Deno.writeTextFile(`${dir}/pool/cue-queue/000000000000001-${holder.pid}-w`, "7 cue waiting");
    for (const copy of [`${dir}/old/tests/slot.ts`, slotPath]) {
      const child = new Deno.Command(`${deno}/deno`, {
        args: ["run", "-A", "--no-config", "--no-lock", copy, "--mem", "1", "--what", "nested", "--", "true"],
        cwd: dir, env: envOf(dir, { STACK_BUDGET: "6", STACK_JOB: String(holder.pid) }), clearEnv: true, stdout: "piped", stderr: "piped",
      }).spawn();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const out = child.output();
      const done = await Promise.race([out.then(() => true), new Promise<boolean>((r) => (timer = setTimeout(() => r(false), 30_000)))]);
      clearTimeout(timer);
      if (!done) { child.kill("SIGKILL"); await out; assert.fail(`${copy} waited behind the top-level ticket`); }
      assertEquals((await out).code, 0, copy);
    }
  } finally {
    await holder.release();
  }
});

Deno.test("a partial vet does not teach its key's cores", async () => {
  const dir = (await Deno.makeTempDir()) + "/m";
  await Deno.mkdir(dir);
  await fake(dir);
  await Deno.mkdir(`${dir}/cue.mod`, { recursive: true });
  await Deno.writeTextFile(`${dir}/cue.mod/module.cue`, `module: "t.example/m@v0"\nlanguage: version: "v0.16.0"\n`);
  for (const p of ["a", "b"]) await Deno.mkdir(`${dir}/${p}`);
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 1\n`);
  await Deno.writeTextFile(`${dir}/b/b.cue`, `package b\ny: 1\n`);
  const vet = () => run(dir, ["vet", "-c", "./..."], { CUE_DIRECT_GB: "0", CUE_UNKNOWN_GB: "0.1" });
  assertEquals((await vet()).code, 0);
  await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${await learnedName(dir)}.cores`, "5\n");
  await Deno.writeTextFile(`${dir}/a/a.cue`, `package a\nx: 2\n`);
  const partial = await vet();
  assertMatch(partial.stderr, /packages? passed before/);
  assertEquals(await Deno.readTextFile(`${dir}/.cache/pronto/cue-mem/${await learnedName(dir)}.cores`), "5\n", "a part of the vet does not teach its key's cores");
});

// The cue memory budget (PRONTO-870): several evaluations at once while their claims fit, strictly first come first
// served, and a record or ticket from before the budget claims all of it. The fake cue notes `s <args> <epoch>` and
// `e <args> <epoch>` in <dir>/times; a case reads when each began and ended.
const times = async (dir: string) => {
  const t: Record<string, { s?: number; e?: number }> = {};
  for (const l of (await Deno.readTextFile(`${dir}/times`).catch(() => "")).split("\n").filter(Boolean)) {
    const [k, ...rest] = l.split(" ");
    const at = Number(rest.pop());
    const id = rest.join(" ");
    (t[id] ??= {})[k as "s" | "e"] = at;
  }
  return t;
};
const live = async (dir: string) => (await jobs(dir)).filter((j) => / cue mem=/.test(j));
// A holder of the pool with the record `body` (after its pid): a live process, as a wrapper's slot.ts would be.
const holdRecord = async (dir: string, body: string) => {
  const h = await hold(dir, 0);
  await Deno.writeTextFile(`${dir}/pool/job-${h.pid}/weight`, `${h.pid} ${body}`);
  return h;
};
const cueEnv = { ...poolEnv, CUE_CORES: "10" };

Deno.test("two 3 GB evaluations overlap", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 8);
  await prime(dir, ["export", "./a"], 2, 3);
  await prime(dir, ["export", "./b"], 2, 3);
  const a = start(dir, ["export", "./a"], cueEnv);
  const b = start(dir, ["export", "./b"], cueEnv);
  const [ra, rb] = await Promise.all([a.done, b.done]);
  assertEquals([ra.code, rb.code], [0, 0]);
  assert.ok(!/waiting:/.test(ra.stderr + rb.stderr), "neither waited");
  const t = await times(dir);
  const sa = t["export ./a"].s!, ea = t["export ./a"].e!, sb = t["export ./b"].s!, eb = t["export ./b"].e!;
  assert.ok(sa < eb && sb < ea, `their runs interleave: a ${sa}-${ea}, b ${sb}-${eb}`);
});

Deno.test("a 20 GB claim waits beside a 20 GB holder under CUE_MEM_GB=30", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 5);
  await prime(dir, ["export", "./a"], 2, 16);
  await prime(dir, ["export", "./b"], 2, 16);
  const env = { ...cueEnv, CUE_MEM_GB: "30" };
  const a = start(dir, ["export", "./a"], env);
  await until(async () => (await live(dir)).length ? true : undefined, "the first holds 20 GB");
  const b = start(dir, ["export", "./b"], env);
  await until(async () => (await names(`${dir}/pool/cue-queue`)).length ? true : undefined, "the second waits");
  const [ra, rb] = await Promise.all([a.done, b.done]);
  assertEquals([ra.code, rb.code], [0, 0]);
  assertMatch(rb.stderr, /waiting: .*cue memory: 20 of 30 GB held/);
  const t = await times(dir);
  assert.ok(t["export ./b"].s! >= t["export ./a"].e!, "it began when the first ended");
});

Deno.test("a small claim waits behind a reserved large one", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 5);
  await prime(dir, ["export", "./a"], 2, 16);
  await prime(dir, ["export", "./b"], 2, 16);
  await prime(dir, ["export", "./c"], 2, 2);
  const env = { ...cueEnv, CUE_MEM_GB: "30" };
  const a = start(dir, ["export", "./a"], env);
  await until(async () => (await live(dir)).length ? true : undefined, "A holds 20 GB");
  const b = start(dir, ["export", "./b"], env);
  await until(async () => (await names(`${dir}/pool/cue-queue`)).length >= 1 ? true : undefined, "B waits for the memory");
  // C's 2.5 GB would fit beside A's 20 GB, but B ahead of it reserves 20: it waits, whatever its size.
  const c = start(dir, ["export", "./c"], env);
  await until(async () => (await names(`${dir}/pool/cue-queue`)).length >= 2 ? true : undefined, "C waits behind B");
  const [ra, rb, rc] = await Promise.all([a.done, b.done, c.done]);
  assertEquals([ra.code, rb.code, rc.code], [0, 0, 0]);
  assertMatch(rc.stderr, /waiting: .*cue memory: 20 of 30 GB held, 20 reserved by those ahead/);
  const t = await times(dir);
  assert.ok(t["export ./c"].s! >= t["export ./a"].e!, "C did not pass B while A held its memory");
});

Deno.test("a legacy holder record or ticket blocks like the lock", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 1);
  await prime(dir, ["export", "./a"], 2, 2);
  // A record of a slot.ts from before the budget, `cue` alone: it holds the whole budget.
  const holder = await holdRecord(dir, "0 cue");
  try {
    const w = start(dir, ["export", "./a"], cueEnv);
    await until(async () => (await names(`${dir}/pool/cue-queue`)).length ? true : undefined, "it waits behind the legacy holder");
    await new Promise((r) => setTimeout(r, 1500));
    assertEquals((await live(dir)).length, 0, "it is not admitted beside the legacy holder");
    await holder.release();
    const r = await w.done;
    assertEquals(r.code, 0);
    assertMatch(r.stderr, /waiting: .*cue memory: 64 of 64 GB held/);
  } finally {
    await holder.release();
  }
  // A ticket without mem= reserves the whole budget, too. (The run above measured its peak again: set to 2 GB again.)
  await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${await learnedName(dir)}`, "2 cue export ./a\n");
  const owner = await hold(dir, 0);
  try {
    await Deno.mkdir(`${dir}/pool/cue-queue`, { recursive: true });
    await Deno.writeTextFile(`${dir}/pool/cue-queue/000000000000001-${owner.pid}`, "0 cue waiting");
    const w = start(dir, ["export", "./a"], cueEnv);
    await until(async () => (await names(`${dir}/pool/cue-queue`)).length >= 2 ? true : undefined, "it waits behind the legacy ticket");
    await new Promise((r) => setTimeout(r, 1500));
    assertEquals((await live(dir)).length, 0, "it is not admitted ahead of the legacy ticket");
    await owner.release();
    const r = await w.done;
    assertEquals(r.code, 0);
    assertMatch(r.stderr, /waiting: .*64 reserved by those ahead/);
  } finally {
    await owner.release();
  }
});

Deno.test("a dead holder frees its memory", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await prime(dir, ["export", "./a"], 2, 2);
  const holder = await holdRecord(dir, "0 cue mem=64 cores=2");
  const w = start(dir, ["export", "./a"], cueEnv);
  await until(async () => (await names(`${dir}/pool/cue-queue`)).length ? true : undefined, "it waits for the holder's 64 GB");
  await new Promise((r) => setTimeout(r, 2000));
  await holder.release();
  const r = await w.done;
  assertEquals(r.code, 0);
  assertMatch(r.stderr, /waiting: .*cue memory: 64 of 64 GB held/);
  assertMatch(r.stderr, /weight 0 of 6 \(cue memory 2\.5 GB/, "admitted once the holder was dead");
});

Deno.test("the cores of the claims add up too", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 4);
  await prime(dir, ["export", "./a"], 4, 2);
  await prime(dir, ["export", "./b"], 4, 2);
  const env = { ...cueEnv, CUE_CORES: "6" };
  const a = start(dir, ["export", "./a"], env);
  await until(async () => (await live(dir)).length ? true : undefined, "A claims 4 of 6 cores");
  const b = start(dir, ["export", "./b"], env);
  const [ra, rb] = await Promise.all([a.done, b.done]);
  assertEquals([ra.code, rb.code], [0, 0]);
  assertMatch(rb.stderr, /waiting: .*cue cores: 4 of 6 claimed/);
  // The cache log's 7th column is the seconds waited: B's wait, inside its seconds taken (the 5th).
  const lines = (await Deno.readTextFile(`${dir}/.cache/pronto/cue-cache.log`)).split("\n").filter(Boolean).map((l) => l.split("\t"));
  assert.ok(lines.length >= 4, "the two primings and the two runs");
  lines.splice(0, lines.length - 2);
  assert.ok(lines.every((f) => f.length === 7), "seven columns");
  const waited = Math.max(...lines.map((f) => Number(f[6])));
  assert.ok(waited >= 3 && lines.some((f) => Number(f[6]) === waited && Number(f[4]) >= waited), `B waited ${waited} s of its own`);
});

Deno.test("the budget's rules: memAdmits, weightOf, the veto and a stuck holder", async () => {
  const slot = await import(new URL("../../harness/files/tests/slot.ts", import.meta.url).href);
  const { memAdmits, weightOf, vetoed, stuck } = slot;
  // The oldest ticket is admitted on an empty pool whatever it claims; otherwise held + ahead + claim fit.
  assertEquals(memAdmits(0, 0, 100, 64), true);
  assertEquals(memAdmits(20, 0, 20, 30), false);
  assertEquals(memAdmits(10, 0, 20, 30), true);
  assertEquals(memAdmits(0, 20, 20, 30), false, "tickets ahead reserve their room");
  assertEquals(memAdmits(0, 20, 5, 30), true);
  // A cue record without mem= claims the whole budget, no cores; one with it, what it says.
  assertEquals(weightOf("7 0 cue", 7, 64), { weight: 0, cue: true, mem: 64, cores: 0 });
  assertEquals(weightOf("7 0 cue mem=2.5 cores=4 in=3", 7, 64), { weight: 0, cue: true, mem: 2.5, cores: 4 });
  assertEquals(weightOf("7 2 mem=9", 7, 64), { weight: 2, cue: true, mem: 9, cores: 0 });
  assertEquals(weightOf("7 3", 7, 64), { weight: 3, cue: false, mem: 0, cores: 0 });
  assertEquals(weightOf("8 0 cue mem=2", 7, 64), { weight: 1, cue: false, mem: 0, cores: 0 }, "another pid's record is not this holder's");
  // The veto spares the head of the line on a pool holding no cue memory.
  assertEquals(vetoed(15, 20, false), true);
  assertEquals(vetoed(15, 20, true), false);
  assertEquals(vetoed(40, 20, false), false);
  assertEquals(vetoed(null, 20, false), false);
  // A holder whose child died more than 60 s ago holds nothing.
  assertEquals(stuck(0, 1e9), false);
  assertEquals(stuck(1e9 - 30_000, 1e9), false);
  assertEquals(stuck(1e9 - 61_000, 1e9), true);
});

Deno.test("a top-level cue that weighs cores holds its place on the cores' line while cue holders run beside it", async () => {
  const dir = await Deno.makeTempDir();
  await Deno.mkdir(`${dir}/pool`, { recursive: true });
  // A cue holder (so the old "no cue runs" condition is false) and a holder of the whole weight budget.
  const cueHolder = await holdRecord(dir, "0 cue mem=1 cores=1");
  const full = await hold(dir, 6);
  const env = { ...envOf(dir, poolEnv), CUE_MEM_GB: "64", CUE_CORES: "10" };
  const job = new Deno.Command(`${deno}/deno`, { args: ["run", "-A", "--no-config", "--no-lock", slotPath, "--weight", "2", "--mem", "1", "--cores-claim", "1", "--what", "dual", "--", "true"], cwd: dir, env, clearEnv: true, stdout: "piped", stderr: "piped" }).spawn();
  const done = job.output();
  try {
    const ticket = await until(async () => (await names(`${dir}/pool/queue`)).find((n) => /^[0-9]+-[0-9]+$/.test(n)), "its ticket on the cores' line");
    assert.ok(ticket.endsWith(`-${job.pid}`), `the ticket is the claim's: ${ticket}`);
    await full.release();
    const out = await done;
    assertEquals(out.code, 0, text(out.stderr));
  } finally {
    await full.release();
    await cueHolder.release();
    try { job.kill("SIGKILL"); } catch { /* done */ }
  }
});

Deno.test("an unknown id in a folder that only ran tiny evaluations still claims CUE_UNKNOWN_GB", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 64);
  const first = await run(dir, ["export", "./a"], { CUE_UNKNOWN_GB: "1" });
  assertEquals(first.code, 0);
  const folder = `${dir}/.cache/pronto/cue-mem/folder`;
  assert.ok((await names(folder)).length === 1, "the folder's peak was noted");
  assert.ok(Number((await Deno.readTextFile(`${folder}/${(await names(folder))[0]}`)).trim()) < 1, "and it is tiny");
  const second = await run(dir, ["export", "./b"], { CUE_UNKNOWN_GB: "3" });
  assertEquals(second.code, 0);
  assertMatch(second.stderr, /cue memory 3 GB/, "the folder's peak only raises the claim");
});

Deno.test("a ticket with an empty mem= reserves the whole budget, not nothing", async () => {
  const dir = await Deno.makeTempDir();
  await fake(dir, 0, 1);
  await prime(dir, ["export", "./a"], 2, 2);
  const owner = await hold(dir, 0);
  try {
    await Deno.mkdir(`${dir}/pool/cue-queue`, { recursive: true });
    await Deno.writeTextFile(`${dir}/pool/cue-queue/000000000000001-${owner.pid}`, "0 mem= cores=0 broken");
    const w = start(dir, ["export", "./a"], cueEnv);
    await until(async () => (await names(`${dir}/pool/cue-queue`)).length >= 2 ? true : undefined, "it waits behind the ticket");
    await new Promise((r) => setTimeout(r, 1500));
    assertEquals((await live(dir)).length, 0, "it is not admitted ahead of a ticket whose mem= is empty");
    await owner.release();
    const r = await w.done;
    assertEquals(r.code, 0);
    assertMatch(r.stderr, /64 reserved by those ahead/);
  } finally {
    await owner.release();
  }
});

Deno.test("CUE_MIN_FREE_PCT vetoes a second claim beside a cue holder, and spares the head of an empty pool", async () => {
  if (Deno.build.os !== "darwin") return; // the veto reads kern.memorystatus_level
  const dir = await Deno.makeTempDir();
  await fake(dir);
  await prime(dir, ["export", "./a"], 2, 2);
  const veto = { ...cueEnv, CUE_MIN_FREE_PCT: "101" };
  // The head of an empty pool is admitted whatever the machine has free.
  const lone = await run(dir, ["export", "./a"], veto);
  assertEquals(lone.code, 0, lone.stderr);
  assert.ok(!/waiting:/.test(lone.stderr), "the head of an empty pool did not wait");
  await Deno.writeTextFile(`${dir}/.cache/pronto/cue-mem/${await learnedName(dir)}`, "2 cue export ./a\n");
  // With a cue holder, the memory fits but the veto holds the claim until the holder ends.
  const holder = await holdRecord(dir, "0 cue mem=1 cores=1");
  try {
    const w = start(dir, ["export", "./a"], veto);
    await until(async () => (await names(`${dir}/pool/cue-queue`)).length ? true : undefined, "it waits in the cue line");
    await new Promise((r) => setTimeout(r, 1500));
    assertEquals((await live(dir)).filter((j) => !j.includes(" mem=1 ")).length, 0, "it is not admitted beside the holder");
    await holder.release();
    const r = await w.done;
    assertEquals(r.code, 0);
    assertMatch(r.stderr, /waiting: .*of its memory free, under 101%/);
  } finally {
    await holder.release();
  }
});
