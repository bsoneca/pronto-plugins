// The unit cases (tests/unit/*.cue, their schema says the steps) run as Deno tests: one test a
// case, its steps in order on one value. Run by the `test` verb (program.cue), a suite at a time:
//   deno test --allow-read --allow-env --allow-run tests/unit.ts -- <suite>
// A suite whose inputs are as at its last green run is reported cached and not run (select.js,
// docs/test-selection.md); `-- <suite> --all` or UNIT_ALL=1 runs it anyway.
// A suite the app gives jobs (suites.cue) runs its cases over that many processes at once, each
// every n-th case ("-- <suite> <k>/<n>" runs the k-th share alone).
// Every app's copy of this file, tests/unit/select.js and tests/unit/schema.cue is the same; what
// an app's cases call is its own tests/unit/registry.js, and its suites its tests/unit/suites.cue.
import { called, holds, imports, key, needed, reach, sha, slotOf } from "./unit/select.js";
import { dirname, relative, resolve } from "node:path";
import { tmpdir } from "node:os";

const all = Deno.args.includes("--all") || !!Deno.env.get("UNIT_ALL");
const [suite, share] = Deno.args.filter((a) => a !== "--all");
if (!suite) throw new Error("name the suite (tests/unit/suites.cue)");
const dir = new URL("./unit/", import.meta.url).pathname;
// A unit test is a case here, never code: a *.test.* file beside them fails every suite.
const coded = [...Deno.readDirSync(new URL(".", import.meta.url))].filter((f) => /\.test\.[jt]s$/.test(f.name)).map((f) => f.name);
if (coded.length) throw new Error(`write these as cases in tests/unit/*.cue: ${coded.join(", ")}`);
const files = [...Deno.readDirSync(dir)].filter((f) => f.name.endsWith(".cue")).map((f) => dir + f.name).sort();
// The parent evaluates the cases once, vet and export side by side, and hands them to its child
// (and to each share's child) in a scratch file: the child runs this file's top level again and
// must not evaluate the CUE a second time (UNIT_CASES_FROM).
const casesFrom = Deno.env.get("UNIT_CASES_FROM");
let exportedText: string;
if (casesFrom) exportedText = Deno.readTextFileSync(casesFrom);
else {
  const cue = (args: string[]) => new Deno.Command(Deno.env.get("CUE") ?? "cue", { args, stdout: "piped", stderr: "piped" }).output();
  const [out, exported] = await Promise.all([
    cue(["vet", "-c", ...files]),
    cue(["export", ...files, "-e", "{c: cases, j: jobs}", "--out", "json"]),
  ]);
  if (!out.success) throw new Error("the cases do not meet their schema:\n" + new TextDecoder().decode(out.stderr));
  if (!exported.success) throw new Error(new TextDecoder().decode(exported.stderr));
  exportedText = new TextDecoder().decode(exported.stdout);
}
const { c: cases, j: jobs }: { c: Record<string, { suite: string; steps: Step[] }>; j: Record<string, number> } = JSON.parse(exportedText);
// This process's share of the suite, the k-th of n: every case of it when no share is named.
const [k, n] = share ? share.split("/").map(Number) : [0, 1];
const mine = Object.entries(cases).filter(([, c]) => c.suite === suite).filter((_, i) => i % n === k);
// A suite with no cases ran nothing, and nothing run is not green: a misspelt suite fails here.
if (!Object.values(cases).some((c) => c.suite === suite)) throw new Error(`no cases ran: the suite "${suite}" has none in tests/unit/*.cue`);

