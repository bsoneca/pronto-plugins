// The hourly pending-flags watch (flags merged to main and not on for everyone in production): a dedicated clone of the
// flow's `flagsRepo` under the devflow cache (never a developer's checkout) is brought to origin/main, cue exports each
// app's flags and where they are live, the live value is asked of production's OFREP, and flow.js pendingFlags says
// which wait for their flip. The line is what `status` and `pronto-devflow flags` print.
import { cmd } from "../intents/shell.ts";
import { driftFlags, newPending, pendingFlags, pendingLine, unavailableLines } from "./flow.js";
import { cueBin, type DevFlow } from "./spec.ts";

type Run = (c: string, args: string[], cwd?: string, env?: Record<string, string>) => Promise<{ ok: boolean; out: string; err: string }>;
type Flags = Record<string, { default: unknown; note?: string }>;
type Entries = Record<string, { flags?: string[]; steps?: { flag?: string }[] }>;

const cacheDir = () => {
  const base = Deno.env.get("XDG_CACHE_HOME") ?? (Deno.env.get("HOME") ? `${Deno.env.get("HOME")}/.cache` : "");
  if (!base.startsWith("/")) throw new Error("no HOME or XDG_CACHE_HOME to keep the clone in");
  return `${base}/pronto-devflow`;
};

