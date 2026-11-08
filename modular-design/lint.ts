// The lint of an app's modules (modules/modules.cue), run in `test`: `deno run --allow-read --allow-run --allow-env modules/lint.ts`
// from the app's folder. It fails when
//   - a module imports another module's CUE (only the schema is imported; any other module is read through its export),
//   - two modules own overlapping paths (`owns`: dotted paths of the app's data, where a segment may be `*`, `a|b` or
//     a range `1-9`, and a path owns everything under it),
//   - `needs` has a cycle, names a module that is not listed, or a folder under modules/ is not listed.
// Written by pronto-modular-design (modular-design/lint.ts in pronto-plugins): regenerated, do not edit.

type Module = { needs: string[]; owns: string[] };

const cue = Deno.env.get("CUE") ?? "cue";
const out = await new Deno.Command(cue, { args: ["export", "./modules", "--out", "json"], stdout: "piped", stderr: "piped" }).output();
if (!out.success) {
  console.error(`modules/modules.cue: ${new TextDecoder().decode(out.stderr)}`);
  Deno.exit(1);
}
const modules: Record<string, Module> = JSON.parse(new TextDecoder().decode(out.stdout)).modules;
const names = Object.keys(modules);
const problems: string[] = [];

// The module path of the app (cue.mod/module.cue), without its major version.
const mod = (await Deno.readTextFile("cue.mod/module.cue")).match(/^module:\s*"([^"@]+)/m)?.[1];
if (!mod) problems.push("cue.mod/module.cue names no module");

// Folders under modules/ that hold CUE are modules, and are listed.
for await (const e of Deno.readDir("modules")) {
  if (e.isDirectory && !names.includes(e.name) && e.name !== "deps") problems.push(`modules/${e.name} is not listed in modules/modules.cue`);
}

// A module imports only the schema as CUE.
for (const name of names) {
  const dir = `modules/${name}`;
  let files: string[] = [];
  try {
    files = [...Deno.readDirSync(dir)].filter((f) => f.isFile && f.name.endsWith(".cue")).map((f) => `${dir}/${f.name}`);
  } catch {
    if (name !== "schema") problems.push(`${dir} does not exist`);
  }
  for (const f of files) {
    const text = await Deno.readTextFile(f);
    for (const m of text.matchAll(/"([^"\n]+)"/g)) {
      const path = m[1];
      const other = mod && path.startsWith(`${mod}/modules/`) ? path.slice(`${mod}/modules/`.length).split(/[:/]/)[0] : null;
      if (other && other !== "schema" && other !== name) problems.push(`${f} imports the CUE of module ${other}: read its export (deps/${other}.json) instead`);
    }
  }
}

// `needs` names listed modules and has no cycle.
for (const name of names) {
  for (const d of modules[name].needs) if (!names.includes(d)) problems.push(`${name} needs ${d}, which is not listed`);
}
const state: Record<string, number> = {};
const visit = (n: string, path: string[]) => {
  if (state[n] === 2) return;
  if (state[n] === 1) {
    problems.push(`needs has a cycle: ${[...path.slice(path.indexOf(n)), n].join(" -> ")}`);
    return;
  }
  state[n] = 1;
  for (const d of modules[n]?.needs ?? []) if (names.includes(d)) visit(d, [...path, n]);
  state[n] = 2;
};
for (const n of names) visit(n, []);

// A segment of an `owns` path, as the set of names it stands for (null: any).
const seg = (s: string): Set<string> | null => {
  if (s === "*") return null;
  const out = new Set<string>();
  for (const alt of s.split("|")) {
    const r = alt.match(/^(\d+)-(\d+)$/);
    if (r) for (let i = Number(r[1]); i <= Number(r[2]); i++) out.add(String(i));
    else out.add(alt);
  }
  return out;
};
const meet = (a: string, b: string) => {
  const x = seg(a), y = seg(b);
  return x === null || y === null || [...x].some((v) => y.has(v));
};
// Two paths overlap when, over the length of the shorter, every segment can be the same.
const overlap = (a: string, b: string) => {
  const p = a.split("."), q = b.split(".");
  return p.slice(0, Math.min(p.length, q.length)).every((s, i) => meet(s, q[i]));
};
for (let i = 0; i < names.length; i++) {
  for (let j = i + 1; j < names.length; j++) {
    for (const a of modules[names[i]].owns) {
      for (const b of modules[names[j]].owns) {
        if (overlap(a, b)) problems.push(`${names[i]} owns ${a} and ${names[j]} owns ${b}: two modules never write the same field`);
      }
    }
  }
}

if (problems.length) {
  console.error(problems.map((p) => `modules: ${p}`).join("\n"));
  Deno.exit(1);
}
console.log(`modules: ${names.length} modules, no cross-module import, no overlap, no cycle`);