// --- Selection: the suite's inputs, and its last green run's (.task/unit/<suite>/<slot>.json). ---
const app = new URL("../", import.meta.url).pathname;
// A record is named by the hash of the suite's static inputs (cases, runner, toolchain, modules),
// so trees that differ there never meet in one file, and it is written whole (temp file, rename):
// jobs on other trees may share the folder (ci keeps one per project on the runner machine).
const recordIn = (base: string[]) => `${app}.task/unit/${suite}/${slotOf(base)}.json`;
const rel = (p: string) => relative(app, p) || ".";
// Deno's own calls, kept before the child watches them (below), for the runner's own hashing.
const fs = { readFileSync: Deno.readFileSync.bind(Deno), statSync: Deno.statSync.bind(Deno), readDirSync: Deno.readDirSync.bind(Deno), env: Deno.env.get.bind(Deno.env) };
const hashOf = (p: string) => { try { return sha(fs.readFileSync(p)); } catch { return "absent"; } };
const registryUrl = new URL("./unit/registry.js", import.meta.url).href;
// The modules its cases can reach: the registry's imports but those of namespaces never called.
function modules(): string[] | null {
  const info = new Deno.Command(Deno.execPath(), { args: ["info", "--json", registryUrl], cwd: app, stdout: "piped", stderr: "null" }).outputSync();
  if (!info.success) return null;
  // deno-lint-ignore no-explicit-any
  const { modules: ms, redirects }: { modules: any[]; redirects: Record<string, string> } = JSON.parse(new TextDecoder().decode(info.stdout));
  const to = (s: string) => redirects[s] ?? s;
  const graph: Record<string, string[]> = {};
  // deno-lint-ignore no-explicit-any
  const byUrl: Record<string, any> = {};
  for (const m of ms) {
    byUrl[m.specifier] = m;
    // deno-lint-ignore no-explicit-any
    graph[m.specifier] = (m.dependencies ?? []).map((d: any) => d.code?.specifier).filter(Boolean).map(to);
  }
  // deno-lint-ignore no-explicit-any
  const deps: any[] = byUrl[registryUrl]?.dependencies ?? [];
  const keep = needed(deps.map((d) => d.specifier), imports(Deno.readTextFileSync(new URL(registryUrl))), called(mine.map(([, c]) => c)));
  const roots = deps.filter((d) => keep.includes(d.specifier) && d.code?.specifier).map((d) => to(d.code.specifier));
  return [registryUrl, ...reach(graph, roots).filter((s) => s !== registryUrl)].map((s) => {
    const m = byUrl[s];
    if (s.startsWith("file:")) return `module ${rel(decodeURIComponent(new URL(s).pathname))} ${hashOf(decodeURIComponent(new URL(s).pathname))}`;
    return m?.local ? `module ${s} ${hashOf(m.local)}` : `module ${s}`;
  });
}
function fixed(): string[] | null {
  const graph = modules();
  if (!graph) return null;
  const perms = ["read", "write", "env", "run", "net", "sys", "ffi"].map((name) => `${name}=${Deno.permissions.querySync({ name } as Deno.PermissionDescriptor).state}`);
  return [
    `suite ${suite}`,
    `cases ${sha(JSON.stringify(mine))}`,
    `jobs ${jobs[suite] ?? 1}`,
    ...["tests/unit.ts", "tests/unit/select.js", "tests/unit/schema.cue", "mise.lock", "deno.json", "deno.jsonc", "deno.lock", "package.json"].map((f) => `file ${f} ${hashOf(app + f)}`),
    `deno ${Deno.version.deno}`,
    `args ${JSON.stringify(Deno.args.filter((a) => a !== "--all"))}`,
    `allow ${perms.join(" ")}`,
    `env CUE ${sha(Deno.env.get("CUE") ?? "")}`,
    ...graph,
  ];
}
// What a run saw, kind by kind, each path or name with its value when first seen: a file's content,
// a directory's names, a path's kind, a variable's value, a tree's files (a directory a command
// was given), a command's line.
type Seen = Record<"read" | "dir" | "stat" | "env" | "tree", Record<string, string>> & { cmd: string[]; open?: string };
const kindOf = (p: string) => { try { const st = fs.statSync(p); return st.isFile ? "file" : st.isDirectory ? "dir" : "other"; } catch { return "absent"; } };
const valueOf: Record<keyof Omit<Seen, "cmd" | "open">, (p: string) => string> = {
  read: (p) => kindOf(p) === "dir" ? "dir" : hashOf(p),
  dir: (p) => { try { return sha([...fs.readDirSync(p)].map((e) => `${e.name}${e.isDirectory ? "/" : ""}`).sort().join("\n")); } catch { return "absent"; } },
  stat: kindOf,
  env: (n) => sha(fs.env(n) ?? ""),
  // Every file under it but dependencies, history and scratch; past 20000 files, never the same.
  tree: (p) => {
    const found: string[] = [];
    const walk = (d: string) => {
      for (const e of fs.readDirSync(d)) {
        if ([".git", "node_modules", ".task", "dist", ".certs"].includes(e.name)) continue;
        if (found.length > 20000) return;
        if (e.isDirectory) walk(`${d}/${e.name}`);
        else if (e.isFile) found.push(`${d}/${e.name}`);
      }
    };
    try { walk(p); } catch { return "absent"; }
    return found.length > 20000 ? `too-many ${Math.random()}` : sha(found.sort().map((f) => `${relative(p, f)} ${hashOf(f)}`).join("\n"));
  },
};
const linesOf = (s: Seen) => [
  ...(["read", "dir", "stat", "env", "tree"] as const).flatMap((k) => Object.entries(s[k]).map(([p, v]) => `${k} ${k === "env" ? p : rel(p)} ${v}`)),
  ...s.cmd.map((c) => `cmd ${c}`),
];
// The same paths and names as they are now.
const linesNow = (s: Seen) => linesOf({
  ...s,
  ...Object.fromEntries((["read", "dir", "stat", "env", "tree"] as const).map((k) => [k, Object.fromEntries(Object.keys(s[k]).map((p) => [p, valueOf[k](p)]))])),
} as Seen);
// The record lives under .task/, which git and bayt's sources leave out. The suites run without
// --allow-write, so it is written by a deno child, which may write (`deno eval`). A file appears
// whole or not at all (written beside, then renamed); `prune` also drops what a week has not touched.
function persist(path: string, content: string | null, prune = false) {
  const to = JSON.stringify(path);
  const code = content === null
    ? `try { Deno.removeSync(${to}); } catch { /* none */ }`
    : `const d = ${JSON.stringify(dirname(path))}; Deno.mkdirSync(d, { recursive: true }); const t = ${to} + "." + crypto.randomUUID() + ".tmp"; Deno.writeTextFileSync(t, await new Response(Deno.stdin.readable).text()); Deno.renameSync(t, ${to});`
      + (prune ? ` for (const e of [...Deno.readDirSync(d)]) { try { if (Date.now() - Deno.statSync(d + "/" + e.name).mtime!.getTime() > 6048e5) Deno.removeSync(d + "/" + e.name); } catch { /* gone */ } }` : "");
  const child = new Deno.Command(Deno.execPath(), { args: ["eval", code], stdin: "piped", stdout: "null", stderr: "piped" }).spawn();
  const w = child.stdin.getWriter();
  return w.write(new TextEncoder().encode(content ?? "")).then(() => w.close()).then(() => child.output()).then((o) => {
    if (!o.success) console.warn(`could not keep ${rel(path)}: ${new TextDecoder().decode(o.stderr)}`);
  });
}