/** `fn` holding the clone's lock (a directory made, so two runs never share the tree): waits up to 10 min, and takes over one older than 30. */
async function locked<T>(repo: string, fn: () => Promise<T>): Promise<T> {
  Deno.mkdirSync(cacheDir(), { recursive: true });
  const lock = `${cacheDir()}/flags-${repo.replace("/", "-")}.lock`;
  for (let waited = 0;; waited += 5) {
    try {
      Deno.mkdirSync(lock);
      break;
    } catch (e) {
      if (!(e instanceof Deno.errors.AlreadyExists)) throw e;
      const age = Date.now() - (Deno.statSync(lock).mtime?.getTime() ?? 0);
      if (age > 30 * 60000) {
        try { Deno.removeSync(lock); } catch { /* another run took it over */ }
        continue;
      }
      if (waited >= 600) throw new Error(`the clone of ${repo} is in use by another run`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
  try {
    return await fn();
  } finally {
    try { Deno.removeSync(lock); } catch { /* gone already */ }
  }
}
const first = (s: string) => s.trim().split("\n")[0];

/** The dedicated clone of `repo`, at its origin/main: made on first use, then fetched. A failure throws, naming the call. */
async function cloneAt(repo: string, run: Run): Promise<string> {
  const dir = `${cacheDir()}/flags-${repo.replace("/", "-")}`;
  const git = async (args: string[]) => {
    const r = await run("git", ["-C", dir, ...args]);
    if (!r.ok) throw new Error(`git ${args[0]} ${repo}: ${first(r.err)}`);
    return r.out;
  };
  try {
    Deno.statSync(`${dir}/.git`);
  } catch {
    Deno.mkdirSync(cacheDir(), { recursive: true });
    const r = await run("gh", ["repo", "clone", repo, dir, "--", "--no-checkout", "--quiet"]);
    if (!r.ok) throw new Error(`gh repo clone ${repo}: ${first(r.err)}`);
  }
  await git(["fetch", "--quiet", "origin", "main"]);
  await git(["checkout", "--quiet", "--force", "--detach", "origin/main"]);
  await git(["clean", "-fdq"]);
  return dir;
}

/** The environment a cue runs in under an app: the CUE the app pins (`cue-lang/cue` in its .mise.toml, as mise installed it) first
 * on the PATH, ahead of the budget wrapper's search, since an app's language version may be newer than the plugins' pin. Undefined
 * (the caller's own environment) when the app pins none or it is not installed. */
function cueEnv(dir: string): Record<string, string> | undefined {
  try {
    const pin = /cue-lang\/cue['"]\s*=\s*['"]([^'"]+)/.exec(Deno.readTextFileSync(`${dir}/.mise.toml`))?.[1];
    const data = Deno.env.get("MISE_DATA_DIR") ?? `${Deno.env.get("XDG_DATA_HOME") ?? `${Deno.env.get("HOME") ?? "."}/.local/share`}/mise`;
    const bin = `${data}/installs/github-cue-lang-cue/${pin}`;
    if (!pin || !Deno.statSync(`${bin}/cue`).isFile) return undefined;
    return { ...Deno.env.toObject(), PATH: `${bin}:${Deno.env.get("PATH") ?? ""}` };
  } catch {
    return undefined;
  }
}

/** An expression of the CUE package in `dir`, or null when it has none there (no such folder, or no such field). */
async function exportOf<T>(dir: string, pkg: string, expr: string, run: Run): Promise<T | null> {
  try {
    Deno.statSync(pkg === "." ? dir : `${dir}/${pkg}`);
  } catch {
    return null;
  }
  for (let stubs = 0;; stubs++) {
    const r = await run(cueBin(), ["export", pkg === "." ? "." : `./${pkg}`, "-e", expr, "--out", "json"], dir, cueEnv(dir));
    if (r.ok) return JSON.parse(r.out) as T;
    // A file a package embeds that its generate step writes (and .gitignore keeps out of the clone) is stood in for by `{}`: the flags and the
    // address do not read it, and the clone is the watch's own.
    const embed = /@embed: open (\S+\.json): no such file or directory:\s+\.?\/?(\S+?):\d+:\d+/.exec(r.err);
    if (embed && stubs < 12) {
      const at = `${dir}/${embed[2].replace(/[^/]*$/, "")}${embed[1]}`;
      Deno.mkdirSync(at.replace(/\/[^/]*$/, ""), { recursive: true });
      Deno.writeTextFileSync(at, "{}");
      continue;
    }
    // A tests folder with no `scenarios` or `cases` field has none; the app's own package says its flags, or the run fails.
    if (pkg !== "." && /undefined field|incomplete/.test(r.err)) return null;
    throw new Error(`cue export ${pkg} in ${dir}: ${r.err.trim().split("\n").pop()}`);
  }
}

/** What production's OFREP answers for a flag with no context: its value, or null where it answers none (a flag that is
 * not `client` is a 404). Anything else throws. */
async function liveValue(url: string, flag: string): Promise<unknown> {
  const r = await fetch(`${url}/ofrep/v1/evaluate/flags/${flag}`, { method: "POST", headers: { "content-type": "application/json" }, body: '{"context":{}}', signal: AbortSignal.timeout(15000) });
  const body = await r.text();
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`ofrep ${url} ${flag}: ${r.status}`);
  return (JSON.parse(body) as { value?: unknown }).value ?? null;
}

/** When the commit that added `flag` to the app's flags_spec.cue landed (the oldest that changes the count of `flag:` there), or null. */
async function addedAt(dir: string, app: string, flag: string, run: Run): Promise<string | null> {
  const r = await run("git", ["-C", dir, "log", "--format=%cI", "--pickaxe-regex", `-S(^|[^A-Za-z0-9_])${flag}:`, "--", `apps/${app}/flags_spec.cue`]);
  if (!r.ok) throw new Error(`git log ${app}/${flag}: ${first(r.err)}`);
  return r.out.trim().split("\n").filter(Boolean).pop() ?? null;
}

/** Whether a scenario (tests/scenarios, in `flags` or a step's `flag`) or a unit case (tests/unit, in `flags`) names each of `names`: what a flip runs, and what `pronto-flags push` refuses a flag without. */
async function casesOf(dir: string, names: string[], run: Run): Promise<Record<string, boolean>> {
  const scenarios = await exportOf<Entries>(dir, "tests/scenarios", "scenarios", run) ?? {};
  const unit = await exportOf<Entries>(dir, "tests/unit", "cases", run) ?? {};
  const named = new Set<string>();
  for (const e of Object.values(scenarios)) for (const f of [...(e.flags ?? []), ...(e.steps ?? []).map((s) => s.flag ?? "")]) named.add(f);
  for (const e of Object.values(unit)) for (const f of e.flags ?? []) named.add(f);
  return Object.fromEntries(names.map((n) => [n, named.has(n)]));
}

/** The pending flags of every app of the flow's `flagsRepo` at origin/main, held ones left out, and the drift (live true, spec false). A failure of the clone throws, naming it; a failure inside one app (its CUE, its OFREP) leaves
 * that app out and lists it in `unavailable` with the reason, so the other apps are still reported. */
export function pendingNow(flow: DevFlow, now: Date, run: Run = (c, a, cwd, env) => cmd(c, a, { cwd, env })) {
  return locked(flow.flagsRepo, () => pendingIn(flow, now, run));
}

async function pendingIn(flow: DevFlow, now: Date, run: Run) {
  const root = await cloneAt(flow.flagsRepo, run);
  const tree = await run("git", ["-C", root, "ls-tree", "-r", "--name-only", "origin/main"]);
  if (!tree.ok) throw new Error(`git ls-tree ${flow.flagsRepo}: ${first(tree.err)}`);
  const names = tree.out.split("\n").map((l) => /^apps\/([^/]+)\/flags_spec\.cue$/.exec(l)?.[1]).filter((a): a is string => !!a);
  const apps = [];
  const unavailable: { app: string; reason: string }[] = [];
  for (const app of names) {
    try {
      const dir = `${root}/apps/${app}`;
      // A spec that says no flag (aprende's is only its production address, generated from release.cue) has nothing to flip, and its package may need a generate step to evaluate at all.
      if (!/^flags\b/m.test(Deno.readTextFileSync(`${dir}/flags_spec.cue`))) continue;
      const spec = await exportOf<{ f: Flags; url: string | null }>(dir, ".", "{f: flags, url: *flagsLive.url | null}", run);
      // An app with no production address has no live value to wait on.
      if (!spec?.url) continue;
      const off = Object.entries(spec.f).filter(([, f]) => f.default === false).map(([n]) => n);
      const live = Object.fromEntries(await Promise.all(off.map(async (n) => [n, await liveValue(spec.url!, n)] as const)));
      const pending = off.filter((n) => live[n] !== true);
      const added: Record<string, string | null> = {};
      for (const n of pending) added[n] = await addedAt(root, app, n, run);
      apps.push({ app, flags: spec.f, live, added, cases: pending.length ? await casesOf(dir, pending, run) : {} });
    } catch (e) {
      unavailable.push({ app, reason: (e as Error).message });
    }
  }
  return { pending: pendingFlags(apps, flow.flagsHeld, now), drift: driftFlags(apps), unavailable };
}

/** The flags `--new` has reported, kept between runs: one small JSON file of `app/flag` names, written whole to a temporary file and renamed. */
function seenFile(flow: DevFlow) {
  const file = `${cacheDir()}/pending-flags-${flow.board.workspace}-${flow.board.project.identifier}.json`;
  return {
    read(): string[] {
      try {
        const seen = JSON.parse(Deno.readTextFileSync(file)) as unknown;
        return Array.isArray(seen) ? seen.filter((s): s is string => typeof s === "string") : [];
      } catch {
        return [];
      }
    },
    write(keys: string[]) {
      const tmp = `${file}.${Deno.pid}.tmp`;
      try {
        Deno.mkdirSync(cacheDir(), { recursive: true });
        Deno.writeTextFileSync(tmp, JSON.stringify(keys));
        Deno.renameSync(tmp, file);
      } catch { /* a state that cannot be written costs the next run a repeat */ }
    },
  };
}

/** The pending flags and the line to print. With `fresh` (`--new`) the list is only those not reported before, and what is
 * pending now is kept as reported; a flag that leaves and returns is reported again. */
export async function watchFlags(flow: DevFlow, now: Date, fresh = false, run?: Run) {
  const { pending, drift, unavailable } = await pendingNow(flow, now, run);
  const down = unavailableLines(unavailable);
  const line = (l: string) => [l, ...down].join("\n");
  if (!fresh) return { list: pending, drift, unavailable, line: line(pendingLine(pending, false, drift)) };
  const seen = seenFile(flow);
  const was = seen.read();
  const list = newPending(pending, was);
  const newDrift = newPending(drift, was, "drift");
  seen.write([...pending.map((f) => `pending:${f.app}/${f.flag}`), ...drift.map((f) => `drift:${f.app}/${f.flag}`)]);
  return { list, drift: newDrift, unavailable, line: line(pendingLine(list, true, newDrift)) };
}
