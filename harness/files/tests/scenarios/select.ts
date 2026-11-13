// Which scenarios the runner (tests/scenarios.ts) runs: the ones whose inputs are not as at their
// last green run on this machine. The rest are reported cached and not run. Every app's copy of
// this file is the same.
//
// It selects only in the local gate (integrate@local with INTEGRATE_LOCAL_DRIVERS=all, on a
// localhost door): a stack that integrate@local brought up from the tree's files, so the tree on
// disk is what the scenarios saw. A runner pointed by hand at a stack someone started earlier or a
// release's preview runs every scenario; a rehearsal's (SCENARIOS_REUSE=1) runs those with no green record on this exact tree. SCENARIOS_ALL=1 runs every one there too
// (and records the green ones, which the diff below then trusts).
//
// 1. Cached on the exact tree. A scenario's inputs are its own exported steps and the whole app's
// tree: every file git lists (tracked or new, not ignored: what the gate's ledger keys) but the
// scratch (.omc, .claude), the unit cases (tests/unit*) and the other scenarios' files
// (tests/scenarios/*.cue; what a scenario reads from them reaches it through its export). The
// runner's helpers beside them (tests/scenarios/*.ts, such as brawl-chess's early.ts) are inputs of
// every scenario, and so is what the scenarios' CUE holds beside the scenarios (its export less `scenarios`:
// a stand-in's image, PRONTO-184). Beside the tree: this file, the runner, the schema, SLOW, the tool pins of the app
// and of the directories above it, and Deno's version. So the gate's ledger (pronto's
// local-gate-key.nu, which stamps a tree on which every driver passed) keeps its meaning: a cached
// scenario passed on a tree of the same files.
//
// 2. Not touched by the diff. A scenario not cached on the exact tree is still skipped when it has a
// record and the change of the tree against `git merge-base origin/main HEAD` (committed, staged,
// unstaged and new files) touches nothing it exercised. Its record keeps the hash of its steps, the
// environment's (Deno, SLOW, the runner, helpers, schema, pins) and what its green run observed:
// the requests its pages and http steps made, and a hash of the body of each static asset a page
// loaded. A changed file (relative to the app) is
//   - nothing, when it is documentation (*.md, journal/), a unit case, a runner of something else
//     (premium, the rehearsals, slots) or another scenario's CUE (its steps' hash is compared);
//   - everything, when it is the runner, a helper, the schema, SLOW, a pin or a fixture;
//   - a client source, when it is under a directory the app declares (`client`, a list of path globs, `dir/*`
//     prefixes whose effect on a scenario is only through the static assets it loads): the scenarios
//     that loaded such an asset run when the live stack serves it with other bytes than recorded,
//     and one that recorded none runs;
//   - derived, when it is under a prefix the app declares (`derived`: a source whose only effect on a
//     scenario is a generated file that is in the diff too, and judged there: Bonk Chess's hatch-src/src,
//     which `generate` builds into shell/hatches/);
//   - SQL (`*.sql`), judged by what the scenario's requests touched: `/crud/<table>` and `/crud/rpc/<fn>`
//     name a table and a function, and the file matters to the scenario when it mentions one of those or one
//     defined by a file that does, to a fixpoint (a trigger, a function another calls). A scenario that
//     read a shape naming no table or whose file cannot be read runs on any SQL change;
//   - the scenarios' that recorded a request naming it (its path, or its file name);
//   - otherwise unattributable, and every scenario runs. So is a file outside the app that is not
//     documentation, a scenario with no record, and a git that cannot say.
// The diff trusts main: it assumes a scenario was green on main, which the merge gate keeps true.
//
// A green run is recorded under ~/.cache/pronto/scenarios/<app>/<scenario>, once the run is over and
// the tree is still the one it started from; a scenario that fails loses its record.
import { createHash } from "node:crypto";
import { basename, dirname, join, relative } from "node:path";