// The cases run in a child `deno test` of this file, its output this one's: the record is kept
// only when that child exits green, so a case failing after its last step (a leaked timer, an
// uncaught rejection) never leaves a green record. The child says what it saw in `observedTo`.
const observedTo = Deno.env.get("UNIT_OBSERVED_TO");
if (!observedTo) {
  const base = fixed();
  // deno-lint-ignore no-explicit-any
  let last: any = null;
  const record = base ? recordIn(base) : null;
  try { last = JSON.parse(Deno.readTextFileSync(record!)); } catch { /* never green here */ }
  if (!last?.observed?.read) last = null;
  if (base && last && !all) {
    const now = [...base, ...linesNow(last.observed)];
    if (holds(last, now)) {
      console.log(`${suite}: cached, its ${mine.length} cases were green on these inputs at ${last.at} (--all or UNIT_ALL=1 runs them)`);
      Deno.exit(0);
    }
    const before = new Set(last.lines ?? []);
    // A line is its kind, then the path or name it is about when it has one, then its value.
    const named = ["module", "file", "read", "dir", "stat", "env", "tree"];
    const changed = [...new Set(now.filter((l) => !before.has(l)).map((l) => { const [kind, what] = l.split(" "); return named.includes(kind) ? `${kind} ${what}` : kind; }))];
    console.log(`${suite}: runs, its inputs changed: ${changed.slice(0, 5).join(", ")}${changed.length > 5 ? `, and ${changed.length - 5} more` : ""}`);
  } else if (base) console.log(`${suite}: runs, ${all ? "every suite asked for" : "no green run kept"}`);
  else console.log(`${suite}: runs, its module graph could not be read (deno info)`);
  // A run forgets the last green one until it is green itself.
  // Its own scratch, in the temp dir: no other job's run shares a name with it.
  const pending = `${resolve(tmpdir())}/unit-${suite}-${crypto.randomUUID()}.pending`;
  if (record) await persist(record, null);
  const casesFile = `${pending}.cases`;
  await persist(casesFile, exportedText);
  const granted = ["read", "write", "env", "run", "net", "sys", "ffi"].filter((name) => Deno.permissions.querySync({ name } as Deno.PermissionDescriptor).state === "granted");
  // One child a share, each saying what it saw in its own file; one share is the whole suite.
  const shares = jobs[suite] ?? 1;
  const pendings = Array.from({ length: shares }, (_, i) => shares > 1 ? `${pending}.${i}` : pending);
  if (shares > 1) await Promise.all(pendings.map((to) => persist(to, null)));
  const children = pendings.map((to, i) => new Deno.Command(Deno.execPath(), {
    args: ["test", "--no-config", ...granted.map((p) => `--allow-${p}`), new URL(import.meta.url).pathname, "--", suite, ...(shares > 1 ? [`${i}/${shares}`] : [])],
    env: { UNIT_OBSERVED_TO: to, UNIT_CASES_FROM: casesFile },
    ...(shares > 1 ? { stdout: "piped", stderr: "piped" } : {}),
  }).spawn());
  const codes: number[] = [];
  for (const child of children) {
    if (shares === 1) { codes.push((await child.status).code); continue; }
    const o = await child.output();
    await Deno.stdout.write(o.stdout);
    await Deno.stderr.write(o.stderr);
    codes.push(o.code);
  }
  const code = codes.find((c) => c !== 0) ?? 0;
  if (code === 0 && base) {
    // Each share's snapshot; when one kept none, the run keeps none.
    const each = pendings.map((to): Seen | null => { try { return JSON.parse(Deno.readTextFileSync(to)); } catch { return null; } });
    const got: Seen | null = each.some((x) => !x) ? null : (each as Seen[]).reduce((a, b) => ({
      read: { ...b.read, ...a.read }, dir: { ...b.dir, ...a.dir }, stat: { ...b.stat, ...a.stat }, env: { ...b.env, ...a.env }, tree: { ...b.tree, ...a.tree },
      cmd: [...new Set([...a.cmd, ...b.cmd])].sort(), open: a.open ?? b.open,
    }));
    if (got?.open) console.log(`${suite}: green, not kept: ${got.open}`);
    else if (got) {
      const lines = [...base, ...linesOf(got)];
      await persist(record!, JSON.stringify({ key: key(lines), at: new Date().toISOString(), observed: got, lines }, null, 1), true);
    }
  }
  await Promise.all([...pendings, casesFile].map((to) => persist(to, null)));
  Deno.exit(code);
}

