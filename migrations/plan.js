// pronto-migrations' rules, apart from what they act on (migrate.ts reads the files, runs git and
// cue, and writes): the model an app's emitted proto and pronto's column facts describe, the changes
// between two models, the SQL each change needs on a database that already holds rows, and the files
// that record them (a pgroll migration, the snapshot, the sum, the ledger). Pure, so the cases
// (tests/unit/migrations.cue) hold them.

// The snapshot's format, and the version of pronto's .pronto/check-inputs.json this reads. A
// snapshot of another format, or facts of another version, is refused rather than misread: a fact
// read wrong would be a change, and a change is SQL on a live database.
export const FORMAT = 1;
export const FACTS_VERSION = 1;

// --- The model ---

// The messages of an emitted entities.proto: each field's number, name and type, and the numbers
// and names each message reserves. pronto's emitter writes one flat message per entity (no nesting,
// enums, oneofs or maps), and anything else is refused rather than misread.
export function parseProto(text) {
  const messages = {};
  let cur = null;
  const lines = text.split("\n");
  for (const [i, raw] of lines.entries()) {
    const line = raw.replace(/\/\/.*$/, "").trim();
    if (!line) continue;
    const at = `entities.proto:${i + 1}`;
    let m;
    if (!cur) {
      if ((m = line.match(/^message\s+(\w+)\s*\{$/))) {
        if (messages[m[1]]) throw new Error(`${at}: message ${m[1]} twice`);
        cur = messages[m[1]] = { fields: {}, reserved: { numbers: [], names: [] } };
      } else if (!/^(syntax|package|import|option)\b.*;$/.test(line)) {
        throw new Error(`${at}: not what pronto emits: ${line}`);
      }
      continue;
    }
    if (line === "}") {
      cur = null;
    } else if ((m = line.match(/^reserved\s+(.+);$/))) {
      for (const part of m[1].split(",").map((s) => s.trim())) {
        let r;
        if ((r = part.match(/^"(\w+)"$/))) cur.reserved.names.push(r[1]);
        else if ((r = part.match(/^(\d+)$/))) cur.reserved.numbers.push(Number(r[1]));
        else if ((r = part.match(/^(\d+)\s+to\s+(\d+)$/))) for (let n = Number(r[1]); n <= Number(r[2]); n++) cur.reserved.numbers.push(n);
        else throw new Error(`${at}: a reservation pronto does not emit: ${part}`);
      }
    } else if ((m = line.match(/^(?:(optional|repeated)\s+)?([\w.]+)\s+(\w+)\s*=\s*(\d+)\s*(?:\[[^\]]*\])?\s*;$/))) {
      if (cur.fields[m[4]]) throw new Error(`${at}: field number ${m[4]} twice`);
      cur.fields[m[4]] = { name: m[3], type: m[1] === "repeated" ? `repeated ${m[2]}` : m[2] };
    } else {
      throw new Error(`${at}: not what pronto emits: ${line}`);
    }
  }
  if (cur) throw new Error("entities.proto: a message is not closed");
  return messages;
}

// The states of each machine's column, from the emitted 010_machines.sql: pronto writes a machine's
// states as the column's check, `"<table>_<column>_check" CHECK ("<column>" IN (...)) NOT VALID`,
// and guards its transitions with the trigger trg_<table>_<column>_machine. By table, then column.
// A machine's trigger with no check read is a 010 this reader does not know, and is refused.
export function parseMachines(sql) {
  const out = {};
  const read = new Set();
  for (const [, name, col, list] of sql.matchAll(/ADD CONSTRAINT "(\w+)_check" CHECK \("(\w+)" IN \(([^)]*)\)\)/g)) {
    if (!name.endsWith(`_${col}`)) continue;
    const table = name.slice(0, -col.length - 1);
    (out[table] ??= {})[col] = [...list.matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1].replaceAll("''", "'"));
    read.add(name);
  }
  for (const [, middle] of sql.matchAll(/CREATE TRIGGER "trg_(\w+)_machine"/g)) {
    if (!read.has(middle)) throw new Error(`010_machines.sql: the trigger trg_${middle}_machine has no check this reader knows: a pronto this plugin does not read`);
  }
  return out;
}

// A column's type as pronto's identity compares it: an alias named by its type (text is string),
// and a decimal with its precision and scale, which are its column's type too.
const canonical = (f, types) => {
  const t = types?.aliases?.[f.type] ?? f.type;
  return t === "decimal" ? `decimal(${f.precision ?? ""},${f.scale ?? ""})` : t;
};

