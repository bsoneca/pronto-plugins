// pronto-probe: runs an app's journeys against its released address every few seconds and says
// loudly when they fail, naming the flag writes just before the first failure (README.md).
//   deno run -A probe/probe.ts <app-dir> [--once] [--probe name]
// `cue` from PATH or $CUE. One JSON line per run goes to stdout and to
// ${XDG_STATE_HOME:-~/.local/state}/pronto-probe/<app>.jsonl. PROBE_NOTIFY=0 turns the macOS
// notification off; PROBE_WEBHOOK=<url> posts each alert's JSON there.
import { initial, parseDuration, step, suspects } from "./probe.js";

const args = [...Deno.args];
const once = args.includes("--once") && !!args.splice(args.indexOf("--once"), 1);
const only = (() => {
  const i = args.indexOf("--probe");
  return i < 0 ? undefined : args.splice(i, 2)[1];
})();
const [appArg] = args;
if (!appArg) throw new Error("usage: probe.ts <app-dir> [--once] [--probe name]");
const appDir = Deno.realPathSync(appArg);
const app = appDir.split("/").pop()!;
const cue = Deno.env.get("CUE") ?? "cue";
const decode = (b: Uint8Array) => new TextDecoder().decode(b);
const state = Deno.env.get("XDG_STATE_HOME") ?? `${Deno.env.get("HOME")}/.local/state`;

const registry = (() => { try { return Deno.readTextFileSync(`${appDir}/.mise.toml`).match(/^CUE_REGISTRY\s*=\s*['"]([^'"]+)['"]/m)?.[1]; } catch { return undefined; } })();
const exported = new Deno.Command(cue, { args: ["export", ".", "-e", "{p: probes, t: probeTarget}", "--out", "json"], cwd: appDir, env: registry ? { CUE_REGISTRY: registry } : {}, stdout: "piped", stderr: "piped" }).outputSync();
if (!exported.success) throw new Error(`cue export (in ${appDir}):\n${decode(exported.stderr)}`);
const { p: probes, t: target } = JSON.parse(decode(exported.stdout)) as { p: Record<string, Probe>; t: { url: string; flagsJournal?: string } };

interface Step { name: string; method: string; path: string; body?: unknown; expect: { status: number; contains?: string } }
interface Probe { every: string; timeout: string; journey: Step[]; alert: { after: number; suspectWindow: string } }

const logPath = `${state}/pronto-probe/${app}.jsonl`;
Deno.mkdirSync(`${state}/pronto-probe`, { recursive: true });
// The flags journal pronto-flags writes: PRONTO_FLAGS_JOURNAL names it for both, as flags/live.nu reads it.
const journalPath = Deno.env.get("PRONTO_FLAGS_JOURNAL") || target.flagsJournal || `${state}/pronto-flags/${app}.jsonl`;
const emit = (o: Record<string, unknown>) => {
  const line = JSON.stringify(o);
  console.log(line);
  Deno.writeTextFileSync(logPath, line + "\n", { append: true });
};

// One run of a journey: the first step to fail ends it.
async function run(p: Probe) {
  const timeout = parseDuration(p.timeout);
  const start = performance.now();
  for (const s of p.journey) {
    const t0 = performance.now();
    const ms = () => Math.round(performance.now() - t0);
    try {
      const res = await fetch(target.url + s.path, {
        method: s.method,
        headers: s.body === undefined ? {} : { "content-type": "application/json" },
        body: s.body === undefined ? undefined : JSON.stringify(s.body),
        signal: AbortSignal.timeout(timeout),
      });
      const text = await res.text();
      if (res.status !== s.expect.status) return { ok: false, step: s.name, status: res.status, ms: ms(), error: `status ${res.status}, wanted ${s.expect.status}` };
      if (s.expect.contains !== undefined && !text.includes(s.expect.contains)) return { ok: false, step: s.name, status: res.status, ms: ms(), error: `body lacks "${s.expect.contains}"` };
    } catch (e) {
      return { ok: false, step: s.name, status: null, ms: ms(), error: String(e) };
    }
  }
  return { ok: true, step: null, status: null, ms: Math.round(performance.now() - start), error: null };
}

function journal(): string[] {
  try { return Deno.readTextFileSync(journalPath).split("\n").filter(Boolean); } catch { return []; }
}

async function notify(title: string, body: string, payload?: unknown) {
  if (Deno.build.os === "darwin" && Deno.env.get("PROBE_NOTIFY") !== "0") {
    const q = (s: string) => `"${s.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
    try { await new Deno.Command("osascript", { args: ["-e", `display notification ${q(body)} with title ${q(title)}`], stdout: "null", stderr: "null" }).output(); } catch { /* no notification centre */ }
  }
  const hook = Deno.env.get("PROBE_WEBHOOK");
  if (hook && payload) {
    try { await fetch(hook, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload), signal: AbortSignal.timeout(5000) }); } catch (e) { console.error(`probe: webhook: ${e}`); }
  }
}

async function onEvent(name: string, p: Probe, ev: Record<string, unknown>) {
  if (ev.event === "probe.alert") {
    const sus = suspects(journal(), ev.firstFailureAt as string, parseDuration(p.alert.suspectWindow)).map((w) => ({ ...w, rollback: w.rollback.replace("<app-dir>", appArg) }));
    const alert = { ...ev, probe: name, app, suspects: sus };
    console.log("\n" + "!".repeat(72));
    console.log(`ALERT  ${app}/${name} failing since ${ev.firstFailureAt} (${ev.failures} runs)`);
    if (sus.length) {
      console.log("Suspect flag writes, newest first:");
      for (const s of sus) console.log(`  ${s.at}  ${s.flag}  v${s.version} by ${s.who} (${s.commit})\n    undo: ${s.rollback || "nothing before it to roll back to"}`);
    } else console.log(`No flag write in the ${p.alert.suspectWindow} before it (${journalPath}).`);
    console.log("!".repeat(72) + "\n");
    emit(alert);
    await notify(`ALERT ${app}/${name}`, sus.length ? `after flag ${sus[0].flag}: ${sus[0].rollback}` : "no flag write before it", alert);
  } else if (ev.event === "probe.resolved") {
    const resolved = { ...ev, probe: name, app };
    console.log(`\nRESOLVED  ${app}/${name} down ${Math.round((ev.downFor as number) / 1000)}s (since ${ev.firstFailureAt})\n`);
    emit(resolved);
    await notify(`RESOLVED ${app}/${name}`, `down ${Math.round((ev.downFor as number) / 1000)}s`, resolved);
  }
}

const names = Object.keys(probes).filter((n) => !only || n === only);
if (!names.length) throw new Error(only ? `no probe ${only} in ${appDir}` : `${appDir} says no probes`);

let stop = false;
const timers = new Set<number>();
const abort = () => { stop = true; for (const t of timers) clearTimeout(t); };
Deno.addSignalListener("SIGINT", () => { abort(); console.error("probe: stopped"); Deno.exit(0); });

let failed = false;
await Promise.all(names.map(async (name) => {
  const p = probes[name];
  let st = initial();
  while (!stop) {
    const at = new Date().toISOString();
    const r = await run(p);
    emit({ at, event: "probe.run", probe: name, ok: r.ok, step: r.step, status: r.status, ms: r.ms, error: r.error });
    if (!r.ok) failed = true;
    const next = step(st, r, at, { after: p.alert.after });
    st = next.state;
    for (const ev of next.events) await onEvent(name, p, ev);
    if (once) return;
    await new Promise((res) => timers.add(setTimeout(res, parseDuration(p.every))));
  }
}));
if (once && failed) Deno.exit(1);
