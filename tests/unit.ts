// The unit cases (tests/unit/*.cue, their schema says the steps) run as Deno tests: one test a
// case, its steps in order on one value. Run by the `test` verb (program.cue), a suite at a time:
//   deno test --allow-read --allow-env --allow-run tests/unit.ts -- <suite>
// Every app's copy of this file and of tests/unit/schema.cue is the same; what an app's cases
// call is its own tests/unit/registry.js, and its suites its tests/unit/suites.cue.
import { registry as registryOf } from "./unit/registry.js";

const suite = Deno.args[0];
if (!suite) throw new Error("name the suite (tests/unit/suites.cue)");
const dir = new URL("./unit/", import.meta.url).pathname;
// A unit test is a case here, never code: a *.test.* file beside them fails every suite.
const coded = [...Deno.readDirSync(new URL(".", import.meta.url))].filter((f) => /\.test\.[jt]s$/.test(f.name)).map((f) => f.name);
if (coded.length) throw new Error(`write these as cases in tests/unit/*.cue: ${coded.join(", ")}`);
const files = [...Deno.readDirSync(dir)].filter((f) => f.name.endsWith(".cue")).map((f) => dir + f.name).sort();
const out = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["vet", "-c", ...files], stdout: "piped", stderr: "piped" }).output();
if (!out.success) throw new Error("the cases do not meet their schema:\n" + new TextDecoder().decode(out.stderr));
const exported = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["export", ...files, "-e", "cases", "--out", "json"], stdout: "piped", stderr: "piped" }).output();
if (!exported.success) throw new Error(new TextDecoder().decode(exported.stderr));
const cases: Record<string, { suite: string; steps: Step[] }> = JSON.parse(new TextDecoder().decode(exported.stdout));

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
function resolve(v: unknown, now: unknown, kept: Map<string, unknown>): unknown {
  if (v === "$") return now;
  if (typeof v === "string" && v.startsWith("$")) {
    const [name, ...path] = v.slice(1).split(".");
    if (kept.has(name)) return path.length ? at(kept.get(name), path.join(".")) : kept.get(name);
  }
  if (Array.isArray(v)) return v.map((x) => resolve(x, now, kept));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, resolve(x, now, kept)]));
  return v;
}
const at = (v: unknown, path: string | number): unknown =>
  String(path).split(".").reduce((x: any, k) => (x == null ? x : k === "length" ? x.length : x[k]), v);

async function act(step: Step, now: unknown, kept: Map<string, unknown>): Promise<unknown> {
  if ("throws" in step) {
    try { await fnOf(step.call as string)(...(resolve(step.args ?? [], now, kept) as unknown[])); } catch (e) {
      if (!new RegExp(step.throws as string).test(String((e as Error).message))) throw new Error(`threw "${(e as Error).message}", expected /${step.throws}/`);
      return now;
    }
    throw new Error(`${step.call} did not throw`);
  }
  if ("call" in step) return await fnOf(step.call as string)(...(resolve(step.args ?? [], now, kept) as unknown[]));
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
  if ("value" in step) return resolve(step.value, now, kept);
  return now;
}

for (const [name, c] of Object.entries(cases)) {
  if (c.suite !== suite) continue;
  Deno.test(`${suite} > ${name}`, async () => {
    let now: unknown = undefined;
    const kept = new Map<string, unknown>();
    for (const [i, step] of c.steps.entries()) {
      now = await act(step, now, kept);
      const why = `step ${i + 1}${step.why ? ` (${step.why})` : ""}`;
      const want = resolve(step.expect, now, kept);
      if ("expect" in step && !same(now, want)) throw new Error(`${why}: expected ${JSON.stringify(want)}, got ${JSON.stringify(now)}`);
      if ("near" in step) {
        const { value, within } = step.near as { value: number; within: number };
        if (Math.abs((now as number) - value) > (within ?? 0.05)) throw new Error(`${why}: expected ${value} ± ${within}, got ${now}`);
      }
      const held = resolve(step.holds, now, kept);
      if ("holds" in step && !same(named(now, held), held)) throw new Error(`${why}: expected ${JSON.stringify(held)} in ${JSON.stringify(now)}`);
      if ("matches" in step && !new RegExp(step.matches as string).test(String(now))) throw new Error(`${why}: expected /${step.matches}/, got ${JSON.stringify(now)}`);
    }
  });
}