// The column's type as Postgres holds it, which an alias does not always share with its type
// (pronto's emit.cue, _sqlType): text and int are string's and int32's, but bigint, timestamptz and
// tsvector are base types where int64 and timestamp are domains and string is text. Spelling a
// field another way with another column type is a retype the replay never applies.
const LEGACY = { text: "text", int: "integer", bigint: "bigint", timestamptz: "timestamptz", tsvector: "tsvector" };
const physical = (f, types) => {
  if (LEGACY[f.type]) return LEGACY[f.type];
  if (f.type === "decimal") return `portable_decimal_${f.precision ?? ""}_${f.scale ?? ""}`;
  const c = types?.types?.[f.type];
  return String(c ? (c.column === "domain" ? c.sql : c.pg) : f.type).toLowerCase();
};

// The model of an app's database: each entity with a table (pronto's `server`), keyed by its
// message, with its live fields and its retired ones by number. The proto says what a column is (its
// number, its name, its wire type, a retirement); .pronto/check-inputs.json (`inputs`, pronto's facts
// for its own checks, from the same CUE) says what it holds (required, default, enum, check, unique,
// reference, generated, also for a retired field, which keeps what pronto still emits for it) and the
// entity's table and indexes; 010_machines.sql (`machinesSql`) the states of a machine's column.
// Where the proto and the facts disagree the app was not generated: an error, not a guess.
export function model(protoText, inputs, machinesSql = "") {
  if (inputs.version !== FACTS_VERSION) throw new Error(`.pronto/check-inputs.json is version ${inputs.version}; this plugin reads version ${FACTS_VERSION}`);
  const proto = parseProto(protoText);
  const machines = parseMachines(machinesSql);
  const out = {};
  for (const [name, e] of Object.entries(inputs.entities ?? {})) {
    if (!e.server) continue;
    const msg = proto[name];
    if (!msg) throw new Error(`${name}: a table with no message in entities.proto: run generate`);
    if (!e.cel?.enums || !e.cel?.checks || !Array.isArray(e.uniques)) throw new Error(`${name}: .pronto/check-inputs.json has no cel.enums, cel.checks or uniques: a pronto this plugin does not read`);
    const machined = machines[e.table] ?? {};
    const enums = { ...e.cel.enums, ...machined };
    const facts = (f) => clean({
      name: f.name,
      type: canonical(f, inputs.types),
      sql: physical(f, inputs.types),
      required: !!f.required,
      default: f.default,
      enum: enums[f.name],
      machine: machined[f.name] ? true : undefined,
      check: enums[f.name] ? undefined : e.cel.checks[f.name],
      unique: f.unique || undefined,
      ref: f.ref,
      generated: f.generated,
      pk: f.pk || undefined,
    });
    const fields = {}, retired = {};
    for (const f of e.fields) {
      const n = String(f.ordinal);
      if (f.retired) {
        if (!msg.reserved.numbers.includes(f.ordinal) || !msg.reserved.names.includes(f.name)) throw new Error(`${name}.${f.name}: retired, and entities.proto does not reserve ${n} and "${f.name}": run generate`);
        retired[n] = facts(f);
        continue;
      }
      const p = msg.fields[n];
      if (!p || p.name !== f.name) throw new Error(`${name}.${f.name}: entities.proto has ${p ? p.name : "nothing"} at ${n}: run generate`);
      fields[n] = { ...facts(f), proto: p.type };
    }
    for (const [n, p] of Object.entries(msg.fields)) {
      if (!fields[n]) throw new Error(`${name}: entities.proto has ${p.name} at ${n}, which .pronto/check-inputs.json does not: run generate`);
    }
    // pronto writes an index's name unquoted, so Postgres keeps it in lower case: an entity's
    // `uniques` entry by its name, a plain index as idx_<table>_<column>.
    const indexes = {};
    for (const u of e.uniques) indexes[u.name.toLowerCase()] = { cols: u.cols, unique: true };
    for (const x of e.indexes ?? []) indexes[`idx_${e.table}_${x.on}`.toLowerCase()] = clean({ cols: [x.on], using: x.using });
    out[name] = clean({ table: e.table, id: e.id, fields, retired, indexes });
  }
  return sorted(out);
}

// --- The changes ---