// --- The child: what the run reads, writes and spawns, seen through Deno from here on. ---
const temp = [resolve(tmpdir()), resolve(app, ".task")];
const seen: Seen = { read: {}, dir: {}, stat: {}, env: {}, tree: {}, cmd: [] };
const wrote = new Set<string>();
const envSet = new Set<string>();
const pathOf = (p: unknown) => {
  const s = p instanceof URL ? p.href : String(p);
  return s.startsWith("file:") ? decodeURIComponent(new URL(s).pathname) : resolve(Deno.cwd(), s);
};
// Seen before the call, so a read that fails (a file absent) is an input too.
const note = (k: keyof Omit<Seen, "cmd" | "open">, p: string) => { if (!(p in seen[k])) seen[k][p] = valueOf[k](p); };
// deno-lint-ignore no-explicit-any
const D = Deno as any;
// deno-lint-ignore no-explicit-any
const watch = (name: string, before: (args: any[]) => void, after?: (result: any) => void) => {
  const f = D[name].bind(Deno);
  // deno-lint-ignore no-explicit-any
  D[name] = (...args: any[]) => {
    before(args);
    const r = f(...args);
    // deno-lint-ignore no-explicit-any
    if (after && r instanceof Promise) return r.then((v: any) => (after(v), v));
    if (after) after(r);
    return r;
  };
};
for (const n of ["readTextFile", "readTextFileSync", "readFile", "readFileSync"]) watch(n, (a) => note("read", pathOf(a[0])));
for (const n of ["open", "openSync"]) watch(n, (a) => { const o = a[1] ?? {}; if (o.write || o.append || o.create || o.truncate || o.createNew) wrote.add(pathOf(a[0])); else note("read", pathOf(a[0])); });
for (const n of ["readDir", "readDirSync"]) watch(n, (a) => note("dir", pathOf(a[0])));
for (const n of ["stat", "statSync", "lstat", "lstatSync"]) watch(n, (a) => note("stat", pathOf(a[0])));
for (const n of ["writeTextFile", "writeTextFileSync", "writeFile", "writeFileSync", "mkdir", "mkdirSync", "remove", "removeSync", "create", "createSync"]) watch(n, (a) => wrote.add(pathOf(a[0])));
for (const n of ["makeTempDir", "makeTempDirSync", "makeTempFile", "makeTempFileSync"]) watch(n, () => {}, (r) => wrote.add(pathOf(r)));
// A variable the suite sets before it reads it is its own, not an input.
const env = Deno.env as unknown as Record<string, (...a: string[]) => unknown>;
for (const n of ["get", "has"]) { const f = env[n].bind(Deno.env); env[n] = (name: string) => { if (!envSet.has(name)) note("env", name); return f(name); }; }
for (const n of ["set", "delete"]) { const f = env[n].bind(Deno.env); env[n] = (name: string, ...rest: string[]) => { if (!(name in seen.env)) envSet.add(name); return f(name, ...rest); }; }
const local = (host: string) => ["localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0"].includes(host);
// What another machine answers is not an input it can hash: the suite keeps no record.
const remote = (what: string) => { seen.open ??= `it reached ${what}`; };
const Command = D.Command;
D.Command = class extends Command {
  // deno-lint-ignore no-explicit-any
  constructor(cmd: string | URL, opts?: any) {
    super(cmd, opts);
    const args = (opts?.args ?? []).map(String);
    const cwd = opts?.cwd ? pathOf(opts.cwd) : Deno.cwd();
    seen.cmd.push(JSON.stringify([String(cmd), args, rel(cwd), Object.keys(opts?.env ?? {}).sort().map((k) => `${k}=${sha(String(opts.env[k]))}`)]));
    // A file named in its arguments is read by it; a directory, every file under it.
    for (const a of args) {
      const p = resolve(cwd, a);
      const k = kindOf(p);
      if (k === "file") note("read", p);
      else if (k === "dir") note("tree", p);
    }
  }
};
const fetchOf = globalThis.fetch;
globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(input instanceof Request ? input.url : String(input));
  if (url.protocol === "file:") note("read", decodeURIComponent(url.pathname));
  else if (!local(url.hostname)) remote(url.host);
  return fetchOf(input, init);
};
for (const n of ["connect", "connectTls"]) watch(n, (a) => { if (a[0]?.hostname && !local(a[0].hostname)) remote(a[0].hostname); });
const WebSocketOf = globalThis.WebSocket;
globalThis.WebSocket = class extends WebSocketOf {
  constructor(url: string | URL, protocols?: ConstructorParameters<typeof WebSocket>[1]) {
    const host = new URL(String(url)).hostname;
    if (!local(host)) remote(host);
    super(url, protocols);
  }
};
const ours = (p: string) => temp.some((t) => p === t || p.startsWith(t + "/")) || [...wrote].some((w) => p === w || p.startsWith(w + "/"));
// What it saw, less its own scratch; a file that changed while it ran keeps nothing.
function snapshot(): Seen {
  const s: Seen = { read: {}, dir: {}, stat: {}, env: { ...seen.env }, tree: {}, cmd: [...new Set(seen.cmd)].sort(), open: seen.open };
  for (const k of ["read", "dir", "stat", "tree"] as const) {
    for (const [p, v] of Object.entries(seen[k])) {
      if (ours(p)) continue;
      if (valueOf[k](p) !== v) s.open ??= `${rel(p)} changed while it ran`;
      s[k][p] = v;
    }
  }
  return s;
}

