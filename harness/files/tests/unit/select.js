// Which suites tests/unit.ts may skip: a suite whose inputs hash as they did at its last green
// run is reported cached and not run, as Bazel skips a test whose inputs it has seen pass.
// A suite's inputs are the runner (unit.ts, this file, schema.cue), its own cases as exported, the
// app's lockfiles and Deno, the modules its cases can reach and what the run itself read: the
// files, directories, environment and commands seen through Deno while the suite ran.
// Every app's copy of this file is the same, as unit.ts and schema.cue are (AGENTS.md); its
// cases are brawl-chess's `selection` suite.
import { createHash } from "node:crypto";

export const sha = (data) => createHash("sha256").update(data).digest("hex");

// The namespaces a suite's cases call ("chess.perft" calls chess), through `map` too.
export function called(cases) {
  const names = new Set();
  const visit = (act) => {
    if (!act || typeof act !== "object") return;
    if (typeof act.call === "string") names.add(act.call.split(".")[0]);
    if (act.map) visit(act.map);
  };
  for (const c of cases) for (const step of c.steps) visit(step);
  return [...names].sort();
}

// Each import of the registry's source, with the namespace it becomes when that is plain:
// `import * as chess from 'x'`, `r.gold = await import('x')`, `apps: () => import('x')`. Any
// other import (named, bare, into a variable) has no namespace: its module is always an input.
export function imports(source) {
  const found = [];
  for (const m of source.matchAll(/import\s+([^'"();]*?)\s*from\s*['"]([^'"]+)['"]/g)) {
    const ns = m[1].trim().match(/^\*\s+as\s+([A-Za-z_$][\w$]*)$/);
    found.push({ spec: m[2], ns: ns ? ns[1] : null });
  }
  for (const m of source.matchAll(/(?:^|[;\n])\s*import\s*['"]([^'"]+)['"]/g)) found.push({ spec: m[1], ns: null });
  for (const m of source.matchAll(/import\(\s*['"]([^'"]+)['"]\s*\)/g)) {
    const before = source.slice(source.lastIndexOf("\n", m.index) + 1, m.index);
    const ns = before.match(/(?:\.([A-Za-z_$][\w$]*)\s*=|(?:^|[{,\s])([A-Za-z_$][\w$]*)\s*:)\s*(?:\(\s*\)\s*=>\s*)?(?:await\s+)?$/);
    found.push({ spec: m[1], ns: ns ? (ns[1] ?? ns[2]) : null });
  }
  // A namespace the registry itself reads (`r.match` handed to another module's load) or passes
  // to a call is used whatever the cases call: its module is always an input.
  const used = (ns) => new RegExp(`\\.${ns}\\b(?!\\s*=[^=])|\\(\\s*${ns}\\s*[,)]|,\\s*${ns}\\s*\\)`).test(source);
  return found.map((f) => (f.ns && used(f.ns) ? { ...f, ns: null } : f));
}

// The registry's imports a suite needs: all but those whose every import names a namespace its
// cases never call. A specifier the source does not show plainly is kept.
export function needed(specs, found, calls) {
  const call = new Set(calls);
  return specs.filter((spec) => {
    const of = found.filter((f) => f.spec === spec);
    return of.length === 0 || of.some((f) => f.ns === null || call.has(f.ns));
  });
}

// The modules reachable from the roots in a module graph ({specifier: [specifier, ...]}).
export function reach(graph, roots) {
  const seen = new Set();
  const todo = [...roots];
  while (todo.length) {
    const at = todo.pop();
    if (seen.has(at)) continue;
    seen.add(at);
    for (const next of graph[at] ?? []) todo.push(next);
  }
  return [...seen].sort();
}

// One key for a list of input lines, whatever their order.
export const key = (lines) => sha([...new Set(lines)].sort().join("\n"));

// The name a suite's record goes by: its static inputs, so a record is only ever looked up by
// the trees whose cases, runner, toolchain and modules are these.
export const slotOf = (base) => key(base);

// A record holds for these inputs only when its key is theirs, observed part included: a record
// another tree wrote for other inputs, or a half-written one, never does.
export const holds = (last, now) => !!last && typeof last.key === "string" && key(now) === last.key;