// What each kind of change is: refused (no migration can make it safe for every holder of the data),
// the ledger's (an existing column, constraint or index the replay of the emitted schema never
// alters), the replay's (what pronto's emitted CREATE ... IF NOT EXISTS makes by itself), or advisory.
export const verdicts = {
  "entity-dropped": "refused",
  "entity-renamed": "refused",
  "table-renamed": "refused",
  "field-dropped": "refused",
  "field-renamed": "refused",
  "field-retyped": "refused",
  "field-revived": "refused",
  "retirement-dropped": "refused",
  "generated-changed": "refused",
  "pk-retired": "refused",
  "required-added": "refused",
  required: "ledger",
  optional: "ledger",
  default: "ledger",
  "enum-narrowed": "ledger",
  "check-dropped": "ledger",
  "machine-dropped": "ledger",
  "unique-dropped": "ledger",
  "unique-added": "ledger",
  "ref-dropped": "ledger",
  "ref-added": "ledger",
  "index-dropped": "ledger",
  "index-changed": "ledger",
  retired: "replay",
  "entity-added": "replay",
  "field-added": "replay",
  "enum-widened": "replay",
  "index-added": "replay",
  "machine-added": "replay",
  "check-changed": "advisory",
  "check-added": "advisory",
};

// Why a refused change is refused, and what is admitted instead (pronto's
// docs/schema-change-admission.md: an addition or a retirement, never a rename, drop or retype).
export const reasons = {
  "entity-dropped": () => "an entity is never removed: its rows and every reader of them stay",
  "entity-renamed": (c) => `renamed to ${c.to}: a new entity beside this one, never a rename`,
  "table-renamed": (c) => `its table renamed to ${c.to}: every reader of the table breaks`,
  "field-dropped": () => "a field is retired (retired: true), never removed: its number stays reserved",
  "field-renamed": (c) => `renamed to ${c.to}: a reader of the JSON reads it by name, so a rename is a new field beside the retired one`,
  "field-retyped": (c) => `retyped from ${c.from} to ${c.to}: a retype is a new field beside the retired one`,
  "field-revived": () => "its number was retired: a retired number is never used again",
  "retirement-dropped": () => "a retired number stays reserved",
  "generated-changed": () => "a generated column is not altered in place: re-creating it gives it a new attnum, which every replay reports as a column gone",
  "pk-retired": () => "a primary key is never retired",
  "required-added": () => "the replay adds a required column to every row the table already holds, so it needs a default that a migration's session can compute (not auth_uid()); or add it optional, then make it required in a later migration, which fills the NULLs (backfill)",
};

// Where a change is: the entity's column, its index, or the entity.
export const where = (c) => c.field ? `${c.entity}.${c.field}` : c.index ? `${c.entity} index ${c.index}` : c.entity;

// A default read from the session (the caller's claims, a setting): NULL in a migration, so it fills
// nothing.
export const sessionDefault = (d) => d !== undefined && /\b(auth_\w*|current_setting|current_user|session_user|current_role)\b/.test(d);