const { registry: registryOf } = await import("./unit/registry.js");
type Step = Record<string, unknown>;
// deno-lint-ignore no-explicit-any
const registry: Record<string, any> = await registryOf(suite);

// deno-lint-ignore no-explicit-any
const fnOf = (name: string): (...a: any[]) => any => {
  const [ns, fn] = name.split(".");
  const f = registry[ns]?.[fn];
  if (typeof f !== "function") throw new Error(`no function ${name}`);
  return f;
};
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
// What of `got` `want` names (a `holds` check): an object's fields named, a list's elements one by
// one when as many, else `got` whole.
function named(got: unknown, want: unknown): unknown {
  if (Array.isArray(want)) return Array.isArray(got) && got.length === want.length ? got.map((g, i) => named(g, want[i])) : got;
  if (want && typeof want === "object" && got && typeof got === "object" && !Array.isArray(got)) {
    return Object.fromEntries(Object.keys(want).map((k) => [k, named((got as Record<string, unknown>)[k], (want as Record<string, unknown>)[k])]));
  }
  return got;
}
// "$" is the value, "$name" a kept one, anywhere in an argument.
function resolveArg(v: unknown, now: unknown, kept: Map<string, unknown>): unknown {
  if (v === "$") return now;
  if (typeof v === "string" && v.startsWith("$")) {
    const [name, ...path] = v.slice(1).split(".");
    if (kept.has(name)) return path.length ? at(kept.get(name), path.join(".")) : kept.get(name);
  }
  if (Array.isArray(v)) return v.map((x) => resolveArg(x, now, kept));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, resolveArg(x, now, kept)]));
  return v;
}
const at = (v: unknown, path: string | number): unknown =>
  String(path).split(".").reduce((x: any, k) => (x == null ? x : k === "length" ? x.length : x[k]), v);

