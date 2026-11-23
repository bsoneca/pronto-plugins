// The harness's flake filing (harness/files/tests/scenarios/flakes.ts) on a fake board: one that
// refuses, one that is missing, one that files. Each call is one filing into a fresh marks folder.
import { fileFlake } from "../../harness/files/tests/scenarios/flakes.ts";
import { lockArgs } from "../../harness/files/tests/unit/select.js";

// The unit runner's lock flags (UNIT_LOCK, PRONTO-973), and what deno does with them: `deno info` on a module importing one
// served here on 127.0.0.1 (no registry, a fresh DENO_DIR), against a lock that names nothing, with the flags lockArgs
// gives, and without any.
export const lockFlags = (lock) => lockArgs(lock);
export async function lockHonoured() {
  const ac = new AbortController();
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0, signal: ac.signal, onListen() {} }, () => new Response("export const x = 1;\n", { headers: { "content-type": "application/typescript" } }));
  const served = `http://127.0.0.1:${server.addr.port}/x.ts`;
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/m.ts`, `import "${served}";\n`);
    await Deno.writeTextFile(`${dir}/deno.lock`, '{"version":"5"}\n');
    const info = (args) => new Deno.Command(Deno.execPath(), { args: ["info", "--no-config", "--allow-import=127.0.0.1", ...args, `${dir}/m.ts`], env: { DENO_DIR: `${dir}/cache` }, stdout: "piped", stderr: "piped" }).output();
    const frozen = await info(lockArgs(`${dir}/deno.lock`));
    const free = await info(lockArgs(undefined));
    const text = (b) => new TextDecoder().decode(b);
    return { frozen: frozen.success, said: text(frozen.stderr), free: free.success && text(free.stdout).includes(served) };
  } finally {
    ac.abort();
    await server.finished;
    await Deno.remove(dir, { recursive: true });
  }
}
// The scenario selector's rule for files outside the app (select.ts), called by the cases as harness.outsideConcerns.
import { outsideConcerns, outsideKeys as keys } from "../../harness/files/tests/scenarios/select.ts";
export { outsideConcerns };
// outsideKeys with a hash that is the file's name, so a case can name what it keys.
export const outsideKeys = (files, reads) => keys(files, (f) => `h:${f}`, reads);
export { declaredKeys, siblingsMoved } from "../../harness/files/tests/scenarios/select.ts";

// A scenario step's gate (harness/files/tests/scenarios/gate.ts) with a flagOn that records what it is asked and answers true.
import { stepGate } from "../../harness/files/tests/scenarios/gate.ts";
export async function gate(st, here) {
  const asked = [];
  const g = await stepGate(st, { kept: () => undefined, ...here }, (f) => { asked.push(f); return Promise.resolve(true); });
  return { run: g.run, asked };
}

async function filing(run, github = false) {
  const marks = await Deno.makeTempDir();
  const said = [];
  try {
    const r = await fileFlake({ id: "demo", cmd: "board", args: [], marks, run, github, say: (l) => said.push(l) }).then((r) => ({ threw: false, filed: r.filed, error: null }), (e) => ({ threw: true, filed: null, error: e.message }));
    const marker = await Deno.readTextFile(`${marks}/demo`).catch(() => null);
    return { ...r, marker, said };
  } finally { await Deno.remove(marks, { recursive: true }); }
}
export const refused = (github) => filing(() => Promise.resolve({ success: false, stdout: "", stderr: "Error: board said no\n    at async board.ts:19:21\n" }), github);
export const missing = () => filing(() => Promise.reject(new Deno.errors.NotFound("board: command not found")));
export const accepted = () => filing(() => Promise.resolve({ success: true, stdout: "noise\nPRONTO-700 https://board/PRONTO-700\n", stderr: "" }));
// A board that files, but a marks folder that cannot be made (a file stands where it would go).
export async function unmarked() {
  const blocker = await Deno.makeTempFile();
  const said = [];
  try {
    return await fileFlake({ id: "demo", cmd: "board", args: [], marks: `${blocker}/marks`, say: (l) => said.push(l), run: () => Promise.resolve({ success: true, stdout: "PRONTO-700\n", stderr: "" }) })
      .then((r) => ({ threw: false, filed: r.filed, said: said.length }), () => ({ threw: true, said: said.length }));
  } finally { await Deno.remove(blocker); }
}

// What a read-only production page's request becomes (scenarios/gate.ts's sentOf).
export { sentOf };
import { sentOf } from "../../harness/files/tests/scenarios/gate.ts";

// One step of a scenario held to the scenarios' schema (harness/files/tests/scenarios/schema.cue), with a gesture
// `play: {play: string, refused?: true}` declared as an app declares its own: the schema and the scenario copied to a
// fresh folder and evaluated by the cue on PATH (CUE, where set). The first line of what cue refused, or null.
const schema = new URL("../../harness/files/tests/scenarios/schema.cue", import.meta.url).pathname;
export async function stepRefused(step) {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.copyFile(schema, `${dir}/schema.cue`);
    await Deno.writeTextFile(`${dir}/app.cue`, `package scenarios\n#Gestures: {play: {play: string, refused?: true}}\nscenarios: t: {accepts: [], actors: {a: {name: "a"}}, steps: [${JSON.stringify(step)}]}\n`);
    const r = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["eval", "-e", "scenarios.t._checked", "."], cwd: dir, stdout: "null", stderr: "piped" }).output();
    return r.success ? null : new TextDecoder().decode(r.stderr).split("\n")[0];
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