// The changes from one model to the next, in a stable order: entities by name, columns by number.
// A column is paired by its number, never by its name, so a rename is seen as one; a live field and
// a retired one are compared alike, so a retirement alters the column toward what pronto still
// emits for it.
export function diff(before, after) {
  const out = [];
  const ids = (m) => Object.fromEntries(Object.entries(m).filter(([, e]) => e.id).map(([n, e]) => [e.id, n]));
  const afterIds = ids(after), beforeIds = ids(before);
  for (const [name, b] of Object.entries(before)) {
    const a = after[name];
    const on = { entity: name, table: b.table };
    if (!a) {
      out.push(b.id && afterIds[b.id] ? { ...on, kind: "entity-renamed", to: afterIds[b.id] } : { ...on, kind: "entity-dropped" });
      continue;
    }
    if (a.table !== b.table) {
      out.push({ ...on, kind: "table-renamed", to: a.table });
      continue;
    }
    const machined = Object.values(a.fields).filter((f) => f.machine).map((f) => f.name);
    const numbers = [...new Set([b.fields, b.retired ?? {}, a.fields, a.retired ?? {}].flatMap(Object.keys))].sort((x, y) => Number(x) - Number(y));
    for (const n of numbers) {
      const bf = b.fields[n], br = b.retired?.[n], af = a.fields[n], ar = a.retired?.[n];
      const was = bf ?? br, now = af ?? ar;
      const at = { ...on, field: (was ?? now).name, number: Number(n) };
      if (!was) {
        if (af) out.push(af.required && (af.default === undefined || sessionDefault(af.default)) && !af.generated ? { ...at, kind: "required-added" } : { ...at, kind: "field-added" });
        continue;
      }
      if (!now) {
        out.push({ ...at, kind: bf ? "field-dropped" : "retirement-dropped" });
        continue;
      }
      if (br && af) {
        out.push({ ...at, kind: "field-revived" });
        continue;
      }
      if (now.name !== was.name) {
        out.push({ ...at, kind: "field-renamed", to: now.name });
        continue;
      }
      if (now.type !== was.type || (now.sql ?? null) !== (was.sql ?? null) || (bf && af && af.proto !== bf.proto)) {
        const same = now.type === was.type && (now.sql ?? null) !== (was.sql ?? null);
        out.push({ ...at, kind: "field-retyped", from: same ? was.sql : was.type, to: same ? now.sql : now.type });
        continue;
      }
      if (bf && ar) {
        if (bf.pk) {
          out.push({ ...at, kind: "pk-retired" });
          continue;
        }
        out.push({ ...at, kind: "retired" });
      }
      alter(out, at, was, now, machined);
    }
    for (const [x, bi] of Object.entries(b.indexes ?? {})) {
      const ai = a.indexes?.[x];
      if (!ai) out.push({ ...on, index: x, kind: "index-dropped" });
      else if (JSON.stringify(ai) !== JSON.stringify(bi)) out.push({ ...on, index: x, kind: "index-changed", to: ai });
    }
    for (const [x, ai] of Object.entries(a.indexes ?? {})) if (!b.indexes?.[x]) out.push({ ...on, index: x, kind: "index-added", unique: !!ai.unique });
  }
  for (const [name, a] of Object.entries(after)) {
    if (!before[name] && !(a.id && beforeIds[a.id])) out.push({ entity: name, table: a.table, kind: "entity-added" });
  }
  return out;
}

// The changes to what a column holds, from `was` to `now` (both live, or a retirement).
function alter(out, at, was, now, machined) {
  if ((now.generated ?? null) !== (was.generated ?? null)) {
    out.push({ ...at, kind: "generated-changed" });
    return;
  }
  if (now.generated) return;
  if (now.required && !was.required) out.push({ ...at, kind: "required", default: now.default });
  if (!now.required && was.required) out.push({ ...at, kind: "optional" });
  if ((now.default ?? null) !== (was.default ?? null)) out.push({ ...at, kind: "default", from: was.default ?? null, to: now.default ?? null });
  if (was.machine && !now.machine) out.push({ ...at, kind: "machine-dropped" });
  if (!was.machine && now.machine) out.push({ ...at, kind: "machine-added" });
  if (was.enum && now.enum) {
    const removed = was.enum.filter((v) => !now.enum.includes(v));
    if (removed.length) out.push({ ...at, kind: "enum-narrowed", removed, admitted: now.enum, machined });
    else if (now.enum.some((v) => !was.enum.includes(v))) out.push({ ...at, kind: "enum-widened" });
  } else if (was.enum || was.check) {
    if (!now.enum && !now.check) out.push({ ...at, kind: "check-dropped" });
    else if (was.check !== now.check) out.push({ ...at, kind: "check-changed" });
  } else if (now.enum || now.check) {
    out.push({ ...at, kind: "check-added", machine: !!now.machine });
  }
  if (was.unique && !now.unique) out.push({ ...at, kind: "unique-dropped" });
  if (!was.unique && now.unique) out.push({ ...at, kind: "unique-added" });
  if ((was.ref ?? null) !== (now.ref ?? null)) {
    if (was.ref) out.push({ ...at, kind: "ref-dropped" });
    if (now.ref) out.push({ ...at, kind: "ref-added", ref: now.ref });
  }
}

// --- The plan ---

// The phases a migration runs in, whatever order the changes came in: what is relaxed (a NOT NULL,
// a default, a check, a unique, a reference, a machine's trigger, an index), then the rows moved (a
// backfill, a carry), then what is tightened (a NOT NULL, a unique, a reference, an index built
// again), so no row is moved against a rule the same migration removes, and nothing is tightened
// before the rows it holds are moved.
const RELAX = 0, DATA = 1, TIGHTEN = 2;

