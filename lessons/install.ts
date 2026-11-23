// Adds or refreshes pronto-lessons in a pronto app (bin/pronto-lessons):
//   install.ts <app-dir> [<module-path>] [--migration <name>]
// The app must hold pronto-flags (flags_plugin.cue): a course names a flag, and the database refuses a chapter whose flag is
// off for the account. Refused otherwise, with nothing written (every refusal is made before the first write).
// Regenerated every time, each marked as this host's: the LessonProgress entity, the migrations and the emitter's outputs
// (lessons_plugin.cue), the course schema (lessons_schema.cue, schema.cue as the app's package), the generate step
// (pronto/lessons.cue, lessons/lessons.nu), the functions (lessons/lessons.sql, a raw migration the app lists in
// `code: state: rawMigrations`, which lessons_plugin.cue does when the app lists none) and the page's engine at
// <module-path> (.js, .mjs or .ts; lessons/lessons.js unless named) with a commit stamp. Written once, then the app's own: its
// courses and the names stamped for its migrations (lessons_spec.cue), and a stub lessons_spec.js beside the module. The courses'
// own outputs are generate's: lessons/lessons_spec.sql, lessons_spec.js and the lines in messages/<locale>.json.
//
// Names. The two raw migrations are `<n>_lessons_spec.sql` and `<n+1>_lessons.sql`, n one more than the highest numbered raw
// migration the app's CUE lists (`name: "NNN_x.sql"`), at that width; at three digits the numbers stay below 800 (pronto reserves
// the 8xx, and 950_fixture.sql is its own): the next two above the highest below 800, else the two highest free ones below it,
// refused when fewer than two are free; the pgroll migration (`_lessonsMigration`) is `<m>_lessons`,
// m one more than the highest of the app's own pgroll names (`_xMigration: "NN_x"`, `migrations: "NN_x"`), at that width, or
// the name `--migration` gives (required when the app names none). They are stamped once into lessons_spec.cue and reused
// verbatim from then on, whatever the app adds later; a fresh install whose number needs more digits than the width is refused.
const here = new URL(".", import.meta.url).pathname;
const args = Deno.args.slice();
let migrationFlag: string | undefined;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--migration") { migrationFlag = args[i + 1]; args.splice(i, 2); break; }
  if (args[i].startsWith("--migration=")) { migrationFlag = args[i].slice(12); args.splice(i, 1); break; }
}
const [appArg, at = "lessons/lessons.js"] = args;
const fail = (m: string): never => { throw new Error(`pronto-lessons: ${m}`); };
if (!appArg || args.length > 2) fail("usage: install.ts <app-dir> [<module-path>] [--migration <name>]");
if (migrationFlag !== undefined && !/^[A-Za-z0-9_]+$/.test(migrationFlag)) fail(`--migration ${migrationFlag}: a name of letters, digits and underscores`);
const app = appArg.replace(/\/$/, "");
const program = await Deno.readTextFile(`${app}/program.cue`).catch(() => fail(`${app} has no program.cue: not a pronto app`));
const pkg = /^package\s+([a-z][a-z0-9_]*)\s*$/m.exec(program)?.[1];
if (!pkg) fail(`${app}/program.cue names no package`);
if (!/^[A-Za-z0-9_./-]+\.(m?js|ts)$/.test(at) || at.startsWith("/") || at.split("/").includes("..") || at.split("/").includes(".")) fail(`${at}: a .js, .mjs or .ts path inside the app`);
if (!await Deno.stat(`${app}/flags_plugin.cue`).catch(() => null)) {
  fail(`${app} has no pronto-flags (flags_plugin.cue): it needs it, a course's flag gates its chapters. Run bin/pronto-flags ${app} first.`);
}
const moduleDir = at.includes("/") ? at.slice(0, at.lastIndexOf("/")) : ".";
const inModuleDir = (f: string) => moduleDir === "." ? f : `${moduleDir}/${f}`;