// Steps of a scenario marked `production`, held to the schema the same way: the first line of what cue refused, or null.
export async function productionRefused(steps) {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.copyFile(schema, `${dir}/schema.cue`);
    await Deno.writeTextFile(`${dir}/app.cue`, `package scenarios\n#Gestures: {}\nscenarios: t: {accepts: [], production: true, actors: {}, steps: ${JSON.stringify(steps)}}\n`);
    const r = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["vet", "-c", "."], cwd: dir, stdout: "null", stderr: "piped" }).output();
    return r.success ? null : new TextDecoder().decode(r.stderr).split("\n")[0];
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

// siblingFiles on a small repository of two apps: the sibling's brief.md committed, then edited and staged, then committed.
// Each step reports the blob siblingFiles keys the brief by and the blob HEAD and the index hold for it.
import { siblingFiles } from "../../harness/files/tests/scenarios/select.ts";
export async function siblingStaged() {
  const dir = Deno.realPathSync(await Deno.makeTempDir()); // real path, so the run keeps its scratch as its own
  const git = async (...a) => new TextDecoder().decode((await new Deno.Command("git", { args: ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", ...a], stdout: "piped", stderr: "null" }).output()).stdout).trim();
  const keyed = () => Object.fromEntries(siblingFiles(`${dir}/apps/studio`) ?? [])["../other/brief.md"];
  try {
    await git("init", "-q");
    await Deno.mkdir(`${dir}/apps/studio`, { recursive: true });
    await Deno.mkdir(`${dir}/apps/other`, { recursive: true });
    await Deno.writeTextFile(`${dir}/apps/studio/a.ts`, "a");
    await Deno.writeTextFile(`${dir}/apps/other/brief.md`, "one");
    await git("add", "-A"); await git("commit", "-qm", "one");
    const committed = await git("rev-parse", "HEAD:apps/other/brief.md");
    const first = keyed();
    await Deno.writeTextFile(`${dir}/apps/other/brief.md`, "two");
    await git("add", "-A");
    const staged = keyed();
    await git("commit", "-qm", "two");
    const after = keyed();
    const head = await git("rev-parse", "HEAD:apps/other/brief.md");
    return { firstIsHead: first === committed, stagedIsHead: staged === committed, afterIsNewHead: after === head && after !== committed };
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

// The run guard of the shared tests/lint.ts (PRONTO-867): the largest argument of every RUN, CMD,
// ENTRYPOINT and HEALTHCHECK of a Dockerfile, as BuildKit joins them. `sizes` keeps what a case reads.
import { argSizes, heaviest } from "../../harness/files/tests/lint.ts";
export const sizes = (dockerfile) => argSizes(dockerfile, "Dockerfile.x").map((a) => [a.line, a.instruction, a.bytes]);
// A RUN of `n` bytes of one install -D chain, the shape pronto emits for a served image: its size and heaviest folders.
export function served(files) {
  const run = "RUN set -e; " + files.map(([dir, name]) => `install -D -m 644 '/src/${dir}${name}' '/served/${dir}${name}'`).join("; ");
  return { bytes: argSizes(run)[0].bytes, heaviest: heaviest(run.slice(4), 2) };
}
// One RUN of exactly `n` bytes after its keyword.
export const ofSize = (n) => argSizes("RUN " + "x".repeat(n)).map((a) => a.bytes);
// A RUN heredoc whose body is `n` bytes.
export const ofHeredoc = (n) => argSizes("RUN <<EOF\n" + "x".repeat(n - 1) + "\nEOF\n").map((a) => a.bytes);
export { parseCeiling } from "../../harness/files/tests/lint.ts";
// runArgProblems on a temp app folder: a .bayt/Dockerfile.x and a root Dockerfile of `bayt` and `root` bytes of command.
import { runArgProblems } from "../../harness/files/tests/lint.ts";
async function inApp(fill, ceiling) {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.mkdir(`${dir}/.bayt`);
    await fill(dir);
    return await runArgProblems(ceiling, dir);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}
export const problems = (ceiling, bayt, root) => inApp(async (d) => {
  await Deno.writeTextFile(`${d}/.bayt/Dockerfile.x`, "RUN " + "x".repeat(bayt) + "\n");
  await Deno.writeTextFile(`${d}/Dockerfile`, "RUN " + "x".repeat(root) + "\n");
}, ceiling);
export const linked = (ceiling) => inApp(async (d) => {
  await Deno.writeTextFile(`${d}/.bayt/Dockerfile.real`, "RUN " + "x".repeat(ceiling + 1) + "\n");
  await Deno.symlink("Dockerfile.real", `${d}/.bayt/Dockerfile.link`);
}, ceiling);
export const unreadable = () => inApp(async (d) => {
  await Deno.symlink("nowhere", `${d}/.bayt/Dockerfile.gone`);
}, 100).then((p) => [p.length === 1 && p[0].startsWith(".bayt/Dockerfile.gone: cannot be read")]);

// The scenarios loader (load.ts, PRONTO-1071): which files of a folder are scenarios, and, with a fake `cue` (a script CUE
// names), the command it runs and what an abort or a timeout does to it.
import { loadScenarios, scenarioFiles } from "../../harness/files/tests/scenarios/load.ts";
export { scenarioFiles };
export async function loaded(script, opts) {
  const dir = await Deno.makeTempDir();
  const prev = Deno.env.get("CUE");
  try {
    await Deno.mkdir(`${dir}/scenarios`);
    for (const n of ["b.cue", "a.cue", "notes.md", "c.cue.bak"]) await Deno.writeTextFile(`${dir}/scenarios/${n}`, "");
    await Deno.writeTextFile(`${dir}/cue.sh`, `#!/bin/sh\n${script}\n`);
    await Deno.chmod(`${dir}/cue.sh`, 0o755);
    Deno.env.set("CUE", `${dir}/cue.sh`);
    const started = Date.now();
    const ac = new AbortController();
    if (opts?.abortAfterMs) setTimeout(() => ac.abort(), opts.abortAfterMs);
    try {
      const spec = await loadScenarios(`${dir}/scenarios/`, { signal: opts?.abortAfterMs ? ac.signal : undefined, timeoutMs: opts?.timeoutMs });
      return { spec, args: (await Deno.readTextFile(`${dir}/args`).catch(() => "")).split("\n").slice(0, -1).map((a) => a.replace(dir, "<dir>")), error: null, fast: Date.now() - started < 5000 };
    } catch (e) {
      const fast = Date.now() - started < 5000; // at the rejection, not once settled
      await e.settled;
      return { spec: null, error: String(e.message), fast };
    }
  } finally {
    if (prev === undefined) Deno.env.delete("CUE"); else Deno.env.set("CUE", prev);
    await Deno.remove(dir, { recursive: true });
  }
}

// A cue that starts a descendant holding its pipes (the wrapper's slot job does), under a deadline: how soon it rejects,
// and whether the descendant (its pid is in a file; opts.ignoreTerm: one that ignores TERM) is gone within 4 s.
export async function descendant(opts) {
  const dir = await Deno.makeTempDir();
  const prev = Deno.env.get("CUE");
  try {
    await Deno.mkdir(`${dir}/scenarios`);
    await Deno.writeTextFile(`${dir}/cue.sh`, `#!/bin/sh\n${opts.ignoreTerm ? "sh -c 'trap \"\" TERM; while :; do sleep 1; done' &" : "sleep 30 &"}\necho $! > "$(dirname "$0")/pid"\nwait\n`);
    await Deno.chmod(`${dir}/cue.sh`, 0o755);
    Deno.env.set("CUE", `${dir}/cue.sh`);
    const started = Date.now();
    const ac = new AbortController();
    if (opts.preAborted) ac.abort();
    let error = null, settled;
    try { await loadScenarios(`${dir}/scenarios`, { signal: opts.preAborted ? ac.signal : undefined, timeoutMs: opts.timeoutMs }); } catch (e) { error = String(e.message); settled = e.settled; }
    const ms = Date.now() - started;
    await settled;
    const pid = Number((await Deno.readTextFile(`${dir}/pid`).catch(() => "0")).trim());
    const alive = (p) => { try { Deno.kill(p, "SIGCONT"); return true; } catch { return false; } };
    let gone = true;
    if (pid) { for (let i = 0; i < 40 && alive(pid); i++) await new Promise((r) => setTimeout(r, 100)); gone = !alive(pid); if (!gone) Deno.kill(pid, "SIGKILL"); }
    return { error, quick: ms < 2500, started: pid > 0, gone };
  } finally {
    if (prev === undefined) Deno.env.delete("CUE"); else Deno.env.set("CUE", prev);
    await Deno.remove(dir, { recursive: true });
  }
}

// The image guard of the shared tests/lint.ts on a stand-in app (PRONTO-870): a scenarios runner whose loader imports
// tests/slot.ts, which names ".bayt", "cue.mod" and the compose file. `lint image` runs in the app's folder, as the gate does.
export async function imageGuard() {
  const dir = await Deno.makeTempDir();
  const lint = new URL("../../harness/files/tests/lint.ts", import.meta.url).pathname;
  const put = async (path, text) => {
    await Deno.mkdir(`${dir}/${path.split("/").slice(0, -1).join("/") || "."}`, { recursive: true });
    await Deno.writeTextFile(`${dir}/${path}`, text);
  };
  try {
    await put("bayt.json", JSON.stringify({ name: "x" }));
    await put(".bayt/bayt.integrate.json", JSON.stringify({ name: "integrate", compose: { command: ["deno", "run", "tests/scenarios.ts"] } }));
    await put(".bayt/Dockerfile.integrate", "FROM scratch AS integrate\nCOPY tests tests\n");
    await put(".bayt/process-compose.yaml", "processes: {}\n");
    await put("cue.mod/module.cue", "module: \"x.test\"\n");
    await put("tests/scenarios.ts", 'import "./scenarios/load.ts";\n');
    await put("tests/scenarios/load.ts", 'import { treeOf } from "../slot.ts";\nexport const t = treeOf;\n');
    await put("tests/slot.ts", 'export const treeOf = () => [".bayt", "cue.mod", ".bayt/process-compose.yaml"];\n');
    const out = await new Deno.Command(Deno.execPath(), { args: ["run", "-A", "--no-config", lint, "image"], cwd: dir, stdout: "piped", stderr: "piped" }).output();
    const say = new TextDecoder();
    return { code: out.code, out: say.decode(out.stdout).trim(), err: say.decode(out.stderr).trim() };
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}

// How a close ends (harness/files/tests/scenarios/verdict.ts closing): a close that finishes, one Playwright rejects (with a stack behind its
// first line) and one that never answers, waited for 20 ms.
import { closing, settleRun } from "../../harness/files/tests/scenarios/verdict.ts";
export function closeOf(kind) {
  const p = kind === "ok" ? Promise.resolve() : kind === "reject" ? Promise.reject(new Error("Target page, context or browser has been closed\n    at stack")) : new Promise(() => {});
  return closing(p, 20);
}
// The ids a run reports failed and records green once the browser's close is known (verdict.ts settleRun), as sorted lists.
export function settled(o) {
  const r = settleRun({ failed: [], pageErrorIds: [], pageErrors: [], ...o });
  return { failedAll: [...r.failedAll].sort(), green: r.green };
}