// The SQL each of the ledger's changes needs, in phase order, with what the app declared
// (#Migrations: the schema, carries, backfills) and what the app's migrations already dropped
// (`dropped`: a name to the migration that dropped it, from droppedBy). A change the model cannot
// settle alone is a need: the declaration it wants, by path. A refused change, or a declaration that
// cannot be applied, is refused. `make` writes a migration only when both are empty.
export function plan(changes, declared = {}, dropped = {}) {
  const schema = declared.schema ?? "public";
  const ops = [], refused = [], needs = [], advisories = [];
  for (const c of changes) {
    const v = verdicts[c.kind];
    const at = where(c);
    if (v === "refused") {
      refused.push({ at, kind: c.kind, why: reasons[c.kind](c) });
      continue;
    }
    // A name an earlier migration dropped, which the replay builds again: every fresh database runs
    // that migration after initdb built the name, and would lose it.
    for (const name of rebuilt(c)) {
      if (dropped[name]) refused.push({ at, kind: "rebuilt", why: `${name} was dropped by ${dropped[name]}, which every fresh database still runs after building it: fold ${dropped[name]} (once every database has run it) before building ${name} again` });
    }
    if (v === "advisory") {
      advisories.push({ at, kind: c.kind, why: c.kind === "check-added" ? "the replay adds the check NOT VALID: rows written before it are not checked, and no carry can be named, since what the column admitted before is not known" : "the replay restates the check NOT VALID: rows written before it are not checked" });
      continue;
    }
    if (c.kind === "index-added" && c.unique) advisories.push({ at, kind: c.kind, why: "the replay builds this unique index over every row, locking writes while it builds, and fails on a duplicate before any migration runs" });
    if (v !== "ledger") continue;
    const t = `${ident(schema)}.${ident(c.table)}`;
    const col = c.field && ident(c.field);
    const op = (phase, why, ...sql) => ops.push({ phase, at, why, sql: sql.join("\n") });
    switch (c.kind) {
      case "optional":
        op(RELAX, "no longer required", `ALTER TABLE ${t} ALTER COLUMN ${col} DROP NOT NULL;`);
        break;
      case "default":
        op(RELAX, c.to === null ? "its default removed" : `its default is ${c.to}`, `ALTER TABLE ${t} ALTER COLUMN ${col} ${c.to === null ? "DROP DEFAULT" : `SET DEFAULT ${c.to}`};`);
        break;
      case "required": {
        const fill = declared.backfill?.[c.entity]?.[c.field] ?? (sessionDefault(c.default) ? undefined : c.default);
        if (fill === undefined) {
          needs.push({ at, declare: `backfill.${c.entity}.${c.field}`, why: `made required, with ${c.default === undefined ? "no default" : `a default a migration cannot compute (${c.default})`}: the value (an SQL expression) its NULL rows take` });
          break;
        }
        op(DATA, "made required: its NULL rows filled", `UPDATE ${t} SET ${col} = ${fill} WHERE ${col} IS NULL;`);
        op(TIGHTEN, "made required", `ALTER TABLE ${t} ALTER COLUMN ${col} SET NOT NULL;`);
        break;
      }
      case "enum-narrowed": {
        const sql = carrySql(c, declared.carry?.[c.entity]?.[c.field], t, col, needs, refused, at);
        if (sql) op(DATA, `carried: it no longer admits ${c.removed.map(lit).join(", ")}`, sql);
        break;
      }
      case "check-dropped":
        op(RELAX, "its check removed", `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(`${c.table}_${c.field}_check`)};`);
        break;
      case "machine-dropped":
        op(RELAX, "no longer a machine's", `DROP TRIGGER IF EXISTS ${ident(`trg_${c.table}_${c.field}_machine`)} ON ${t};`);
        break;
      case "unique-dropped":
        op(RELAX, "no longer unique", `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(`${c.table}_${c.field}_key`)};`);
        break;
      case "unique-added":
        // The constraint pronto's inline UNIQUE makes, so a later unique-dropped finds it.
        op(TIGHTEN, "made unique", `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(`${c.table}_${c.field}_key`)}, ADD CONSTRAINT ${ident(`${c.table}_${c.field}_key`)} UNIQUE (${col});`);
        advisories.push({ at, kind: c.kind, why: "the constraint is built over every row, locking writes while it builds, and the migration fails on a duplicate" });
        break;
      case "ref-dropped":
        op(RELAX, "no longer a reference", `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(`${c.table}_${c.field}_fkey`)};`);
        break;
      case "ref-added":
        // pronto's inline REFERENCES, NOT VALID: rows written before it are not checked.
        op(TIGHTEN, `a reference to ${c.ref}`, `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(`${c.table}_${c.field}_fkey`)}, ADD CONSTRAINT ${ident(`${c.table}_${c.field}_fkey`)} FOREIGN KEY (${col}) REFERENCES ${ident(schema)}.${ident(c.ref)} ("id") ON DELETE CASCADE NOT VALID;`);
        break;
      case "index-dropped":
        op(RELAX, "index removed", `DROP INDEX IF EXISTS ${ident(schema)}.${ident(c.index)};`);
        break;
      case "index-changed":
        op(RELAX, "index changed: the old one dropped", `DROP INDEX IF EXISTS ${ident(schema)}.${ident(c.index)};`);
        op(TIGHTEN, "index changed: built again", createIndex(t, c.index, c.to));
        break;
    }
  }
  ops.sort((x, y) => x.phase - y.phase);
  return { ops, refused, needs, advisories };
}