type Keyed = { id: string };
type Record_ = { key: string; at: string; steps?: string; env?: string; served?: string[]; assets?: Record<string, string> };
export const sha = (b: string | Uint8Array) => createHash("sha256").update(b).digest("hex");
const apart = [".git", "node_modules", ".task", "dist", ".certs", ".omc", ".claude", ".probe", ".DS_Store"];
const apartPrefix = ["tests/unit/", "tests/unit.ts"];
// History pronto keeps under .pronto/ (CI's lint rewrites it in the gate's checkout, so a diff would show it as
// changed): bookkeeping, no input of a scenario (lint.ts, bayt.json's `pronto-history`). A pattern, not a path:
// the scenarios do not read it.
const history = /^\.pronto\/(identity|proto-baseline)\.json$/;
const pins = ["mise.lock", ".mise.toml", "mise.toml"];
// What the diff ignores, beside the scratch: documentation, the unit cases, runners of other checks.
const inert = [/\.md$/, /^journal\//, /^tests\/unit(\/|\.ts$)/, /^tests\/(premium|rehearse|rehearse-cloud|gate-ledger|slot)\.ts$/, /^tests\/scenarios\/(?!schema)[^/]*\.cue$/];
// What every scenario depends on.
const everything = [/^tests\/slow\.ts$/, /^tests\/[^/]*\.ts$/, /^tests\/scenarios\//, /^tests\/fixtures\//, /(^|\/)(mise\.lock|\.?mise\.toml|deno\.jsonc?|deno\.lock|package\.json)$/];
// Audio is left out: a page may stop reading it early, so its body is not the file.
const staticAsset = /\.(js|mjs|css|html|json|wasm|svg|png|jpg|webp|ico|woff2?|glb|gltf)$/;


// What a scenario's requests say it touched in the database: the tables and functions its `/crud/…`
// requests name (a table `/crud/<t>`, a function `/crud/rpc/<fn>`, a shape's `?table=`), lowercased; `wild` when it
// read shapes and none named a table.
export function touched(served: string[]): { names: string[]; wild: boolean } {
  const names = new Set<string>();
  let shapeNamed = false, shapeBare = false;
  for (const r of served) {
    const full = r.slice(r.indexOf(" ") + 1), path = full.split("?")[0];
    if (path.startsWith("/electric/")) {
      // A shape names its table on the request that starts it (`?table=public.chess_match_seat`, recorded by the
      // runner); the ones that follow it (`handle=`, `offset=`) name none and continue that shape.
      const t = full.match(/[?&]table=([^&]+)/)?.[1];
      if (t) { shapeNamed = true; names.add(decodeURIComponent(t).replace(/"/g, "").split(".").pop()!.toLowerCase()); } else shapeBare = true;
    }
    const m = path.match(/^\/crud\/(?:rpc\/)?([A-Za-z0-9_]+)/);
    if (m) names.add(m[1].toLowerCase());
  }
  // Shapes read, and none of them said which table: any.
  return { names: [...names].sort(), wild: shapeBare && !shapeNamed };
}
const words = (text: string) => new Set(text.toLowerCase().match(/[a-z_][a-z0-9_]*/g) ?? []);
// The names a SQL file defines (a function, table, view, type, or a table it alters or attaches a
// trigger, policy or index to), schema left off.
const defined = (text: string) => {
  const out = new Set<string>();
  for (const m of text.matchAll(/\b(?:create(?:\s+or\s+replace)?|alter|drop)\s+(?:temp(?:orary)?\s+|unlogged\s+|materialized\s+|recursive\s+)*(?:function|procedure|table|view|type|domain|trigger|policy|index|sequence)\s+(?:if\s+(?:not\s+)?exists\s+)?("?[\w.]+"?)(?:[^;]*?\bon\s+("?[\w.]+"?))?/gi)) {
    for (const n of [m[1], m[2]]) if (n) out.add(n.replace(/"/g, "").split(".").pop()!.toLowerCase());
  }
  return out;
};
// The SQL files (path → text) that matter to a scenario that touched `names`: those mentioning one, and
// then those mentioning a name the hot ones define or mention, until no more join. `wild` makes every file matter.
export function hotSql(files: Record<string, string>, names: string[], wild: boolean): string[] {
  if (wild) return Object.keys(files).sort();
  const hot = new Set<string>(), seen = new Set(names);
  const toks = Object.fromEntries(Object.entries(files).map(([f, t]) => [f, words(t)]));
  const everyDefined = new Set(Object.values(files).flatMap((t) => [...defined(t)]));
  for (let grew = true; grew;) {
    grew = false;
    for (const [f, t] of Object.entries(toks)) {
      if (hot.has(f) || ![...seen].some((n) => t.has(n))) continue;
      hot.add(f); grew = true;
      // What it defines, and what it mentions that some file defines (a trigger's function, a call).
      for (const d of defined(files[f])) seen.add(d);
      for (const w of t) if (everyDefined.has(w)) seen.add(w);
    }
  }
  return [...hot].sort();
}

// The key of what the scenarios' export holds beside `scenarios` (PRONTO-184), its fields in order.
export function sharedKey(exported: Record<string, unknown>): string {
  const { scenarios: _, ...rest } = exported;
  return sha(JSON.stringify(rest, (_k, v) => v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => a < b ? -1 : 1)) : v));
}

const fileURLToPath = (u: string) => new URL(u).pathname;
const hashOf = (p: string) => { try { return sha(Deno.readFileSync(p)); } catch { return "absent"; } };
const git = (root: string, ...args: string[]) => {
  const o = new Deno.Command("git", { args: ["-C", root, ...args], stdout: "piped", stderr: "null" }).outputSync();
  return o.success ? new TextDecoder().decode(o.stdout) : null;
};

// The app's files as git lists them (tracked and untracked, not ignored: what the local gate's
// ledger keys, pronto's gcp/local-gate-key.nu), each with its content, as they are now; null where
// git cannot list them, and then nothing is cached.
function treeKey(root: string): string | null {
  const listed = new Deno.Command("git", { args: ["-C", root, "ls-files", "-co", "--exclude-standard", "-z"], stdout: "piped", stderr: "null" }).outputSync();
  if (!listed.success) return null;
  const lines: string[] = [];
  for (const rel of new TextDecoder().decode(listed.stdout).split("\0").filter(Boolean).sort()) {
    if (rel.split("/").some((n) => apart.includes(n)) || apartPrefix.some((x) => rel === x || rel.startsWith(x)) || history.test(rel)) continue;
    if (rel.startsWith("tests/scenarios/") && rel.endsWith(".cue")) continue;
    lines.push(`${rel} ${hashOf(join(root, rel))}`);
  }
  // The pins of the directories above the app, up to the repository's top.
  for (let d = dirname(root); ; d = dirname(d)) {
    for (const f of pins) lines.push(`above ${relative(root, join(d, f))} ${hashOf(join(d, f))}`);
    try { Deno.statSync(join(d, ".git")); break; } catch { /* higher */ }
    if (dirname(d) === d) break;
  }
  return sha(lines.join("\n"));
}

// The files that differ from where the branch left main (committed, staged, unstaged, new), as
// paths relative to the app, or `../…` for a file outside it; null where git cannot say.
function changedFiles(root: string): string[] | null {
  const top = git(root, "rev-parse", "--show-toplevel")?.trim();
  if (!top) return null;
  let base: string | null = null;
  for (const ref of [Deno.env.get("SCENARIOS_BASE") ?? "origin/main", "main"]) {
    base = git(root, "merge-base", ref, "HEAD")?.trim() || null;
    if (base) break;
  }
  if (!base) return null;
  const diff = git(root, "diff", "--name-only", "--no-renames", "-z", base);
  const fresh = git(root, "ls-files", "-o", "--exclude-standard", "-z");
  if (diff === null || fresh === null) return null;
  const topReal = Deno.realPathSync(top);
  return [...new Set([...diff.split("\0"), ...fresh.split("\0")].filter(Boolean))]
    .map((f) => relative(root, join(topReal, f)))
    .filter((rel) => !rel.split("/").some((n) => apart.includes(n)) && !history.test(rel));
}

// `runner` is the runner's import.meta.url; `url` the door it runs against; `client`, the path
// prefixes (relative to the app) of sources whose only effect on a scenario is the static assets it
// loads; `more.derived`, the prefixes of sources that only build a generated file (judged in its turn) and
// `more.inert`, regular expressions (as strings) of files no scenario can see (release and deploy files).
// `more.live`, regular expressions of files the app runs while a scenario does, though the shared list above
// calls them inert (Studio's Publish starts a game through tests/slot.ts: PRONTO-291, found by no scenario).
export function select<S extends Keyed>(runner: string, url: string, scenarios: S[], client: string[] = [], more: { derived?: string[]; inert?: string[]; live?: string[] } = {}) {
  const appDir = Deno.realPathSync(new URL("..", runner).pathname);
  const root = Deno.env.get("PRONTO_GATE_DIR") ? Deno.realPathSync(Deno.env.get("PRONTO_GATE_DIR")!) : appDir;
  const local = ["localhost", "127.0.0.1"].includes(new URL(url).hostname);
  // SCENARIOS_REUSE (the rehearsal's, tests/rehearse.ts): the exact-tree records only, no diff: a scenario already
  // green on this very tree, slowed as it is slowed now, is not run again.
  const reuse = !!Deno.env.get("SCENARIOS_REUSE") && local;
  const gate = (Deno.env.get("INTEGRATE_LOCAL_DRIVERS") === "all" && local) || reuse;
  const all = !!Deno.env.get("SCENARIOS_ALL");
  const none = {
    run: scenarios,
    cached: [] as S[],
    observe: (_id: string, _method: string, _path: string, _body?: string) => {},
    verify: async (_get: (path: string) => Promise<string | null>) => {},
    commit: (_ran: string[], _failed: string[]) => {},
  };
  if (!gate) return none;
  const ledger = join(Deno.env.get("HOME") ?? "/tmp", ".cache", "pronto", "scenarios", basename(root));
  const own = [fileURLToPath(runner), join(dirname(fileURLToPath(runner)), "scenarios", "select.ts"), join(dirname(fileURLToPath(runner)), "scenarios", "schema.cue"), join(dirname(fileURLToPath(runner)), "slow.ts")];
  // What the scenarios' CUE holds beside the scenarios (a stand-in's image, a shared constant the stack or the
  // runner reads, not a scenario's steps): the package's export less `scenarios`, an input of every scenario.
  // The scenarios' files are left out of the tree, so without it a stand-in moved from one version to another
  // left every scenario "cached" (Ume's identity broker 0.2.3 → 0.2.4, PRONTO-184). Null when it does not
  // export, and then nothing is cached.
  const shared = (() => {
    const dir = join(dirname(fileURLToPath(runner)), "scenarios");
    let files: string[];
    try { files = [...Deno.readDirSync(dir)].filter((f) => f.isFile && f.name.endsWith(".cue")).map((f) => join(dir, f.name)).sort(); } catch { return null; }
    const o = new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["export", ...files, "--out", "json"], stdout: "piped", stderr: "null" }).outputSync();
    if (!o.success) return null;
    return sharedKey(JSON.parse(new TextDecoder().decode(o.stdout)));
  })();
  if (shared === null) return none;
  const env = () => sha([`deno ${Deno.version.deno}`, `slow ${Deno.env.get("SLOW") ?? ""}${Deno.env.get("SLOW_GATE") ? " gate" : ""}`, `shared ${shared}`, ...own.map(hashOf)].join("\n"));
  // What the app's tree does not hold but its stack may serve: the files outside it that differ from main
  // and are not documentation (another app's files, a stand-in's version), by content. So a change there
  // is never "cached green" (it hid Ume's refused and bureau-cap, 2026-11-03).
  const outside = () => (changedFiles(root) ?? []).filter((f) => f.startsWith("../") && !/\.md$/.test(f) && !/^\.\.\/\.\.\/(docs|\.github)\//.test(f)).sort().map((f) => `outside ${f} ${hashOf(join(root, f))}`);
  const tree = () => {
    const t = treeKey(root);
    return t && sha([t, env(), ...outside()].join("\n"));
  };
  const before = tree();
  if (!before) return none;
  const stepsOf = (s: S) => sha(JSON.stringify(s));
  const keyOf = (s: S) => sha(before + JSON.stringify(s));
  // One record per scenario and per runner/toolchain (`env`): a gate of another checkout, ci's, a rehearsal's, each
// with its own runner file, would overwrite one shared record and make every other's miss ("another runner").
const recordOf = (id: string) => join(ledger, `${id}.${envNow.slice(0, 12)}`);
  const last = (s: S) => { try { return JSON.parse(Deno.readTextFileSync(recordOf(s.id))) as Record_; } catch { return null; } };
  const observed = new Map<string, { served: Set<string>; assets: Map<string, string> }>();
  const seen = (id: string) => { let o = observed.get(id); if (!o) observed.set(id, o = { served: new Set(), assets: new Map() }); return o; };

  // The app's SQL files, read once, when a changed one is judged; null where they cannot be listed.
  let sqlRead: Record<string, string> | null | undefined;
  const sqlFiles = () => {
    if (sqlRead !== undefined) return sqlRead;
    const listed = git(root, "ls-files", "-co", "--exclude-standard", "*.sql");
    if (listed === null) return sqlRead = null;
    sqlRead = {};
    for (const rel of listed.split("\n").filter(Boolean)) if (!rel.split("/").some((n) => apart.includes(n))) try { sqlRead[rel] = Deno.readTextFileSync(join(root, rel)); } catch { /* removed */ }
    return sqlRead;
  };
  const cached: S[] = [], run: S[] = [];
  const pending: { s: S; assets: Record<string, string>; byBytes: boolean }[] = [];
  const diff = all || reuse ? null : changedFiles(root);
  const envNow = env();
  for (const s of scenarios) {
    const l = last(s);
    if (!all && l?.key === keyOf(s)) {
      cached.push(s);
      console.log(`- ${s.id}: cached, it was green on these inputs at ${l.at} (SCENARIOS_ALL=1 runs it)`);
      continue;
    }
    const verdict = all || reuse ? "" : !diff ? "git cannot say what changed since main" : !l ? "it has no record of a green run" : skippable(l, s, diff);
    if (verdict === true || (typeof verdict === "object")) pending.push({ s, assets: l!.assets ?? {}, byBytes: typeof verdict === "object" });
    else { run.push(s); if (!all && diff) console.log(`- ${s.id}: runs, ${verdict}`); }
  }

  // true: no changed file concerns the scenario; {…}: only client sources do, judged by bytes.
  function skippable(l: Record_, s: S, files: string[]): true | { client: string[] } | string {
    if (l.env !== envNow) return "its record is of another runner, schema, SLOW, Deno or shared scenario CUE";
    if (l.steps !== stepsOf(s)) return "its steps changed";
    const served = (l.served ?? []).map((x) => x.slice(x.indexOf(" ") + 1));
    const clientFiles: string[] = [];
    for (const f of files) {
      if (f.startsWith("../")) {
        if (/\.md$/.test(f) || /^\.\.\/\.\.\/(docs|\.github)\//.test(f) || /^\.\.\/\.\.\/AGENTS\.md$/.test(f)) continue;
        return `${f.replace(/^(\.\.\/)+/, "")} is outside the app`;
      }
      if ((more.live ?? []).some((r) => new RegExp(r).test(f))) return `${f} is run by the app while the scenario does`;
      if (inert.some((r) => r.test(f)) || (more.inert ?? []).some((r) => new RegExp(r).test(f))) continue;
      if (everything.some((r) => r.test(f))) return `${f} is the runner's, a helper, a fixture or a pin`;
      if (client.some((c) => f.startsWith(c.replace(/\*$/, "")))) {
        // Judged by bytes only where the asset is one the runner records (audio is not).
        if (!staticAsset.test(f)) return `${f} is a client source whose bytes are not judged`;
        clientFiles.push(f);
        continue;
      }
      if ((more.derived ?? []).some((d) => f.startsWith(d.replace(/\*$/, "")))) continue;
      if (f.endsWith(".sql")) {
        const sql = sqlFiles();
        const t = touched(l.served ?? []);
        if (!sql || !(f in sql)) return `${f} is SQL that cannot be read`;
        const hot = hotSql(sql, t.names, t.wild);
        if (hot.includes(f)) return `${f} mentions what it called in the database (${t.wild ? "a shape of any table" : t.names.filter((n) => words(sql[f]).has(n)).join(", ") || "a name another SQL file it reads defines"})`;
        continue;
      }
      const name = basename(f);
      if (served.some((p) => p.split("?")[0].replace(/^\//, "") === f || f.endsWith("/" + p.split("?")[0].replace(/^\//, "")) || (name.includes(".") && basename(p.split("?")[0]) === name))) return `${f} is named by a request it made`;
      return `${f} is attributed to no scenario`;
    }
    if (!clientFiles.length) return true;
    return Object.keys(l.assets ?? {}).length ? { client: clientFiles } : `${clientFiles[0]} is a client source and it recorded no asset`;
  }

  return {
    run,
    cached,
    // A page's request, and for a static asset the hash of its body, as the runner saw it.
    observe(id: string, method: string, path: string, body?: string) {
      const o = seen(id);
      o.served.add(`${method} ${path}`);
      if (method === "GET" && body && staticAsset.test(path.split("?")[0])) o.assets.set(path.split("?")[0], body);
    },
    // Judges the client sources by bytes: `get` answers a path's body hash on the live stack (null
    // where it does not answer). A scenario whose recorded assets are all as served is skipped, any
    // other runs. Call it once, before the queue is made; it moves scenarios into `run`.
    async verify(get: (path: string) => Promise<string | null>) {
      const fetched = new Map<string, string | null>();
      for (const { s, assets, byBytes } of pending) {
        let why = "";
        if (byBytes) {
          for (const [p, h] of Object.entries(assets)) {
            if (!fetched.has(p)) fetched.set(p, await get(p).catch(() => null));
            if (fetched.get(p) !== h) { why = `${p} is not as served at its last green run`; break; }
          }
        }
        if (why) { run.push(s); console.log(`- ${s.id}: runs, ${why}`); }
        else {
          cached.push(s);
          console.log(`- ${s.id}: skipped, ${byBytes ? "the client assets it loaded are as at its last green run and no other changed file concerns it" : "no file changed since main concerns it"} (SCENARIOS_ALL=1 runs it)`);
        }
      }
      pending.length = 0;
    },
    // Records the scenarios that ran green and forgets the ones that failed, but only on the tree the
    // run started from.
    commit(ran: string[], failed: string[]) {
      for (const id of failed) try { Deno.removeSync(recordOf(id)); } catch { /* none */ }
      if (tree() !== before) { console.log("scenarios: the tree changed during the run: no scenario is recorded green"); return; }
      Deno.mkdirSync(ledger, { recursive: true });
      for (const s of scenarios.filter((x) => ran.includes(x.id))) {
        const o = seen(s.id);
        const rec: Record_ = { key: keyOf(s), at: new Date().toISOString(), steps: stepsOf(s), env: envNow, served: [...o.served].sort(), assets: Object.fromEntries([...o.assets].sort()) };
        Deno.writeTextFileSync(recordOf(s.id), JSON.stringify(rec));
      }
    },
  };
}