async function act(step: Step, now: unknown, kept: Map<string, unknown>): Promise<unknown> {
  if ("throws" in step) {
    try { await fnOf(step.call as string)(...(resolveArg(step.args ?? [], now, kept) as unknown[])); } catch (e) {
      if (!new RegExp(step.throws as string).test(String((e as Error).message))) throw new Error(`threw "${(e as Error).message}", expected /${step.throws}/`);
      return now;
    }
    throw new Error(`${step.call} did not throw`);
  }
  if ("call" in step) return await fnOf(step.call as string)(...(resolveArg(step.args ?? [], now, kept) as unknown[]));
  if ("get" in step) return at(now, step.get as string);
  if ("pick" in step) return (step.pick as (string | number)[]).map((p) => at(now, p));
  if ("filter" in step) return (now as unknown[]).filter((x) => at(x, step.filter as string));
  if ("map" in step) {
    const outs = [];
    for (const x of now as unknown[]) outs.push(await act(step.map as Step, x, kept));
    return outs;
  }
  if ("keep" in step) { kept.set(step.keep as string, now); return now; }
  if ("use" in step) return kept.get(step.use as string);
  if ("value" in step) return resolveArg(step.value, now, kept);
  return now;
}

let green = 0;
for (const [name, c] of mine) {
  Deno.test(`${suite} > ${name}`, async () => {
    let now: unknown = undefined;
    const kept = new Map<string, unknown>();
    for (const [i, step] of c.steps.entries()) {
      now = await act(step, now, kept);
      const why = `step ${i + 1}${step.why ? ` (${step.why})` : ""}`;
      const want = resolveArg(step.expect, now, kept);
      if ("expect" in step && !same(now, want)) throw new Error(`${why}: expected ${JSON.stringify(want)}, got ${JSON.stringify(now)}`);
      if ("near" in step) {
        const { value, within } = step.near as { value: number; within: number };
        if (Math.abs((now as number) - value) > (within ?? 0.05)) throw new Error(`${why}: expected ${value} ± ${within}, got ${now}`);
      }
      const held = resolveArg(step.holds, now, kept);
      if ("holds" in step && !same(named(now, held), held)) throw new Error(`${why}: expected ${JSON.stringify(held)} in ${JSON.stringify(now)}`);
      if ("matches" in step && !new RegExp(step.matches as string).test(String(now))) throw new Error(`${why}: expected /${step.matches}/, got ${JSON.stringify(now)}`);
    }
    green++;
  });
}
// Last, after every case: what the run saw, for the parent to keep if the run ends green.
Deno.test(`${suite} > its inputs kept when every case is green`, async () => {
  if (green === mine.length) await persist(observedTo!, JSON.stringify(snapshot()));
});