// The app's CUE, comments dropped, but for the plugin's own files.
const mine = new Set(["lessons_plugin.cue", "lessons_spec.cue", "lessons_schema.cue"]);
const cue: string[] = [];
async function walk(rel: string) {
  for await (const e of Deno.readDir(rel ? `${app}/${rel}` : app)) {
    const p = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory) {
      if (!e.name.startsWith(".") && e.name !== "node_modules" && e.name !== "cue.mod") await walk(p);
    } else if (e.name.endsWith(".cue") && !(rel === "" && mine.has(e.name))) {
      cue.push((await Deno.readTextFile(`${app}/${p}`)).split("\n").map((l) => l.replace(/\/\/.*$/, "")).join("\n"));
    }
  }
}
await walk("");
const all = cue.join("\n");
const listed = (re: RegExp) => [...all.matchAll(re)].map((m) => ({ n: m[1], rest: m[2] }));
// The ones that sort apart (pronto's own fixture) are not the app's.
const raws = listed(/name:\s*"(\d+)(_[A-Za-z0-9_.]*\.sql)"/g).filter((m) => m.n + m.rest !== "950_fixture.sql");
// Three-digit raw names: pronto's schema reserves every name starting with 8 (but 802_signals.sql: the 8xx are not the app's to
// number after) and 950_fixture.sql, so the two names are free numbers below 800.
const rawNames = (): [string, string] => {
  const wide = raws.filter((m) => m.n.length === 3);
  if (!wide.length) return [`${next(raws, 1)}_lessons_spec.sql`, `${next(raws, 2)}_lessons.sql`];
  const used = new Set(wide.map((m) => Number(m.n)).filter((n) => n < 800));
  const top = used.size ? Math.max(...used) : 99;
  let pair: number[];
  if (top + 2 <= 799) pair = [top + 1, top + 2];
  else {
    const free: number[] = [];
    for (let n = 799; n >= 0 && free.length < 2; n--) if (!used.has(n)) free.push(n);
    if (free.length < 2) fail(`the app's three-digit raw migrations leave no two free numbers below 800 (pronto reserves the 8xx): name them in lessons_spec.cue by hand`);
    pair = free.reverse();
  }
  const [a, b] = pair.map((n) => String(n).padStart(3, "0"));
  return [`${a}_lessons_spec.sql`, `${b}_lessons.sql`];
};
const pgrolls = [...listed(/_\w*Migration\w*:\s*"(\d+)(_[A-Za-z0-9_]+)"/g), ...listed(/\bmigrations:\s*"(\d+)(_[A-Za-z0-9_]+)"/g)];
const next = (xs: { n: string }[], by: number) => {
  const top = Math.max(...xs.map((x) => Number(x.n)));
  const width = Math.max(...xs.map((x) => x.n.length));
  const out = top + by;
  if (String(out).length > width) fail(`the app's migrations are numbered to ${top} at ${width} digits: ${out} needs more, and would sort before them under LC_ALL=C; name them in lessons_spec.cue by hand`);
  return String(out).padStart(width, "0");
};

// The stamp, once.
const specPath = `${app}/lessons_spec.cue`;
const held = await Deno.readTextFile(specPath).catch(() => null);
let migration = "", rawSpec = "", rawFns = "";
if (held !== null) {
  const m = /^_lessonsMigration:\s*"([^"]+)"/m.exec(held)?.[1];
  const r = /^_lessonsRawNames:\s*\{\s*spec:\s*"([^"]+)",\s*fns:\s*"([^"]+)"\s*\}/m.exec(held);
  if (!m || !r) fail("lessons_spec.cue holds no `_lessonsMigration: \"...\"` or `_lessonsRawNames: {spec: \"...\", fns: \"...\"}`: add them (the names of the migrations) and run again");
  else { migration = m; rawSpec = r[1]; rawFns = r[2]; }
} else {
  if (migrationFlag !== undefined) migration = migrationFlag;
  else if (pgrolls.length) migration = `${next(pgrolls, 1)}_lessons`;
  else fail(`the app names no pgroll migration (_xMigration: "NN_x") to number after: give one with --migration <name>`);
  if (raws.length) {
    [rawSpec, rawFns] = rawNames();
  } else { rawSpec = "100_lessons_spec.sql"; rawFns = "101_lessons.sql"; }
}

// What is written: [path, text, seed]. Nothing is written unless every path may be.
const template = async (name: string) => (await Deno.readTextFile(`${here}app/${name}`))
  .replaceAll("__PACKAGE__", pkg!).replaceAll("__MODULE_DIR__", moduleDir).replaceAll("__RAW_SPEC__", rawSpec).replaceAll("__RAW_FNS__", rawFns);
