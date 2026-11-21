// Four release guards, the same file in every app (copied unchanged from apps/brawl-chess, as
// tests/unit.ts is): `deno run --allow-read --allow-run [--allow-env] tests/lint.ts generated|image|schema|run`, run in
// the app's folder by the checks program.cue declares. They are test checks, not lint ones:
// lint is skipped when the tree is the one it last passed (bayt's fingerprint of the tree's
// files), and generate returns a hand-edited tree to exactly that, while `image` also reads
// infra/gcp beside the tree. `test` always runs, and the gate runs it after lint.
//
// generated: a file `generate` writes must be what the repository holds. The gate runs generate
// before lint, so a hand edit to a generated file (a pin in .mise.toml, a line in .bayt/) is
// already overwritten in the working tree; what is left to see is that the overwrite differs
// from what is staged or committed. So after generate, a generated file that differs from the
// index (or is new and untracked) is a stale or hand-edited one. Fix the source (program.cue,
// cue.mod, ...), run generate, and `git add` the result.
//
// The shared copies, in `generated` too: a file every app copies unchanged from apps/brawl-chess
// (.github/ci-shared: tests/slot.ts, tests/unit.ts, ...) must be byte for byte the same in every
// app. ci checks one app, brawl-chess, when only those change (.github/ci-changed.sh), and this
// is what makes that enough: its check names every app whose copy differs.
//
// schema: the two ways a release breaks the live database that no scenario sees (AGENTS.md; once
// only in brawl-chess, PRONTO-173). The replayed SQL of services/database/migrations: Postgres cannot
// change a function's row type in place, so a function that returns rows is dropped before it is
// created again (#619). And the pgroll migrations of .bayt/Dockerfile.migrate: migrate.sh refuses
// one that sorts (plain byte order) before the last one the live database applied (#624). The live
// one is the release record's (~/.cache/pronto/releases/<release>.jsonl, where this Mac released
// the app); main's last is checked too, which the live one never passes. Lints, not a SQL parser.
//
// image: a file a check driver reads when it runs must be in the image that runs it. The image
// is what .bayt/Dockerfile.<target> copies (its COPY globs, its parent images', less the
// excludes); the driver is the script in the target's compose command, plus, for the cloud
// rehearsal's driver (release.cue `rehearsal`), the scripts of the checks it replaces and the
// job's own. Reads are followed statically: relative imports, and any string literal that names
// a file or folder of the app (resolved from the reading file, or from the app's folder).
//
// run: one argument of a Dockerfile instruction must stay under what Linux passes to a process (one
// argv string is at most 131,071 B, MAX_ARG_STRLEN counting the NUL), and a shell-form RUN is one string: pronto emits a
// served image as one `install -D` per file, all joined into a single RUN, so a page that grows by a
// few dozen files breaks the build of the release only (PRONTO-867). The guard measures the largest
// argument of every RUN, CMD, ENTRYPOINT and HEALTHCHECK in the app's Dockerfiles (continuation lines
// joined; a heredoc's body counts where a RUN hands it to `sh -c`, not where it is a file) and fails over a ceiling: 65,536 B
// (half the limit, room for growth between gates), or the number the app's check passes after `run`.
const app = Deno.cwd();
const decoder = new TextDecoder();

const run = async (cmd: string, args: string[]): Promise<string | null> => {
  try {
    const out = await new Deno.Command(cmd, { args, cwd: app, stdout: "piped", stderr: "null" }).output();
    return out.success ? decoder.decode(out.stdout) : null;
  } catch {
    return null;
  }
};
const text = async (path: string): Promise<string | null> => {
  try {
    return await Deno.readTextFile(`${app}/${path}`);
  } catch {
    return null;
  }
};
const exists = async (path: string): Promise<"file" | "dir" | null> => {
  try {
    const s = await Deno.stat(`${app}/${path}`);
    return s.isDirectory ? "dir" : "file";
  } catch {
    return null;
  }
};
// Scratch state a run makes (tests/scenarios/select.ts's `apart`), never source.
const scratch = new Set([".git", "node_modules", ".task", "dist", ".certs", ".omc", ".claude", ".probe", ".DS_Store"]);
const walk = async(dir: string): Promise<string[]> => {
  const out: string[] = [];
  for await (const e of Deno.readDir(`${app}/${dir}`)) {
    if (scratch.has(e.name)) continue;
    const p = dir ? `${dir}/${e.name}` : e.name;
    if (e.isDirectory) out.push(...await walk(p));
    else out.push(p);
  }
  return out;
};

