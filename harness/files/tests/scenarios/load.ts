// Needs --allow-run (cue, ps), --allow-env (CUE, and slot.ts's) and --allow-read (the folder).
// The scenarios of an app, as CUE exports them: the one place that finds tests/scenarios/*.cue, runs `cue export` on
// them and reads the result, for the runner (tests/scenarios.ts) and for a caller that plans from the same set (a
// rehearsal's order of pass 1), so none copies it.
import { processes, treeOf } from "../slot.ts";
export type Step = Record<string, any> & { by?: string; timeout?: number; why?: string };
export type ActorDef = { name: string; device?: string; locale?: string } & Record<string, any>;
export type Scenario = { id: string; slow?: true; accepts: string[]; actors: Record<string, ActorDef>; steps: Step[]; flags?: string[]; production?: true; standin?: true };
export type Screen = { viewport?: { width: number; height: number }; device?: string };
export type Spec = {
  parallel: number;
  deployedParallel: number;
  flakes: { app?: string; priority: string; file: string[]; retry: boolean };
  screen: Screen;
  screens?: Record<string, Screen>;
  locale: string;
  messages: string;
  loaded: { screen?: string; adopted: boolean };
  select: { client: string[]; derived: string[]; inert: string[]; live: string[]; outside: string[] };
  database?: string;
  signIn?: { open: string[]; passkey: string };
  scenarios: Record<string, Scenario>;
};

// The CUE files of a scenarios folder, from the names it holds: those ending in .cue, each as the folder's path and
// its name, sorted. `dir` ends in a slash or is given without one.
export const scenarioFiles = (dir: string, names: string[]): string[] => {
  const base = dir.endsWith("/") ? dir : dir + "/";
  return names.filter((n) => n.endsWith(".cue")).map((n) => base + n).sort();
};

// Stops cue and everything it started (the wrapper's slot job holds the pipes, so killing the child alone leaves them
// open): TERM the whole tree, then, after `graceMs`, KILL what is still the same process. Deno has no process group, so
// the tree is read from one ps table; the pids are kept, since a child's orphans leave its tree the moment it dies.
const stopTree = async (root: number, graceMs = 2000) => {
  const table = await processes();
  const tree = treeOf(table, root).map((pid) => ({ pid, command: table.find((p) => p.pid === pid)?.command }));
  const send = (pid: number, sig: Deno.Signal) => { try { Deno.kill(pid, sig); } catch { /* gone */ } };
  for (const { pid } of tree) send(pid, "SIGTERM");
  // Not unref'd: a caller that rejects and exits at once lives up to graceMs longer, so a TERM-ignoring descendant is KILLed, not left.
  setTimeout(async () => {
    const now = await processes();
    for (const { pid, command } of tree) if (command !== undefined && now.some((p) => p.pid === pid && p.command === command)) send(pid, "SIGKILL");
  }, graceMs);
};

const drain = async (r: ReadableStreamDefaultReader<Uint8Array>): Promise<Uint8Array> => {
  const parts: Uint8Array[] = [];
  try { for (;;) { const { done, value } = await r.read(); if (done) break; parts.push(value); } } catch { /* cancelled */ }
  const out = new Uint8Array(parts.reduce((n, c) => n + c.length, 0));
  parts.reduce((at, c) => { out.set(c, at); return at + c.length; }, 0);
  return out;
};

// `cue export` of the folder's scenarios (the binary CUE names, else cue on the PATH), parsed. An aborted signal or an
// elapsed timeoutMs rejects at once, saying so (never waiting for cue's pipes to close), and stops cue and what it
// started.
export const loadScenarios = async (dir: string, opts: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<Spec> => {
  const files = scenarioFiles(dir, [...Deno.readDirSync(dir)].map((f) => f.name));
  const signals = [opts.signal, opts.timeoutMs === undefined ? undefined : AbortSignal.timeout(opts.timeoutMs)].filter((s): s is AbortSignal => !!s);
  const signal = signals.length ? AbortSignal.any(signals) : undefined;
  const stopped = () => new Error(`the scenarios export was stopped (${opts.signal?.aborted ? "aborted" : `no answer in ${opts.timeoutMs} ms`}), cue was killed`);
  if (signal?.aborted) throw stopped();
  const child = new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["export", ...files, "--out", "json"], stdout: "piped", stderr: "piped" }).spawn();
  const readers = [child.stdout.getReader(), child.stderr.getReader()];
  let onAbort: (() => void) | undefined;
  const aborted = new Promise<never>((_, reject) => {
    if (!signal) return;
    onAbort = () => {
      reject(stopped());
      stopTree(child.pid).catch(() => {});
      for (const r of readers) r.cancel().catch(() => {});
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
  const finished = Promise.all([child.status, drain(readers[0]), drain(readers[1])]);
  finished.catch(() => {});
  try {
    const [status, stdout, stderr] = await Promise.race([finished, aborted]);
    if (!status.success) throw new Error("the scenarios do not export: " + new TextDecoder().decode(stderr));
    return JSON.parse(new TextDecoder().decode(stdout)) as Spec;
  } finally {
    if (onAbort) signal?.removeEventListener("abort", onAbort);
  }
};