// The page's engine says which commit of pronto-plugins it was generated from (the last to touch it), twelve characters on
// every machine. Without a git checkout the line says only that it is the host's.
async function stamped(text: string) {
  const out = await new Deno.Command("git", { args: ["-C", here, "log", "-1", "--abbrev=12", "--format=%h", "--", "app/lessons.js"], stdout: "piped", stderr: "null" }).output().catch(() => null);
  const sha = out?.success ? new TextDecoder().decode(out.stdout).trim() : "";
  return `${sha ? `// Written by pronto-lessons, generated from bsoneca/pronto-plugins@${sha} (lessons/app/lessons.js); regenerated, do not edit.` : "// Written by pronto-lessons; regenerated, do not edit."}\n${text}`;
}
const schema = (await Deno.readTextFile(`${here}schema.cue`)).replace(/^package lessons$/m, `package ${pkg}`);
// lessons_plugin.cue lists the raw migrations itself only where the app lists none: two lists of one field cannot be unified.
const appLists = /\brawMigrations:/.test(all);
const plugin = (await template("lessons_plugin.cue")).replace("// __LESSONS_RAW__", appLists
  ? "// The app lists its own rawMigrations: it adds _lessonsRawMigrations to that list (list.Concat)."
  : "code: state: rawMigrations: _lessonsRawMigrations");
const files: [string, string, boolean][] = [
  [at, await stamped(await template("lessons.js")), false],
  ["lessons_plugin.cue", plugin, false],
  ["pronto/lessons.cue", await template("pronto_lessons.cue"), false],
  ["lessons/lessons.nu", await template("lessons.nu"), false],
  ["lessons_schema.cue", `// generated by pronto-lessons from lessons/schema.cue — do not edit\n${schema}`, false],
  ["lessons/lessons.sql", `-- generated by pronto-lessons from lessons/app/lessons.sql — do not edit\n${await Deno.readTextFile(`${here}app/lessons.sql`)}`, false],
  [inModuleDir("lessons_spec.js"), "export const courses = {};\n", true],
  // generate's own output, written here once so a first generate finds the raw migration pronto's step reads before the lessons
  // step has run; generate overwrites it (the same text the emitter makes of no courses).
  ["lessons/lessons_spec.sql", await Deno.readTextFile(`${here}app/lessons_spec_empty.sql`), true],
  ["lessons_spec.cue", (await template("lessons_spec.cue")).replace(/^_lessonsMigration: ".*"$/m, `_lessonsMigration: "${migration}"`), true],
];
const outputs = new Set(files.map((f) => f[0]).concat(["lessons/lessons_spec.sql", "program.cue"]));
if (at === inModuleDir("lessons_spec.js") || [...outputs].filter((p) => p === at).length > 1 || ["lessons_plugin.cue", "lessons_spec.cue", "lessons_schema.cue", "lessons/lessons.sql", "lessons/lessons.nu", "lessons/lessons_spec.sql"].includes(at)) fail(`${at}: that is another of the installer's files`);

// A file of the app's own is never replaced: what is regenerated says so on its first lines.
const header = /pronto-lessons/;
for (const [path, text, seed] of files) {
  if (seed) continue;
  const was = await Deno.readTextFile(`${app}/${path}`).catch(() => null);
  if (was !== null && was !== text && !header.test(was.split("\n").slice(0, 2).join("\n"))) fail(`${path} exists and is not pronto-lessons' (no header): it is not overwritten`);
}
// An earlier version put its files in the migrations folder, which pronto's generate owns: two copies would be replayed. The two
// names held in _lessonsRawNames are generate's own copies of lessons/ (header and all), overwritten by the next generate: skipped.
try {
  for await (const e of Deno.readDir(`${app}/services/database/migrations`)) {
    if (!/_lessons(_spec)?\.sql$/.test(e.name) || e.name === rawSpec || e.name === rawFns) continue;
    const first = (await Deno.readTextFile(`${app}/services/database/migrations/${e.name}`)).split("\n")[0];
    if (header.test(first)) fail(`services/database/migrations/${e.name} is an earlier install's copy: remove it, the raw migrations are listed from lessons/`);
  }
} catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }

for (const [path, text, seed] of files) {
  const to = `${app}/${path}`;
  const was = await Deno.readTextFile(to).catch(() => null);
  if (was !== null && (seed || was === text)) continue;
  await Deno.mkdir(to.replace(/\/[^/]+$/, ""), { recursive: true });
  await Deno.writeTextFile(to, text);
  console.log(`pronto-lessons: wrote ${path}`);
}
if (appLists && !/_lessonsRawMigrations/.test(all)) {
  console.log("pronto-lessons: add _lessonsRawMigrations to the app's `code: state: rawMigrations` list (list.Concat([[...own], _lessonsRawMigrations]))");
}