// The names a replay-only change builds: a plain or unique index the replay creates, a check it adds,
// a machine's trigger and check 010 creates.
function rebuilt(c) {
  if (c.kind === "index-added") return [c.index];
  if (c.kind === "check-added") return [`${c.table}_${c.field}_check`, ...(c.machine ? [`trg_${c.table}_${c.field}_machine`] : [])];
  if (c.kind === "machine-added") return [`trg_${c.table}_${c.field}_machine`, `${c.table}_${c.field}_check`];
  return [];
}

// A carry, as one DO block: it runs only where a row holds a value gone, so on a fresh database
// (and on one carried already) it does nothing, and it turns off only the triggers that exist then.
function carrySql(c, carry, t, col, needs, refused, at) {
  const gone = c.removed.map(lit).join(", ");
  if (!carry) {
    needs.push({ at, declare: `carry.${c.entity}.${c.field}`, why: `rows may hold ${gone}, which it no longer admits: what each becomes (values: one of ${c.admitted.map(lit).join(", ")}), or the row's new columns (set)` });
    return null;
  }
  const missing = carry.values ? c.removed.filter((x) => carry.values[x] === undefined) : [];
  const stray = Object.entries(carry.values ?? {}).filter(([, to]) => !c.admitted.includes(to)).map(([x, to]) => `${x} → ${to}`);
  const both = carry.values && carry.set?.[c.field] !== undefined;
  const assign = { ...(carry.set ?? {}) };
  if (carry.values) assign[c.field] = `CASE ${col} ${c.removed.map((x) => `WHEN ${lit(x)} THEN ${lit(carry.values[x])}`).join(" ")} END`;
  const triggers = carry.triggers ?? [];
  const known = (c.machined ?? []).map((k) => `trg_${c.table}_${k}_machine`);
  // A machine's trigger lets a row whose state its chart does not know move anywhere, so the carried
  // column's own needs nothing; another machine's column the carry sets would be refused by its
  // chart, as the rows never walked it.
  const guarded = Object.keys(assign).filter((k) => k !== c.field && (c.machined ?? []).includes(k) && !triggers.includes(`trg_${c.table}_${k}_machine`));
  const strange = triggers.filter((x) => !known.includes(x));
  const problem = missing.length ? `values says nothing for ${missing.map(lit).join(", ")}`
    : stray.length ? `values carries to what it does not admit: ${stray.join(", ")}`
    : both ? `both values and set give ${c.field} its value`
    : assign[c.field] === undefined ? `the carry gives ${c.field} no value: name values, or set ${c.field}`
    : guarded.length ? `set moves ${guarded.join(", ")}, which a machine guards: list ${guarded.map((k) => `trg_${c.table}_${k}_machine`).join(", ")} in triggers`
    : strange.length ? `triggers names ${strange.join(", ")}, which is no machine's trigger on ${c.table} (${known.join(", ") || "it has none"})`
    : Object.values(assign).some((e) => e.includes("$carry$")) ? "set holds $carry$, the carry's own quote"
    : null;
  if (problem) {
    refused.push({ at, kind: "carry", why: problem });
    return null;
  }
  const exists = (x) => `EXISTS (SELECT FROM pg_trigger WHERE tgrelid = ${lit(t)}::regclass AND tgname = ${lit(x)})`;
  // Each moved column's check is lifted around the UPDATE and put back as the database holds it then.
  // The replay restates the newest check before any migration runs, so on a database that skipped
  // releases an older carry's destination (one a later migration carries on) is outside it, and an
  // UPDATE is checked even under NOT VALID. Put back NOT VALID, so the rows a later migration carries
  // on are left for it.
  const checks = Object.keys(assign).map((k, i) => ({ name: `${c.table}_${k}_check`, v: `check_${i + 1}` }));
  return [
    "DO $carry$",
    ...(checks.length ? ["DECLARE", ...checks.map((x) => `  ${x.v} text;`)] : []),
    "BEGIN",
    `  IF EXISTS (SELECT FROM ${t} WHERE ${col} IN (${gone})) THEN`,
    ...triggers.map((x) => `    IF ${exists(x)} THEN ALTER TABLE ${t} DISABLE TRIGGER ${ident(x)}; END IF;`),
    ...checks.flatMap((x) => [
      `    SELECT pg_get_constraintdef(oid) INTO ${x.v} FROM pg_constraint WHERE conrelid = ${lit(t)}::regclass AND conname = ${lit(x.name)};`,
      `    IF ${x.v} IS NOT NULL THEN ALTER TABLE ${t} DROP CONSTRAINT ${ident(x.name)}; END IF;`,
    ]),
    `    UPDATE ${t} SET ${Object.entries(assign).map(([k, e]) => `${ident(k)} = ${e}`).join(", ")} WHERE ${col} IN (${gone});`,
    ...checks.map((x) => `    IF ${x.v} IS NOT NULL THEN EXECUTE ${lit(`ALTER TABLE ${t} ADD CONSTRAINT ${ident(x.name)} `)} || ${x.v} || CASE WHEN ${x.v} LIKE '%NOT VALID' THEN '' ELSE ' NOT VALID' END; END IF;`),
    ...triggers.map((x) => `    IF ${exists(x)} THEN ALTER TABLE ${t} ENABLE TRIGGER ${ident(x)}; END IF;`),
    "  END IF;",
    "END $carry$;",
  ].join("\n");
}