// ---- generated ----------------------------------------------------------------------------

// A generated file announces itself in its first lines, or is one of the few JSON/TOML files
// generate writes without a header.
const headed = /(generated|written) (by|from)\b|do not edit/i;
const fixed = [".mise.toml", "bayt.json"];

export async function generated(): Promise<string[]> {
  const inRepo = await run("git", ["rev-parse", "--show-prefix"]);
  if (inRepo === null) return []; // an image has no checkout to compare with
  const tracked = (await run("git", ["ls-files", "-z", "--", "."]) ?? "").split("\0").filter(Boolean);
  const manifest = JSON.parse(await text(".pronto/manifest.json") ?? '{"written":[]}').written as string[];
  const set = new Set<string>([...manifest, ...fixed]);
  for (const f of tracked) {
    if (f.startsWith(".bayt/") || f.startsWith(".pronto/")) set.add(f);
    else {
      const head = (await text(f))?.slice(0, 300);
      if (head && headed.test(head)) set.add(f);
    }
  }
  // History pronto keeps under .pronto/ is not generate's output: lint's inputs write
  // proto-baseline.json, with main's commit only where CI is set. bayt.json names it
  // `pronto-history`, which every target already leaves out of its inputs.
  const targets = JSON.parse(await text("bayt.json") ?? "{}").targets ?? {};
  const history = new Set<string>(Object.values(targets).flatMap((t) =>
    (t as { srcs?: { defaultExclude?: Record<string, { glob?: string } | null> } }).srcs?.defaultExclude?.["pronto-history"]?.glob ?? []
  ));
  const prefix = inRepo.trim();
  const status = (await run("git", ["status", "--porcelain=v1", "-z", "--", "."]) ?? "").split("\0").filter(Boolean);
  const bad: string[] = [];
  for (let i = 0; i < status.length; i++) {
    const code = status[i].slice(0, 2);
    let path = status[i].slice(3).slice(prefix.length);
    if (code[0] === "R" || code[0] === "C") i++; // a rename lists its origin next
    const untracked = code === "??";
    const generatedPath = set.has(path) || path.startsWith(".bayt/") || path.startsWith(".pronto/") ||
      (untracked && path.endsWith("/") && [...set].some((s) => s.startsWith(path)));
    if (!generatedPath || history.has(path)) continue;
    if (untracked || code[1] !== " ") bad.push(`${path}  (${untracked ? "new, not added" : "differs from what is staged"})`);
  }
  return bad;
}

// ---- image --------------------------------------------------------------------------------

