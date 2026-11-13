// The browsers a test run launches, shut down whatever ends the run (PRONTO-450). The same file in
// every app that drives a browser, copied unchanged from apps/brawl-chess (.github/ci-shared).
//
// A runner that called `chromium.launch` and `browser.close()` at the end of its normal path left
// playwright's chrome-headless-shell running after a throw, a SIGINT/SIGTERM (a cancelled gate, a
// stopped run) or a hung page, and the Mac's load climbed to 155 on 18 cores. Runners launch here
// instead (`import { launch } from "./browser.ts"`), and every browser this process launched is:
//   - closed, if still open, on a normal end, on an uncaught error or unhandled rejection (the run
//     exits 1) and on SIGINT, SIGTERM and SIGHUP (the run exits 130, 143, 129);
//   - killed, with its children, when close() does not return within BROWSER_CLOSE_MS (10 s): a
//     hung page's browser does not answer a close. `browser.close()` is this guarded close.
// Only what this process started: the descendants of its own pid that carry playwright's
// --remote-debugging-pipe, never the user's own Chrome or another run's browsers. The machine's side
// (a claim's leftovers, orphans of a run that was killed outright) is tests/slot.ts.
import type { Browser, LaunchOptions } from "npm:playwright@1.61.1";

type Closable = { close(): Promise<void> };
type Proc = { pid: number; ppid: number; command: string };
type Entry = { browser: Closable; close: () => Promise<void>; roots: number[] };

const closeMs = () => Number(Deno.env.get("BROWSER_CLOSE_MS") ?? 10_000);
const marker = "--remote-debugging-pipe";

const table = (out: string): Proc[] => out.split("\n").flatMap((l) => {
  const m = l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
  return m ? [{ pid: Number(m[1]), ppid: Number(m[2]), command: m[3] }] : [];
});
const psArgs = ["-A", "-o", "pid=,ppid=,command="];
const processes = async (): Promise<Proc[]> => {
  try { return table(new TextDecoder().decode((await new Deno.Command("ps", { args: psArgs, stdout: "piped", stderr: "null" }).output()).stdout)); } catch { return []; }
};
const processesSync = (): Proc[] => {
  try { return table(new TextDecoder().decode(new Deno.Command("ps", { args: psArgs, stdout: "piped", stderr: "null" }).outputSync().stdout)); } catch { return []; }
};
// A process and all it started.
export const treeOf = (procs: readonly Proc[], root: number): number[] => {
  const out = [root];
  for (let i = 0; i < out.length; i++) for (const p of procs) if (p.ppid === out[i] && !out.includes(p.pid)) out.push(p.pid);
  return out;
};
// The browsers this process started: its descendants launched by playwright (they carry its pipe flag).
export const ownRoots = (procs: readonly Proc[], me = Deno.pid): number[] => {
  const mine = new Set(treeOf(procs, me));
  return procs.filter((p) => mine.has(p.pid) && p.pid !== me && p.command.includes(marker)).map((p) => p.pid);
};
const kill = (pids: readonly number[]) => { for (const pid of pids) try { Deno.kill(pid, "SIGKILL"); } catch { /* gone */ } };
const killTrees = (roots: readonly number[], procs: readonly Proc[]) => kill([...new Set(roots.flatMap((r) => treeOf(procs, r)))]);

const open = new Set<Entry>();

// One browser closed, or killed with its children if it does not close in time or its close fails
// (a failure is then thrown: a runner calling browser.close() hears of it).
async function closeOne(e: Entry): Promise<void> {
  if (!open.delete(e)) return;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timedOut = new Promise<"hung">((r) => { timer = setTimeout(() => r("hung"), closeMs()); });
  const outcome = await Promise.race([e.close().then(() => "closed" as const, (error: unknown) => ({ error })), timedOut]);
  clearTimeout(timer);
  if (outcome === "closed") return;
  const why = outcome === "hung" ? `close() did not return within ${closeMs() / 1000} s` : `close() failed: ${outcome.error}`;
  console.error(`browser: ${why}; killing it`);
  const procs = await processes();
  killTrees(e.roots.length ? e.roots : ownRoots(procs), procs);
  if (outcome !== "hung") throw outcome.error;
}

// Every browser this process launched, closed; then whatever of its own is left, killed. A close
// that failed was reported by closeOne and its browser killed; the rest still close.
export async function closeAll(): Promise<void> {
  await Promise.allSettled([...open].map(closeOne));
  const procs = await processes();
  killTrees(ownRoots(procs), procs);
}
// The same without waiting, for the process's last moment.
const killAllNow = () => { const procs = processesSync(); killTrees(ownRoots(procs), procs); };

let installed = false;
let stopping = false;
async function stop(code: number): Promise<never> {
  // A second signal while closing: no more waiting.
  if (stopping) { killAllNow(); Deno.exit(code); }
  stopping = true;
  try { await closeAll(); } catch { killAllNow(); }
  Deno.exit(code);
}
function install() {
  if (installed) return;
  installed = true;
  for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]] as const) {
    try { Deno.addSignalListener(signal, () => { console.error(`browser: ${signal}, closing the browsers`); void stop(code); }); } catch { /* not on this platform */ }
  }
  globalThis.addEventListener("error", (e) => { e.preventDefault(); console.error(e.error ?? e.message); void stop(1); });
  globalThis.addEventListener("unhandledrejection", (e) => { e.preventDefault(); console.error(e.reason); void stop(1); });
  // Whatever still runs when the process ends, however it ends.
  globalThis.addEventListener("unload", () => { if (open.size) killAllNow(); });
}

// A browser made one of this process's: its close guarded, its end watched. `roots` are its own
// processes when known (launch finds them); without, a close that times out kills all of this
// process's browsers.
export function register<B extends Closable>(browser: B, roots: number[] = []): B {
  install();
  const original = browser.close.bind(browser);
  const entry: Entry = { browser, close: original, roots };
  open.add(entry);
  browser.close = () => closeOne(entry);
  try { (browser as { on?: (event: string, f: () => void) => unknown }).on?.("disconnected", () => { open.delete(entry); }); } catch { /* a stand-in without events */ }
  return browser;
}

// chromium.launch, registered. Takes playwright's launch options.
export async function launch(options?: LaunchOptions): Promise<Browser> {
  const { chromium } = await import("npm:playwright@1.61.1");
  const before = new Set(ownRoots(await processes()));
  const browser = await chromium.launch(options);
  const claimed = new Set([...open].flatMap((e) => e.roots));
  const roots = ownRoots(await processes()).filter((p) => !before.has(p) && !claimed.has(p));
  return register(browser, roots);
}