const createIndex = (t, name, x) => `CREATE ${x.unique ? "UNIQUE " : ""}INDEX ${ident(name)} ON ${t}${x.using ? ` USING ${x.using}` : ""} (${x.cols.map(ident).join(", ")});`;

// A Postgres identifier, quoted; a string literal, quoted.
export const ident = (s) => `"${String(s).replaceAll('"', '""')}"`;
export const lit = (s) => `'${String(s).replaceAll("'", "''")}'`;

// The names a migration drops and does not build again in itself (`DROP INDEX`, `DROP CONSTRAINT`,
// `DROP TRIGGER` ... IF EXISTS), each to the first migration that dropped it. A replay that builds
// one again is refused until that migration is folded (plan).
export function droppedBy(migrations) {
  const out = {};
  for (const { name, json } of migrations) {
    const sql = (json.operations ?? []).map((o) => o.sql?.up ?? "").join("\n");
    const built = new Set([...sql.matchAll(/(?:ADD CONSTRAINT|INDEX) "([^"]+)"/g)].map((m) => m[1]));
    for (const [, x] of sql.matchAll(/DROP (?:INDEX IF EXISTS "[^"]+"\.|CONSTRAINT IF EXISTS |TRIGGER IF EXISTS )"([^"]+)"/g)) {
      if (!built.has(x)) out[x] ??= name;
    }
  }
  return out;
}

// --- The files ---

// A migration in pgroll's grammar, as pronto's code.state.migrations takes it: one raw SQL operation
// holding every change in phase order, each opening with where it is and why. pgroll runs a raw SQL
// operation alone (one with others is refused) and in one transaction, so the migration lands whole
// or not at all. It runs once on a live database (pgroll's ledger), after the replay of the emitted
// schema. Its constraints are checked as each statement ends: a deferred constraint trigger (an app's
// own, DEFERRABLE INITIALLY DEFERRED) would otherwise leave events pending, and Postgres refuses to
// alter a table with pending events, as a tighten after a backfill or a carry's ENABLE TRIGGER does.
export const migration = (ops) => ({
  operations: [{ sql: { up: ["-- Deferred constraints checked as each statement ends, so the tables can be altered after rows move.\nSET CONSTRAINTS ALL IMMEDIATE;", ...ops.map((o) => `-- ${o.at}: ${o.why}\n${o.sql}`)].join("\n\n") } }],
});

// The next migration's name: the day it is made (`date`, YYYYMMDD, the machine's calendar day), its
// four-digit count among the migrations made that day (`made`: the files and the one folded last), and
// a name that says what it does, in the alphabet pgroll's ledger takes (mecha's pgroll.#Name):
// 20261109_0001_retire_ref. pgroll's runner refuses a migration that sorts before one it has run, so
// the name sorts after every migration the app has (`others`: its own, and any written by hand): a
// later day already used (a machine in a zone ahead) is taken, with the next count. A migration
// written by hand that sorts after every dated name is refused: no name can follow it.
const DATED = /^(\d{8})_(\d{4})_/;
export function nextName(made, slug, date, others = []) {
  if (!/^\d{8}$/.test(date)) throw new Error(`"${date}": a migration's day is YYYYMMDD`);
  if (!/^[a-z][a-z0-9_]*$/.test(slug)) throw new Error(`"${slug}": a migration's name says what it does, in lowercase letters, digits and _, starting with a letter`);
  const all = [...made, ...others];
  const day = all.map((e) => e.match(DATED)?.[1]).filter(Boolean).reduce((a, b) => (b > a ? b : a), date);
  const count = all.map((e) => e.match(DATED)).filter((m) => m && m[1] === day).map((m) => Number(m[2])).reduce((a, b) => Math.max(a, b), 0);
  const name = `${day}_${String(count + 1).padStart(4, "0")}_${slug}`;
  const after = all.filter((o) => o > name).sort();
  if (after.length) throw new Error(`${name} sorts before the app's migration ${after.at(-1)}, which pgroll's runner has to run first: a migration written by hand is named <YYYYMMDD>_<NNNN>_<name> too`);
  return name;
}

// The migrations as code.state.migrations, each embedded from its file in migrations/. No migration
// declares nothing: an empty map would still give the cluster a migrate step.
export function ledger(pkg, names) {
  const head = "// generated by migrations/migrate.ts (make) — do not edit\n";
  if (!names.length) return `${head}package ${pkg}\n`;
  return `${head}@extern(embed)\n\npackage ${pkg}\n\n// The app's pgroll migrations (migrations/README.md): each runs once on a database that already\n// holds rows, after the replay of the emitted schema.\ncode: state: migrations: {\n${names.map((n) => `\t"${n}": _ @embed(file="migrations/${n}.json")`).join("\n")}\n}\n`;
}

// The sum of what make and fold write (atlas.sum's idea): the migration folded last, when one was,
// then a line per file with its SHA-256, and a first line over them all. A file edited, removed or
// added by hand no longer sums.
export async function sum(files, folded) {
  const lines = folded ? [`folded ${folded}`] : [];
  for (const f of [...files].sort((a, b) => a.name < b.name ? -1 : 1)) lines.push(`${f.name} h1:${await sha(f.text)}`);
  return `h1:${await sha(lines.join("\n"))}\n${lines.join("\n")}\n`;
}

// The migration a sum says was folded last, or null.
export const foldedOf = (sumText) => sumText.match(/^folded (\S+)$/m)?.[1] ?? null;

// What differs between a sum and the files: each file edited, missing or not in the sum.
export async function verify(sumText, files) {
  const recorded = Object.fromEntries(sumText.trim().split("\n").slice(1).filter((l) => l && !l.startsWith("folded ")).map((l) => l.split(" ")));
  const out = [];
  for (const f of files) {
    if (recorded[f.name] === undefined) out.push(`${f.name}: not made by make`);
    else if (recorded[f.name] !== `h1:${await sha(f.text)}`) out.push(`${f.name}: edited since make wrote it`);
  }
  for (const name of Object.keys(recorded)) if (!files.some((f) => f.name === name)) out.push(`${name}: removed`);
  if (!out.length && sumText !== await sum(files, foldedOf(sumText))) out.push("migrations.sum: edited");
  return out;
}

async function sha(text) {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return btoa(String.fromCharCode(...bytes));
}

// A model as the snapshot holds it: its format and the model, keys sorted, so the same model is the
// same file.
export const snapshot = (m) => JSON.stringify({ format: FORMAT, model: sorted(m) }, null, 2) + "\n";

// The model a snapshot holds; one of another format is refused.
export function fromSnapshot(text) {
  const s = JSON.parse(text);
  if (s.format !== FORMAT) throw new Error(`the snapshot is format ${s.format}; this plugin reads format ${FORMAT}`);
  return s.model;
}

function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort(byKey).map((k) => [k, sorted(v[k])]));
  return v;
}
// Field numbers sort as numbers, everything else as text.
const byKey = (a, b) => /^\d+$/.test(a) && /^\d+$/.test(b) ? Number(a) - Number(b) : a < b ? -1 : a > b ? 1 : 0;
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
