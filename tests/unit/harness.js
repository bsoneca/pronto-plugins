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
export { declaredKeys } from "../../harness/files/tests/scenarios/select.ts";

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