const globRe = (g: string): RegExp => {
  let re = "";
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === "*" && g[i + 1] === "*") {
      if (g[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } else { re += ".*"; i += 1; }
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else if (c === "[") {
      const j = g.indexOf("]", i);
      if (j < 0) re += "\\[";
      else { re += g.slice(i, j + 1); i = j; }
    } else re += c.replace(/[.+^${}()|\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
};
const covers = (globs: string[], path: string): boolean => {
  const parts = path.split("/");
  const prefixes = parts.map((_, i) => parts.slice(0, i + 1).join("/"));
  return globs.some((g) => {
    const re = globRe(g.replace(/^\.\//, "").replace(/\/+$/, ""));
    return prefixes.some((p) => re.test(p));
  });
};

// One entry per COPY: its sources less its own excludes. An image is their union.
type Image = { globs: string[]; excludes: string[] }[];

// What the image of target `name` holds: its own COPYs, and its parents' (FROM and COPY --from).
async function image(project: string, name: string, seen = new Set<string>()): Promise<Image> {
  const out: Image = [];
  if (seen.has(name)) return out;
  seen.add(name);
  const df = await text(`.bayt/Dockerfile.${name}`);
  if (df === null) return out;
  const lines = df.replace(/\\\n/g, " ").split("\n");
  let stage = false;
  const parent = (ref: string) => ref.startsWith(`${project}-`) ? ref.slice(project.length + 1).replace(/_srcs$/, "") : null;
  const into = async (ref: string) => {
    const p = parent(ref);
    if (!p) return;
    const sub = await image(project, p, seen);
    out.push(...sub);
  };
  for (const line of lines) {
    const from = line.match(/^FROM\s+(\S+)\s+AS\s+(\S+)/i);
    if (from) {
      stage = from[2] === name;
      if (stage) await into(from[1]);
      continue;
    }
    if (!stage || !/^COPY\s/.test(line)) continue;
    const words = line.split(/\s+/).slice(1);
    const flags = words.filter((w) => w.startsWith("--"));
    const rest = words.filter((w) => !w.startsWith("--"));
    const src = flags.find((f) => f.startsWith("--from="));
    if (src) { await into(src.slice(7)); continue; }
    out.push({
      globs: rest.slice(0, -1).filter((s) => !s.startsWith("/") && !s.includes("${")),
      excludes: flags.filter((f) => f.startsWith("--exclude=")).map((f) => f.slice(10)),
    });
  }
  return out;
}

// Strings of a source file outside its comments, and whether each is an import specifier.
function literals(src: string): [string, boolean][] {
  const out: [string, boolean][] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { const j = src.indexOf("*/", i + 2); i = j < 0 ? src.length : j + 2; continue; }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1, s = "";
      while (j < src.length && src[j] !== c) {
        if (src[j] === "\\") { s += src[j + 1] ?? ""; j += 2; continue; }
        if (c !== "`" && src[j] === "\n") break;
        s += src[j++];
      }
      if (!(c === "`" && s.includes("${"))) out.push([s, /\b(from|import)\s*\(?\s*$/.test(src.slice(Math.max(0, i - 20), i))]);
      i = j + 1;
      continue;
    }
    i++;
  }
  return out;
}

const norm = (p: string): string | null => {
  const out: string[] = [];
  for (const part of p.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") { if (!out.length) return null; out.pop(); } else out.push(part);
  }
  return out.join("/");
};
const dirOf = (p: string) => p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "";
const code = /\.(ts|js|mjs|mts|tsx|jsx)$/;
const fileLike = /^[\w@./-]+$/;
// tests/slot.ts is the host tier's (a stack of host processes on a slot): the files it names (".bayt", "cue.mod",
// .bayt/process-compose.yaml) are read there, never in an image. A driver that imports it (load.ts, for `processes`
// and `treeOf`) needs slot.ts itself in the image, not what slot.ts opens.
const hostTier = (f: string) => f === "tests/slot.ts" || f.endsWith("/tests/slot.ts");

// Every file the script reaches, each with the file that read it.
async function reads(entry: string): Promise<Map<string, string>> {
  const found = new Map<string, string>();
  const queue = [entry];
  const visited = new Set<string>();
  while (queue.length) {
    const file = queue.pop()!;
    if (visited.has(file)) continue;
    visited.add(file);
    if (!code.test(file)) continue;
    const src = await text(file);
    if (src === null) continue;
    for (const [lit, imported] of literals(src)) {
      // A "/path" is a URL the running app serves, not a file the driver opens.
      if (!lit || lit.length > 200 || lit.startsWith("/") || lit.includes("://") || scratch.has(lit.replace(/^(\.\/)?/, "").split("/")[0]) ||!fileLike.test(lit) || !(lit.includes("/") || /\.\w{1,6}$/.test(lit))) continue;
      const relative = lit.startsWith("./") || lit.startsWith("../");
      const tries = relative ? [norm(`${dirOf(file)}/${lit}`)] : [norm(lit), norm(`${dirOf(file)}/${lit}`)];
      for (const t of tries) {
        if (!t) continue;
        const kind = await exists(t);
        if (!kind) continue;
        const files = kind === "dir" ? (await walk(t)).map((f) => f) : [t];
        for (const f of files) {
          if (f === entry) continue;
          if (!found.has(f)) found.set(f, file);
          // What the driver imports it runs, so what that reads counts; a path in a string is
          // only read (a page's flags.js, the scripts a child spawns are named by release.cue,
          // below). A file first seen as a string and imported later is still followed.
          if (imported && !hostTier(f)) queue.push(f);
        }
        break;
      }
    }
  }
  return found;
}

// The shared files (.github/ci-shared) every app holds the same as apps/brawl-chess's: the apps whose
// copy differs, or lacks it where brawl-chess has it. Nothing where this checkout has no brawl-chess
// beside the app or no list.
export async function sharedDiffers(): Promise<string[]> {
  const apps = `${app}/..`;
  const list = await Deno.readTextFile(`${apps}/../.github/ci-shared`).catch(() => "");
  const files = list.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const bad: string[] = [];
  for (const f of files) {
    const canon = await Deno.readFile(`${apps}/brawl-chess/${f}`).catch(() => null);
    if (!canon) continue;
    for await (const e of Deno.readDir(apps)) {
      if (!e.isDirectory) continue;
      const mine = await Deno.readFile(`${apps}/${e.name}/${f}`).catch(() => null);
      if (mine && (mine.length !== canon.length || mine.some((b, i) => b !== canon[i]))) {
        bad.push(`apps/${e.name}/${f} differs from apps/brawl-chess/${f}  (a shared copy: change it in every app at once)`);
      }
    }
  }
  return bad;
}

const scriptsIn = async (command: string): Promise<string[]> => {
  const out: string[] = [];
  for (const w of command.split(/[\s"'`;&|]+/)) {
    if (/\.(ts|js|mjs|nu|sh)$/.test(w) && fileLike.test(w) && await exists(w) === "file") out.push(w);
  }
  return out;
};

export async function missingFromImages(): Promise<string[]> {
  const bayt = JSON.parse(await text("bayt.json") ?? "{}");
  const project: string = bayt.name ?? "";
  const targets = new Map<string, string>(); // name -> compose command
  if (await exists(".bayt") === "dir") {
    for (const e of Deno.readDirSync(`${app}/.bayt`)) {
      const m = e.name.match(/^bayt\.(.+)\.json$/);
      if (!m) continue;
      const d = JSON.parse(await text(`.bayt/${e.name}`) ?? "{}");
      const cmd = d.compose?.command;
      if (Array.isArray(cmd)) targets.set(d.name ?? m[1], cmd.join(" "));
    }
  }
  // The cloud rehearsal runs its driver's image with another command: the replaced checks'
  // scripts, run by the job's own script (named in infra/gcp/*.cue beside the job).
  const release = await text("release.cue") ?? "";
  const rehearsal = release.match(/rehearsal:\s*\{([^}]*)\}/)?.[1] ?? "";
  const driver = rehearsal.match(/driver:\s*"([^"]+)"/)?.[1];
  const replaces = [...(rehearsal.match(/replaces:\s*\[([^\]]*)\]/)?.[1] ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  const job = rehearsal.match(/job:\s*"([^"]+)"/)?.[1];
  const extra: string[] = [];
  if (driver && targets.has(driver)) {
    for (const r of replaces) if (targets.has(r)) extra.push(...await scriptsIn(targets.get(r)!));
    if (job) {
      try {
        for await (const e of Deno.readDir(`${app}/../../infra/gcp`)) {
          if (!e.name.endsWith(".cue")) continue;
          const infra = await Deno.readTextFile(`${app}/../../infra/gcp/${e.name}`);
          if (!infra.includes(`"${job}"`)) continue;
          for (const l of infra.split("\n")) if (/^\s*args:/.test(l)) extra.push(...await scriptsIn(l));
        }
      } catch { /* no infra beside the app */ }
    }
  }

  const bad: string[] = [];
  for (const [name, command] of targets) {
    const entries = [...await scriptsIn(command), ...(name === driver ? extra : [])];
    if (!entries.length) continue;
    const img = await image(project, name);
    const ignored = (await text(".dockerignore") ?? "").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#") && !l.startsWith("!"));
    const inImage = (f: string) => !covers(ignored, f) && img.some((c) => covers(c.globs, f) && !covers(c.excludes, f));
    for (const entry of [...new Set(entries)]) {
      if (!inImage(entry)) bad.push(`${name}: ${entry} (its driver script) is not in the image`);
      for (const [f, by] of await reads(entry)) {
        if (!inImage(f)) bad.push(`${name}: ${f} is read by ${by}${by === entry ? "" : ` (run from ${entry})`} but is not in the image`);
      }
    }
  }
  return [...new Set(bad)];
}

// ---- schema --------------------------------------------------------------------------------

const byteOrder = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

// The sorted migration names of a generated .bayt/Dockerfile.migrate.
export function names(dockerfile: string): string[] {
  return [...new Set([...dockerfile.matchAll(/\/pgroll\/([^\s/]+)\.json/g)].map((m) => m[1]))].sort(byteOrder);
}

// The names in `current`, new since `released`, that do not sort after the last of `released`.
export function outOfOrder(released: string[], current: string[]): string[] {
  if (!released.length) return [];
  const last = released.reduce((a, b) => (a > b ? a : b));
  return current.filter((n) => !released.includes(n) && !(n > last)).sort(byteOrder);
}

// The row-returning functions a SQL text creates without an earlier DROP FUNCTION IF EXISTS.
export function undropped(sql: string): string[] {
  const body = sql.replace(/--[^\n]*/g, "");
  const id = '(?:"[^"]+"|[A-Za-z_][\\w$]*)';
  const name = `(${id}(?:\\s*\\.\\s*${id})?)`;
  const norm = (x: string) => x.replace(/"/g, "").replace(/\s+/g, "").toLowerCase();
  const drops = [...body.matchAll(new RegExp(`\\bDROP\\s+FUNCTION\\s+IF\\s+EXISTS\\s+${name}`, "gi"))].map((m) => ({ at: m.index!, name: norm(m[1]) }));
  const out: string[] = [];
  for (const m of body.matchAll(new RegExp(`\\bCREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+${name}\\s*\\(`, "gi"))) {
    const start = m.index! + m[0].length;
    let depth = 1, i = start;
    while (i < body.length && depth) { depth += body[i] === "(" ? 1 : body[i] === ")" ? -1 : 0; i++; }
    const params = body.slice(start, i - 1);
    const rest = body.slice(i, i + 200);
    const rows = /^\s*RETURNS\s+(?:TABLE\b|SETOF\s+record\b)/i.test(rest) || /(?:^|,)\s*(?:OUT|INOUT)\s/i.test(params);
    const n = norm(m[1]);
    if (rows && !drops.some((d) => d.name === n && d.at < m.index!) && !out.includes(n)) out.push(n);
  }
  return out;
}

// The pgroll names a commit held, or null when git cannot show it.
const namesAt = async (commit: string): Promise<string[] | null> => {
  const prefix = (await run("git", ["rev-parse", "--show-prefix"]))?.trim() ?? "";
  const old = await run("git", ["show", `${commit}:${prefix}.bayt/Dockerfile.migrate`]);
  return old === null ? null : names(old);
};

// The commit the release record says last went live, or null where this Mac never released the app.
const liveCommit = async (): Promise<string | null> => {
  const release = (await run(Deno.env.get("CUE") ?? "cue", ["export", "--expression", "GCP.name", "--out", "text", "./release.cue"]))?.trim();
  if (!release) return null;
  let record: string;
  try {
    record = await Deno.readTextFile(`${Deno.env.get("HOME")}/.cache/pronto/releases/${release}.jsonl`);
  } catch {
    return null;
  }
  const lives = record.split("\n").filter((l) => l.trim()).flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } })
    .filter((r) => r.outcome === "live" && !r.preview && !r.dirty && /^[0-9a-f]{40}$/.test(r.commit ?? ""));
  return lives.length ? lives[lives.length - 1].commit : null;
};

export async function schemaProblems(): Promise<string[]> {
  const bad: string[] = [];
  const dir = "services/database/migrations";
  if (await exists(dir) === "dir") {
    for (const f of (await walk(dir)).filter((f) => f.endsWith(".sql")).sort()) {
      const u = undropped(await text(f) ?? "");
      if (u.length) bad.push(`${f}: ${u.join(", ")} returns rows and is created without a DROP FUNCTION IF EXISTS before it`);
    }
  }
  const migrate = await text(".bayt/Dockerfile.migrate");
  const current = migrate === null ? [] : names(migrate);
  if (current.length) {
    const live = await liveCommit();
    const against: [string, string][] = [];
    if (live) against.push([live, `the live release (${live.slice(0, 12)})`]);
    if (await run("git", ["rev-parse", "--verify", "--quiet", "origin/main"]) !== null) against.push(["origin/main", "origin/main"]);
    for (const [commit, what] of against) {
      const released = await namesAt(commit);
      if (released === null) continue;
      for (const n of outOfOrder(released, current)) bad.push(`.bayt/Dockerfile.migrate: ${n} sorts before ${released[released.length - 1]}, the last of ${what} (LC_ALL=C): migrate.sh refuses it`);
    }
  }
  return bad;
}

// ---- run -----------------------------------------------------------------------------------

export const ARG_CEILING = 65536;

export type ArgSize = { file: string; line: number; instruction: string; bytes: number; command: string };

const utf8 = new TextEncoder();
const byteLength = (s: string) => utf8.encode(s).length;
const skippable = (l: string) => /^\s*(#.*)?$/.test(l);

// The largest argument of every RUN, CMD, ENTRYPOINT and HEALTHCHECK CMD of a Dockerfile's text, as
// BuildKit reads it: the `# escape=` directive (default `\`) joins a line to the next, comment lines
// inside a joined instruction are dropped, a shell form is one string, an exec form (a JSON array) is
// as large as its largest element, a heredoc (`<<EOF`) of COPY or ADD is a file, not an argument, and so is a standalone `RUN <<WORD` whose body starts with `#!`
// (BuildKit runs it as a script); any other RUN heredoc goes to `sh -c`, so its command and body count.
// A heredoc's delimiter as BuildKit reads it: any word without whitespace or shell operators, optionally quoted, after `<<` or `<<-`.
const HEREDOC = String.raw`<<(-?)\s*(?:"([^"]+)"|'([^']+)'|([^\s"'<>|&;()]+))`;
export function argSizes(dockerfile: string, file = "Dockerfile"): ArgSize[] {
  const lines = dockerfile.split(/\r?\n/);
  let esc = "\\";
  for (const l of lines) {
    const d = l.match(/^\s*#\s*([A-Za-z]+)\s*=\s*(\S+)\s*$/);
    if (!d) break; // parser directives are only the comments before the first instruction
    if (d[1].toLowerCase() === "escape") esc = d[2];
  }
  const out: ArgSize[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (skippable(lines[i])) continue;
    const start = i + 1;
    let text = lines[i];
    while (text.trimEnd().endsWith(esc) && i + 1 < lines.length) {
      text = text.trimEnd().slice(0, -esc.length);
      i++;
      while (i + 1 < lines.length && skippable(lines[i])) i++;
      if (!skippable(lines[i])) text += lines[i];
    }
    // Heredocs: each `<<WORD` (a word of its own, not `<<<` or a shift) reads its body up to a line that
    // is WORD; with no such line the instruction ends where it did.
    const end = i;
    const heredocs: { word: string; body: string }[] = [];
    for (const h of text.matchAll(new RegExp(String.raw`(?:^|\s)` + HEREDOC, "g"))) {
      const word = h[2] ?? h[3] ?? h[4];
      const body: string[] = [];
      let found = false;
      while (i + 1 < lines.length && !found) {
        i++;
        if ((h[1] ? lines[i].replace(/^\t+/, "") : lines[i]) === word) found = true;
        else body.push(h[1] ? lines[i].replace(/^\t+/, "") : lines[i]);
      }
      if (!found) { i = end; break; }
      heredocs.push({ word, body: body.map((l) => l + "\n").join("") });
    }
    const m = text.match(/^\s*(RUN|CMD|ENTRYPOINT|HEALTHCHECK)\b\s*([\s\S]*)$/i);
    if (!m) continue;
    const instruction = m[1].toUpperCase();
    let rest = m[2].trim();
    if (instruction === "HEALTHCHECK") {
      rest = rest.replace(/^(?:--\S+\s+)*/, "");
      if (!/^CMD\b/i.test(rest)) continue; // NONE has no command
      rest = rest.slice(3).trim();
    } else if (instruction === "RUN") {
      rest = rest.replace(/^(?:--[a-z-]+(?:=\S+)?\s+)*/, "");
    }
    let bytes = byteLength(rest);
    if (instruction === "RUN") {
      const alone = new RegExp(`^${HEREDOC}$`).test(rest);
      if (heredocs.length) {
        // A standalone `RUN <<EOF` is a script file when its body starts with `#!`, else the body is the command; an inline
        // shell command (`RUN cat <<EOF > /f`) is one argument: the command with every body and word, whatever a body starts with.
        if (alone) { if (!heredocs[0].body.startsWith("#!")) bytes = Math.max(bytes, byteLength(heredocs[0].body)); }
        else bytes = Math.max(bytes, byteLength(rest + "\n" + heredocs.map((h) => h.body + h.word).join("\n")));
      }
    }
    if (rest.startsWith("[")) {
      try {
        const arr = JSON.parse(rest);
        if (Array.isArray(arr) && arr.every((x) => typeof x === "string")) bytes = Math.max(0, ...arr.map(byteLength));
      } catch { /* not JSON: a shell form that starts with [ */ }
    }
    out.push({ file, line: start, instruction, bytes, command: rest });
  }
  return out;
}

// The folders (four levels at most) a long instruction's `install -D` destinations sit in, with the bytes
// of the statements installing into each, largest first: where a served image's weight is.
export function heaviest(command: string, top = 3): [string, number][] {
  const by = new Map<string, number>();
  for (const stmt of command.split(/;\s*/)) {
    const d = stmt.match(/install\s+-D\b.*'([^']+)'\s*$/);
    if (!d) continue;
    const dirs = d[1].replace(/^\/served\//, "").split("/").slice(0, -1).slice(0, 4);
    const dir = dirs.length ? dirs.join("/") + "/" : "(root)";
    by.set(dir, (by.get(dir) ?? 0) + byteLength(stmt) + 2);
  }
  return [...by].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, top);
}

// The ceiling a check passes (`run [bytes]`): digits only, above 0 and under what Linux passes in one string
// (131,072 B, MAX_ARG_STRLEN, which counts the NUL, so at most 131,071 B of command); null for anything else.
export function parseCeiling(arg: string | undefined): number | null {
  if (arg === undefined) return ARG_CEILING;
  if (!/^\d+$/.test(arg)) return null;
  const n = Number(arg);
  return n > 0 && n < 131072 ? n : null;
}

// The app's Dockerfiles: .bayt/Dockerfile.* and any Dockerfile* beside program.cue (a symlink counts).
const dockerfiles = async (root: string): Promise<string[]> => {
  const files: string[] = [];
  for (const dir of ["", ".bayt"]) {
    try {
      for await (const e of Deno.readDir(dir ? `${root}/${dir}` : root)) {
        if ((e.isFile || e.isSymlink) && /^Dockerfile/.test(e.name)) files.push(dir ? `${dir}/${e.name}` : e.name);
      }
    } catch (err) {
      if (!(err instanceof Deno.errors.NotFound)) throw err;
    }
  }
  return files.sort();
};

// Every instruction of the app's Dockerfiles whose largest argument is over `ceiling` bytes, worded for the
// gate (file, line, size, and the folders that weigh most); a Dockerfile that cannot be read is a problem too.
export async function runArgProblems(ceiling = ARG_CEILING, root = app): Promise<string[]> {
  const bad: string[] = [];
  for (const f of await dockerfiles(root)) {
    let df: string;
    try {
      df = await Deno.readTextFile(`${root}/${f}`);
    } catch (err) {
      bad.push(`${f}: cannot be read (${(err as Error).message})`);
      continue;
    }
    for (const a of argSizes(df, f)) {
      if (a.bytes <= ceiling) continue;
      const heavy = heaviest(a.command).map(([d, n]) => `${d} ${n}`);
      bad.push(`${a.file}:${a.line} ${a.instruction} ${a.bytes} B > ceiling ${ceiling} B${heavy.length ? `  (heaviest: ${heavy.join(", ")})` : ""}`);
    }
  }
  return bad;
}

if (import.meta.main) {
  const which = Deno.args[0];
  const fix: Record<string, string> = {
    generated: "A generated file differs from what is staged: change its source (program.cue, cue.mod, ...), run ./saytw generate, and `git add` the result. A hand edit to a generated file is overwritten by generate. A shared copy (tests/slot.ts, ...) that differs: copy apps/brawl-chess's over it, in every app.",
    schema: "Put DROP FUNCTION IF EXISTS <name>(<argument types>) before the CREATE of a function that returns rows (its GRANTs after the CREATE stand), and name a new pgroll migration to sort after the last one released (AGENTS.md, #619, #624).",
    run: "One argument of a Dockerfile instruction is over the app's ceiling (Linux takes at most 131,071 B in one argv string, MAX_ARG_STRLEN counting the NUL, and a shell-form RUN is one): split the instruction (for a served image: fewer served files, or pack them), or, with the reason in a comment beside it, raise the number its guard-run check passes (`tests/lint.ts run <bytes>`, default 65536, under 131072).",
    image: "Add the file to the check's srcs in program.cue (build: checks: \"<name>\": srcs: [...]), then run ./saytw generate: the image the rc runs holds only what its Dockerfile copies.",
  };
  const ceiling = which === "run" ? parseCeiling(Deno.args[1]) : 0;
  const bad = ceiling === null ? null : which === "generated" ? [...await generated(), ...await sharedDiffers()] : which === "image" ? await missingFromImages() : which === "schema" ? await schemaProblems() : which === "run" ? await runArgProblems(ceiling) : null;
  if (bad === null) { console.error("usage: tests/lint.ts generated|image|schema|run [ceiling: whole bytes, 1 to 131071, default 65536]"); Deno.exit(2); }
  if (bad.length) {
    console.error(`lint ${which}: ${bad.length} problem(s)`);
    for (const b of bad) console.error(`  ${b}`);
    if (which === "generated") {
      // Show what differs, so a round names its cause (mise.lock: setup's `mise install` rewrites the
      // lock in the form mise writes, so a pasted or hand-made entry differs from it).
      for (const b of bad) {
        const path = b.split("  (")[0];
        const stat = await run("git", ["diff", "--stat", "--", path]);
        const diff = await run("git", ["diff", "--unified=1", "--", path]);
        if (stat) console.error(stat.trimEnd());
        if (diff) console.error(diff.split("\n").slice(0, 40).join("\n"));
      }
    }
    console.error(fix[which]);
    Deno.exit(1);
  }
  console.log(`lint ${which}: ok`);
}
