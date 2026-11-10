// pronto-migrations' rules, apart from what they act on (migrate.ts reads the files, runs git and
// cue, and writes): the model an app's emitted schema describes, the changes between two models, the
// SQL each change needs on a database that already holds rows, and the files that record them (a
// pgroll migration, the snapshot, the sum). Pure, so the cases (tests/unit/migrations.cue) hold them.

// The snapshot's format, and the version of pronto's .pronto/check-inputs.json this reads. A
// snapshot of an older format is upgraded (upgrade); one of a newer format, and facts of another
// version, are refused rather than misread: a fact read wrong would be a change, and a change is SQL
// on a live database.
export const FORMAT = 2;
export const FACTS_VERSION = 1;

// What an input that this plugin cannot read, or that disagrees with another, is: a pronto (or a
// plugin) this one does not read, or an app not generated. Either is refused, saying what to run.
const foreign = (what, why) => new Error(`${what}: ${why}: a pronto this plugin does not read (rerun bin/pronto-migrations from a pronto-plugins that reads it)`);
const ungenerated = (what, why) => new Error(`${what}: ${why}: run generate`);

// --- pronto's names ---

// What a column's constraints and trigger are named: Postgres's own names for a column's inline
// CHECK, UNIQUE and REFERENCES, pronto's for the check of a checked type (emit.cue, _typeCheck) and
// for the trigger of a machine's column (010_machines.sql). Every name this plugin builds, drops or
// reads on a column is one of these. An index's name is read from 005, as pronto writes it.
export const names = {
  check: (table, column) => `${table}_${column}_check`,
  type: (table, column) => `${table}_${column}_type`,
  unique: (table, column) => `${table}_${column}_key`,
  ref: (table, column) => `${table}_${column}_fkey`,
  machine: (table, column) => `trg_${table}_${column}_machine`,
};

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
  for (const [, name, col, list] of sql.matchAll(/ADD CONSTRAINT "(\w+)" CHECK \("(\w+)" IN \(([^)]*)\)\)/g)) {
    const suffix = names.check("", col);
    if (!name.endsWith(suffix)) continue;
    const table = name.slice(0, -suffix.length);
    (out[table] ??= {})[col] = [...list.matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1].replaceAll("''", "'"));
    read.add(names.machine(table, col));
  }
  for (const [, trigger] of sql.matchAll(/CREATE TRIGGER "(trg_\w+_machine)"/g)) {
    if (!read.has(trigger)) throw foreign("010_machines.sql", `the trigger ${trigger} has no check this reader knows`);
  }
  return out;
}

// Each table as the replay writes it, from the emitted 005_create_tables.sql: its columns, each with
// its type as Postgres holds it and its default, and its indexes, each by the name pronto gives it.
// A table's columns are each a line of its CREATE TABLE, and every one but the primary key again an
// ADD COLUMN IF NOT EXISTS, from the same clause (emit.cue, #colSql); an index is a CREATE [UNIQUE]
// INDEX IF NOT EXISTS, its name unquoted, so Postgres keeps it in lower case. By table. These are
// what a live database was given, where pronto's facts state the field and the index: the type a
// field's alias stands for, a default pronto writes that the facts do not state (a machine's initial
// state), and an index's name are read here and never restated.
export function parseTables(sql) {
  const out = {};
  const at = (t) => (out[t] ??= { columns: {}, indexes: {} });
  let table = null;
  for (const line of sql.split("\n")) {
    let m;
    if ((m = line.match(/^CREATE TABLE IF NOT EXISTS (?:"([^"]+)"|(\w+)) \($/))) {
      table = m[1] ?? m[2];
      at(table);
    } else if (table && line.startsWith(")")) {
      table = null;
    } else if (table && (m = line.match(/^ {2}"(\w+)" (.*?),?$/))) {
      at(table).columns[m[1]] ??= columnClause(m[2]);
    } else if ((m = line.match(/^ALTER TABLE (?:"([^"]+)"|(\w+)) ADD COLUMN IF NOT EXISTS "(\w+)" (.*);$/))) {
      at(m[1] ?? m[2]).columns[m[3]] = columnClause(m[4]);
    } else if ((m = line.match(/^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON (?:"([^"]+)"|(\w+))(?: USING (\w+))? \(([^)]*)\)/))) {
      const cols = m[6].split(",").map((c) => c.trim().replace(/^"(.*)"$/, "$1"));
      at(m[3] ?? m[4]).indexes[m[2].toLowerCase()] = m[1] ? { cols, unique: true } : clean({ cols, using: m[5] });
    }
  }
  return out;
}

// A column's type and default from its clause, the text after its name: `text DEFAULT 'x' NOT NULL
// CHECK (...)`, or `uuid PRIMARY KEY DEFAULT gen_random_uuid()`, as #colSql orders its parts. The
// default is found, and runs to the next of the clause's parts, outside quotes and parentheses. A
// type this does not read is kept as the clause, and refused where a field needs it.
const TYPE = /^(double precision|[A-Za-z_][A-Za-z0-9_]*(?:\(\s*\d+(?:\s*,\s*\d+)?\s*\))?)(?=\s|$)/;
const PARTS = [" NOT NULL", " NULL", " PRIMARY KEY", " UNIQUE", " REFERENCES ", " CHECK ", " CONSTRAINT ", " GENERATED ", " DEFAULT "];
function columnClause(clause) {
  const m = clause.match(TYPE);
  if (!m) return { unread: clause };
  const rest = clause.slice(m[0].length);
  const out = { sql: m[1].toLowerCase() };
  const at = outside(rest, 0, (i) => rest.startsWith(" DEFAULT ", i));
  if (at < rest.length) {
    const from = at + " DEFAULT ".length;
    out.default = rest.slice(from, outside(rest, from, (i) => PARTS.some((p) => rest.startsWith(p, i))));
  }
  return out;
}

// The first index from `from` where `stop` holds outside quotes and parentheses, or the text's end.
function outside(text, from, stop) {
  let depth = 0, quoted = false;
  for (let i = from; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === "'" && text[i + 1] === "'") i++;
      else if (ch === "'") quoted = false;
    } else if (ch === "'") quoted = true;
    else if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (depth === 0 && stop(i)) return i;
  }
  return text.length;
}

// A column's type as pronto's identity compares it: an alias named by its type (text is string),
// and a decimal with its precision and scale, which are its column's type too.
const canonical = (f, types) => {
  const t = types?.aliases?.[f.type] ?? f.type;
  return t === "decimal" ? `decimal(${f.precision ?? ""},${f.scale ?? ""})` : t;
};

// The model of an app's database: each entity with a table (pronto's `server`), keyed by its
// message, with its live fields and its retired ones by number. The proto says what a column is (its
// number, its name, its wire type, a retirement); .pronto/check-inputs.json (`inputs`, pronto's facts
// for its own checks, from the same CUE) says what it holds (required, default, enum, check, unique,
// reference, generated, also for a retired field, which keeps what pronto still emits for it) and the
// entity's table and indexes; `sql.tables` (005_create_tables.sql) the column's type and the default
// the replay writes; `sql.machines` (010_machines.sql) the states of a machine's column.
// Where these disagree the app was not generated: an error, not a guess.
export function model(protoText, inputs, sql = {}) {
  if (inputs.version !== FACTS_VERSION) throw foreign(".pronto/check-inputs.json", `version ${inputs.version}, where this plugin reads version ${FACTS_VERSION}`);
  const proto = parseProto(protoText);
  const machines = parseMachines(sql.machines ?? "");
  const tables = parseTables(sql.tables ?? "");
  const out = {};
  for (const [name, e] of Object.entries(inputs.entities ?? {})) {
    if (!e.server) continue;
    const msg = proto[name];
    if (!msg) throw ungenerated(name, "a table with no message in entities.proto");
    if (!e.cel?.enums || !e.cel?.checks || !Array.isArray(e.uniques)) throw foreign(".pronto/check-inputs.json", `${name} has no cel.enums, cel.checks or uniques`);
    if (!tables[e.table]) throw ungenerated(name, `005_create_tables.sql creates no table ${e.table}`);
    const { columns, indexes: written } = tables[e.table];
    const machined = machines[e.table] ?? {};
    const enums = { ...e.cel.enums, ...machined };
    const facts = (f) => {
      const col = columns[f.name];
      if (!col) throw ungenerated(`${name}.${f.name}`, `005_create_tables.sql has no column ${e.table}.${f.name}`);
      if (col.unread !== undefined) throw foreign("005_create_tables.sql", `${e.table}.${f.name} has the clause "${col.unread}", whose type this does not read`);
      // The replay writes the facts' default, else one pronto adds that they do not state.
      if (!f.generated && f.default !== undefined && f.default !== col.default) throw ungenerated(`${name}.${f.name}`, `its default is ${f.default}, and 005_create_tables.sql writes ${col.default ?? "none"}`);
      return clean({
        name: f.name,
        type: canonical(f, inputs.types),
        sql: col.sql,
        required: !!f.required,
        default: f.generated ? f.default : col.default,
        enum: enums[f.name],
        machine: machined[f.name] ? true : undefined,
        check: enums[f.name] ? undefined : e.cel.checks[f.name],
        unique: f.unique || undefined,
        ref: f.ref,
        generated: f.generated,
        pk: f.pk || undefined,
      });
    };
    const fields = {}, retired = {};
    for (const f of e.fields) {
      const n = String(f.ordinal);
      if (f.retired) {
        if (!msg.reserved.numbers.includes(f.ordinal) || !msg.reserved.names.includes(f.name)) throw ungenerated(`${name}.${f.name}`, `retired, and entities.proto does not reserve ${n} and "${f.name}"`);
        retired[n] = facts(f);
        continue;
      }
      const p = msg.fields[n];
      if (!p || p.name !== f.name) throw ungenerated(`${name}.${f.name}`, `entities.proto has ${p ? p.name : "nothing"} at ${n}`);
      fields[n] = { ...facts(f), proto: p.type };
    }
    for (const [n, p] of Object.entries(msg.fields)) {
      if (!fields[n]) throw ungenerated(name, `entities.proto has ${p.name} at ${n}, which .pronto/check-inputs.json does not`);
    }
    // The entity's indexes, each as 005 writes it: a unique by the name the entity gives it, a plain
    // index by the one pronto gives it, found by its column.
    const indexes = {};
    for (const u of e.uniques) {
      const x = written[u.name.toLowerCase()];
      if (!x?.unique || JSON.stringify(x.cols) !== JSON.stringify(u.cols)) throw ungenerated(name, `005_create_tables.sql has no unique index ${u.name.toLowerCase()} on (${u.cols.join(", ")})`);
      indexes[u.name.toLowerCase()] = x;
    }
    for (const i of e.indexes ?? []) {
      const found = Object.entries(written).filter(([, x]) => !x.unique && x.cols.length === 1 && x.cols[0] === i.on && x.using === i.using);
      if (found.length !== 1) throw ungenerated(name, `005_create_tables.sql has ${found.length ? "more than one" : "no"} ${i.using} index on ${e.table} (${i.on})`);
      indexes[found[0][0]] = found[0][1];
    }
    out[name] = clean({ table: e.table, id: e.id, fields, retired, indexes });
  }
  return sorted(out);
}

// --- The changes ---

// Where a change is: the entity's column, its index, or the entity.
export const where = (c) => c.field ? `${c.entity}.${c.field}` : c.index ? `${c.entity} index ${c.index}` : c.entity;

// A default's SQL with its string literals emptied, so a word inside one ('random') is no call.
const code = (d) => String(d).replace(/'(?:[^']|'')*'/g, "''");

// A default read from the session (the caller's claims, a setting): NULL in a migration, so it fills
// nothing. Postgres folds an unquoted name to lower case, so it is matched in any case.
export const sessionDefault = (d) => d !== undefined && /\b(auth_\w*|current_setting|current_user|session_user|current_role)\b/i.test(code(d));

// A default that takes another value each time it is read (a clock, a random value, a sequence, the
// transaction): the replay gives every row a table already holds the value it reads as it runs. A
// time keyword in a literal ('now'::timestamptz) is read as the statement runs too.
export const volatileDefault = (d) => d !== undefined && (/\b(now|clock_timestamp|statement_timestamp|transaction_timestamp|timeofday|random|random_normal|gen_random_uuid|gen_random_bytes|uuidv4|uuidv7|uuid_generate_v\w*|nextval|txid_current|pg_current_xact_id|current_timestamp|current_date|current_time|localtimestamp|localtime)\b/i.test(code(d)) || /'\s*(now|today|tomorrow|yesterday)\s*'/i.test(d));

// A default that is the same value whenever it is read: a literal (a string, a number, true, false,
// NULL), cast or not, that is no time keyword. Only such a default marks the rows the replay filled.
export const constantDefault = (d) => d !== undefined && !volatileDefault(d) && /^\s*\(?\s*(?:'(?:[^']|'')*'|[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|true|false|null)\s*\)?(?:\s*::\s*[a-z_][a-z0-9_ ]*(?:\(\s*\d+(?:\s*,\s*\d+)?\s*\))?(?:\[\])?)*\s*$/i.test(d);

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
        if (af) out.push(af.required && (af.default === undefined || sessionDefault(af.default)) && !af.generated ? { ...at, kind: "required-added" } : clean({ ...at, kind: "field-added", default: af.default, machine: af.machine, generated: af.generated, sql: af.sql }));
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
  // A machine added brings its check with it (010 builds both), so its check is no change of its own.
  const machineAdded = !was.machine && now.machine;
  if (machineAdded) out.push({ ...at, kind: "machine-added" });
  if (was.enum && now.enum) {
    const removed = was.enum.filter((v) => !now.enum.includes(v));
    if (removed.length) out.push({ ...at, kind: "enum-narrowed", removed, admitted: now.enum, machined });
    else if (now.enum.some((v) => !was.enum.includes(v))) out.push({ ...at, kind: "enum-widened" });
  } else if (was.enum || was.check) {
    if (!now.enum && !now.check) out.push({ ...at, kind: "check-dropped" });
    else if (was.check !== now.check) out.push({ ...at, kind: "check-changed" });
  } else if ((now.enum || now.check) && !machineAdded) {
    out.push({ ...at, kind: "check-added" });
  }
  if (was.unique && !now.unique) out.push({ ...at, kind: "unique-dropped" });
  if (!was.unique && now.unique) out.push({ ...at, kind: "unique-added" });
  if ((was.ref ?? null) !== (now.ref ?? null)) {
    if (was.ref) out.push({ ...at, kind: "ref-dropped" });
    if (now.ref) out.push({ ...at, kind: "ref-added", ref: now.ref });
  }
}

// --- The kinds of change ---

// The phases a migration runs in, whatever order the changes came in: what is relaxed (a NOT NULL,
// a default, a check, a unique, a reference, a machine's trigger, an index), then the rows filled (a
// backfill, a copy), then the rows carried, then what is tightened (a NOT NULL, a unique, a
// reference, an index built again). No row is moved against a rule the same migration removes,
// nothing is tightened before the rows it holds are moved, and a fill or a copy reads a row as the
// release before left it, before a carry moves it.
const RELAX = 0, FILL = 1, DATA = 2, TIGHTEN = 3;

// Every kind of change diff reports, in one place. Its verdict: refused (no migration can make it
// safe for every holder of the data), the ledger's (an existing column, constraint or index the
// replay of the emitted schema never alters), the replay's (what pronto's emitted CREATE ... IF NOT
// EXISTS makes by itself), or advisory. Then, as each applies: why it is refused, and what is
// admitted instead (pronto's docs/schema-change-admission.md: an addition or a retirement, never a
// rename, drop or retype); what to note; the names the replay builds for it, which a migration may
// have dropped; and the SQL it needs (`ops`, given the plan's context, `x`). plan refuses a kind
// that is not here: a change it has no rule for is never taken for the replay's.
export const KINDS = {
  "entity-dropped": { verdict: "refused", why: () => "an entity is never removed, as its rows and every reader of them stay: retire each of its fields but the primary key (retired: true) instead, which keeps its table, and make relaxes what the columns held" },
  "entity-renamed": { verdict: "refused", why: (c) => `renamed to ${c.to}: a new entity beside this one, never a rename` },
  "table-renamed": { verdict: "refused", why: (c) => `its table renamed to ${c.to}: every reader of the table breaks` },
  "field-dropped": { verdict: "refused", why: () => "a field is retired (retired: true), never removed: its number stays reserved" },
  "field-renamed": { verdict: "refused", why: (c) => `renamed to ${c.to}: a reader of the JSON reads it by name, so a rename is a new field beside the retired one, which a backfill can copy` },
  "field-retyped": { verdict: "refused", why: (c) => `retyped from ${c.from} to ${c.to}: a retype is a new field beside the retired one, which a backfill can copy` },
  "field-revived": { verdict: "refused", why: () => "its number was retired: a retired number is never used again" },
  "retirement-dropped": { verdict: "refused", why: () => "a retired number stays reserved" },
  "generated-changed": { verdict: "refused", why: () => "a generated column is not altered in place: re-creating it gives it a new attnum, which every replay reports as a column gone (a retired generated field keeps its generated expression)" },
  "pk-retired": { verdict: "refused", why: () => "a primary key is never retired" },
  "required-added": {
    verdict: "refused",
    why: () => "the replay adds a required column to every row the table already holds, before any migration runs, so it needs a default a migration's session can compute (not auth_uid()); or add it optional, then make it required in a later release, whose migration fills its NULLs (backfill): in one release, the replay adds the final NOT NULL first",
  },
  required: {
    verdict: "ledger",
    ops: (c, x) => {
      const fill = fillOf(x.declared("backfill")) ?? (sessionDefault(c.default) || c.default === undefined ? undefined : { value: c.default, triggers: [] });
      if (fill === undefined) return x.need("backfill", `made required, with ${c.default === undefined ? "no default" : `a default a migration cannot compute (${c.default})`}: the value (an SQL expression of the row) its NULL rows take`);
      if (!fillable(fill, x, [])) return;
      // Its own checks stay: the value it fills is the model's, which those checks (the replay's
      // newest) admit, or the migration fails.
      x.op(FILL, "made required: its NULL rows filled", moveSql("$fill$", x.t, `${x.col} IS NULL`, `UPDATE ${x.t} SET ${x.col} = ${fill.value} WHERE ${x.col} IS NULL;`, fill.triggers, [names.check(c.table, c.field), names.type(c.table, c.field)]));
      x.op(TIGHTEN, "made required", `ALTER TABLE ${x.t} ALTER COLUMN ${x.col} SET NOT NULL;`);
    },
  },
  optional: { verdict: "ledger", ops: (_c, x) => x.op(RELAX, "no longer required", `ALTER TABLE ${x.t} ALTER COLUMN ${x.col} DROP NOT NULL;`) },
  default: { verdict: "ledger", ops: (c, x) => x.op(RELAX, c.to === null ? "its default removed" : `its default is ${c.to}`, `ALTER TABLE ${x.t} ALTER COLUMN ${x.col} ${c.to === null ? "DROP DEFAULT" : `SET DEFAULT ${c.to}`};`) },
  "enum-narrowed": {
    verdict: "ledger",
    ops: (c, x) => {
      const sql = carrySql(c, x);
      if (sql) x.op(DATA, `carried: it no longer admits ${c.removed.map(lit).join(", ")}`, sql);
    },
  },
  "check-dropped": { verdict: "ledger", ops: (c, x) => x.drop(RELAX, "its check removed", "constraint", names.check(c.table, c.field)) },
  "machine-dropped": { verdict: "ledger", ops: (c, x) => x.drop(RELAX, "no longer a machine's", "trigger", names.machine(c.table, c.field)) },
  "unique-dropped": { verdict: "ledger", ops: (c, x) => x.drop(RELAX, "no longer unique", "constraint", names.unique(c.table, c.field)) },
  "unique-added": {
    verdict: "ledger",
    // The constraint pronto's inline UNIQUE makes, so a later unique-dropped finds it.
    ops: (c, x) => x.build(TIGHTEN, "made unique", names.unique(c.table, c.field), `UNIQUE (${x.col})`),
    note: () => "the constraint is built over every row, locking writes while it builds, and the migration fails on a duplicate",
  },
  "ref-dropped": { verdict: "ledger", ops: (c, x) => x.drop(RELAX, "no longer a reference", "constraint", names.ref(c.table, c.field)) },
  "ref-added": {
    verdict: "ledger",
    // pronto's inline REFERENCES, NOT VALID: rows written before it are not checked.
    ops: (c, x) => x.build(TIGHTEN, `a reference to ${c.ref}`, names.ref(c.table, c.field), `FOREIGN KEY (${x.col}) REFERENCES ${ident(x.schema)}.${ident(c.ref)} ("id") ON DELETE CASCADE NOT VALID`),
  },
  "index-dropped": { verdict: "ledger", ops: (c, x) => x.drop(RELAX, "index removed", "index", c.index) },
  "index-changed": {
    verdict: "ledger",
    ops: (c, x) => {
      x.drop(RELAX, "index changed: the old one dropped", "index", c.index);
      x.op(TIGHTEN, "index changed: built again", createIndex(x.t, c.index, c.to), { builds: [c.index] });
    },
  },
  retired: { verdict: "replay" },
  "entity-added": { verdict: "replay" },
  "field-added": {
    verdict: "replay",
    // A backfill declared for a column added copies into it, after the replay added it, what the rows
    // the table held should hold (another column, the field a rename retired): a rename spelled as a
    // retirement beside an addition keeps its data. Beside a retirement in the same change, as a
    // rename is, the backfill is a need, so a migration made again never loses the copy; DEFAULT says
    // the rows keep the replay's default. The copy touches only the rows that still hold what the
    // replay gave them, when that is known: NULL, or a constant default. A row written since, or
    // seeded, with a value of its own keeps it; one written with the default itself cannot be told
    // from a row the replay filled, and takes the copy. Any other default (a clock, a function) marks
    // nothing, so the copy touches every row that differs, which is noted. A json column is compared
    // as jsonb, as json has no equality. A copy is not a transition, so a machine's column is copied
    // with its trigger off, and so is any trigger the backfill names. A generated column takes none.
    ops: (c, x) => {
      const fill = fillOf(x.declared("backfill"));
      if (c.generated) {
        if (fill !== undefined && fill.value !== "DEFAULT") x.refuse("backfill", "a generated column is computed by Postgres: it takes no backfill");
        return;
      }
      if (fill === undefined) {
        if (x.renaming) x.need("backfill", `added beside a field ${c.entity} retires in the same change, as a rename is: the SQL of the row the rows it held take (the retired column), or DEFAULT to keep the replay's default`);
        return;
      }
      if (fill.value === "DEFAULT") return;
      if (!fillable(fill, x, [c.default])) return;
      const json = c.sql === "json";
      const as = (e) => json ? `(${e})::jsonb` : `(${e})`;
      const column = json ? `${x.col}::jsonb` : x.col;
      const filled = c.default === undefined ? `${x.col} IS NULL` : constantDefault(c.default) ? `${column} IS NOT DISTINCT FROM ${as(c.default)}` : null;
      const where = [filled, `${column} IS DISTINCT FROM ${as(fill.value)}`].filter(Boolean).join(" AND ");
      x.op(FILL, "added: the rows the table held take their copy", moveSql("$fill$", x.t, where, `UPDATE ${x.t} SET ${x.col} = ${fill.value} WHERE ${where};`, [...fill.triggers, ...(c.machine ? [names.machine(c.table, c.field)] : [])], [names.check(c.table, c.field), names.type(c.table, c.field)]));
    },
    note: (c, x) => {
      const fill = fillOf(x.declared("backfill"));
      if (c.generated || fill?.value === "DEFAULT") return undefined;
      if (fill === undefined) return volatileDefault(c.default) && !x.renaming ? `the replay gives every row the table holds ${c.default}, as it reads when the replay runs (the deploy's time, or a new value a row): declare backfill.${c.entity}.${c.field}, the SQL of the row they should take (another column, say), and make copies it` : undefined;
      if (c.default === undefined || constantDefault(c.default)) return undefined;
      return `the copy cannot tell a row the replay gave ${c.default} from one written since with a value of its own, so it copies into every row whose value differs (a seed row, a row written between the replay and the migration): a constant default, or none, lets it touch only the rows the replay filled`;
    },
  },
  "enum-widened": { verdict: "replay" },
  "index-added": {
    verdict: "replay",
    builds: (c) => [c.index],
    note: (c) => c.unique ? "the replay builds this unique index over every row, locking writes while it builds, and fails on a duplicate before any migration runs" : undefined,
  },
  "machine-added": {
    verdict: "replay",
    builds: (c) => [names.machine(c.table, c.field), names.check(c.table, c.field)],
    note: () => "010 adds the machine's states as its check, NOT VALID: rows written before are not checked against them",
  },
  "check-changed": { verdict: "advisory", note: () => "the replay restates the check NOT VALID: rows written before it are not checked" },
  "check-added": {
    verdict: "advisory",
    builds: (c) => [names.check(c.table, c.field)],
    note: () => "the replay adds the check NOT VALID: rows written before it are not checked, and no carry can be named, since what the column admitted before is not known",
  },
};

// A change's verdict as its kind states it, before any plan; a kind with no rule is an error, never
// the replay's. A change the replay makes that also writes SQL in a plan (a copy into an added
// column) is the ledger's there: plan().verdicts says each change's verdict as made.
export function verdict(c) {
  const k = KINDS[c.kind];
  if (!k) throw new Error(`${where(c)}: a change of kind ${c.kind}, which this plugin has no rule for`);
  return k.verdict;
}

// What the app may declare for a change (#Migrations): the rows a narrowed enum carries, and the value
// a column added or made required fills.
const DECLARED = ["carry", "backfill"];

// --- The plan ---

// The SQL each of the ledger's changes needs, in phase order, with what the app declared
// (#Migrations: the schema, carries, backfills), what the app's migrations already dropped
// (`dropped`: a name to the migration that dropped it, from droppedBy), and the declarations a
// migration made before recorded (`inherited`, for rebase: read where the app declares none, and
// never refused when no change reads them). A change the model cannot
// settle alone is a need: the declaration it wants, by path. A refused change, a declaration that
// cannot be applied, and one no change reads (left from an earlier migration, it would fill a later
// change to the same column) are refused. `make` writes a migration only when both are empty. Each
// op says the names it drops and builds for good.
export function plan(changes, declared = {}, dropped = {}, inherited = {}) {
  const schema = declared.schema ?? "public";
  const ops = [], refused = [], needs = [], advisories = [], verdicts = [];
  const read = new Set();
  // The declarations the plan read, which its migration records (declaredIn).
  const used = {};
  // The entities that retire a field in this change: a column added beside one is a rename's.
  const retiring = new Set(changes.filter((c) => c.kind === "retired").map((c) => c.entity));
  for (const c of changes) {
    const v = verdict(c);
    const before = ops.length;
    const k = KINDS[c.kind];
    const at = where(c);
    if (v === "refused") {
      // A declaration at a refused change is that change's: refused once, with it.
      if (c.field) for (const what of DECLARED) read.add(`${what}.${c.entity}.${c.field}`);
      refused.push({ at, kind: c.kind, why: k.why(c) });
      verdicts.push({ at, kind: c.kind, verdict: v });
      continue;
    }
    // A name an earlier migration dropped, which the replay builds again: every fresh database runs
    // that migration after initdb built the name, and would lose it.
    for (const name of new Set(k.builds?.(c) ?? [])) {
      if (dropped[name]) refused.push({ at, kind: "rebuilt", why: `${name} was dropped by ${dropped[name]}, which every fresh database still runs after building it: fold ${dropped[name]} (once every database has run it) before building ${name} again` });
    }
    const t = `${ident(schema)}.${ident(c.table)}`;
    const op = (phase, why, sql, { drops = [], builds = [] } = {}) => ops.push({ phase, at, why, sql, drops, builds });
    const x = {
      schema,
      t,
      col: c.field && ident(c.field),
      renaming: retiring.has(c.entity),
      op,
      // A name dropped for good: an index by its schema, a trigger on its table, a constraint.
      drop: (phase, why, what, name) => op(phase, why, {
        index: `DROP INDEX IF EXISTS ${ident(schema)}.${ident(name)};`,
        trigger: `DROP TRIGGER IF EXISTS ${ident(name)} ON ${t};`,
        constraint: `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(name)};`,
      }[what], { drops: [name] }),
      // A constraint built under its name, dropped first where an earlier one is.
      build: (phase, why, name, def) => op(phase, why, `ALTER TABLE ${t} DROP CONSTRAINT IF EXISTS ${ident(name)}, ADD CONSTRAINT ${ident(name)} ${def};`, { builds: [name] }),
      need: (what, why) => needs.push({ at, declare: `${what}.${c.entity}.${c.field}`, why }),
      refuse: (kind, why) => refused.push({ at, kind, why }),
      // A declaration is read only by a rule that takes it (a backfill by a column added or made
      // required, a carry by a narrowed enum), so one left beside any other change is still refused.
      // One the app declares wins over one inherited from a migration made before (rebase).
      declared: (what) => {
        read.add(`${what}.${c.entity}.${c.field}`);
        const d = declared[what]?.[c.entity]?.[c.field] ?? inherited[what]?.[c.entity]?.[c.field];
        if (d !== undefined) ((used[what] ??= {})[c.entity] ??= {})[c.field] = d;
        return d;
      },
    };
    k.ops?.(c, x);
    const note = k.note?.(c, x);
    if (note) advisories.push({ at, kind: c.kind, why: note });
    // A change the replay makes that also wrote SQL here (a copy) is the ledger's too.
    verdicts.push({ at, kind: c.kind, verdict: v === "replay" && ops.length > before ? "ledger" : v });
  }
  for (const what of DECLARED) {
    for (const [entity, columns] of Object.entries(declared[what] ?? {})) {
      for (const column of Object.keys(columns ?? {})) {
        if (!read.has(`${what}.${entity}.${column}`)) refused.push({ at: `${entity}.${column}`, kind: "declaration", why: `schemaMigrations.${what}.${entity}.${column} is for no change since the snapshot: remove it, as a declaration serves the migration it was written for, and one left would be read into a later change to ${entity}.${column}` });
      }
    }
  }
  ops.sort((a, b) => a.phase - b.phase);
  return { ops, refused, needs, advisories, verdicts, used };
}

// A backfill as declared: the SQL expression of the row alone, or with the triggers the fill would
// trip (an app's own, say) to turn off around it.
const fillOf = (d) => d === undefined ? undefined : typeof d === "string" ? { value: d, triggers: [] } : { value: d.value, triggers: d.triggers ?? [] };

// A backfill is an SQL expression put inside a $fill$-quoted block, with the column's default and the
// triggers it names, so none may hold $fill$; a trigger is named by its identifier.
function fillable(fill, x, more) {
  const bad = fill.triggers.filter((t) => !TRIGGER.test(t));
  if (bad.length) {
    x.refuse("backfill", `triggers names ${bad.join(", ")}, which is no trigger's name (letters, digits, _ and $)`);
    return false;
  }
  if (![fill.value, ...fill.triggers, ...more.filter(Boolean)].some((e) => String(e).includes("$fill$"))) return true;
  x.refuse("backfill", "the backfill holds $fill$, its block's own quote");
  return false;
}

// A trigger's name as a carry or a backfill lists it: an identifier, as Postgres keeps an unquoted one
// or pronto writes one.
const TRIGGER = /^[A-Za-z_][A-Za-z0-9_$]*$/;

// A carry, as one DO block: it runs only where a row holds a value gone, so on a fresh database
// (and on one carried already) it does nothing, and it turns off only the triggers that are on then.
function carrySql(c, x) {
  const carry = x.declared("carry");
  const gone = c.removed.map(lit).join(", ");
  if (!carry) {
    x.need("carry", `rows may hold ${gone}, which it no longer admits: what each becomes (values: one of ${c.admitted.map(lit).join(", ")}), or the row's new columns (set)`);
    return null;
  }
  const missing = carry.values ? c.removed.filter((v) => carry.values[v] === undefined) : [];
  const stray = Object.entries(carry.values ?? {}).filter(([, to]) => !c.admitted.includes(to)).map(([v, to]) => `${v} → ${to}`);
  const both = carry.values && carry.set?.[c.field] !== undefined;
  const assign = { ...(carry.set ?? {}) };
  if (carry.values) assign[c.field] = `CASE ${x.col} ${c.removed.map((v) => `WHEN ${lit(v)} THEN ${lit(carry.values[v])}`).join(" ")} END`;
  // Any trigger on the table may be listed: another machine's, or one of the app's own (a guard that
  // refuses to change a row once final) that the move would trip.
  const triggers = carry.triggers ?? [];
  // A machine's trigger lets a row whose state its chart does not know move anywhere, so the carried
  // column's own needs nothing; another machine's column the carry sets would be refused by its
  // chart, as the rows never walked it.
  const guarded = Object.keys(assign).filter((k) => k !== c.field && (c.machined ?? []).includes(k) && !triggers.includes(names.machine(c.table, k)));
  const problem = missing.length ? `values says nothing for ${missing.map(lit).join(", ")}`
    : stray.length ? `values carries to what it does not admit: ${stray.join(", ")}`
    : both ? `both values and set give ${c.field} its value`
    : assign[c.field] === undefined ? `the carry gives ${c.field} no value: name values, or set ${c.field}`
    : guarded.length ? `set moves ${guarded.join(", ")}, which a machine guards: list ${guarded.map((k) => names.machine(c.table, k)).join(", ")} in triggers`
    : triggers.some((t) => !TRIGGER.test(t)) ? `triggers names ${triggers.filter((t) => !TRIGGER.test(t)).join(", ")}, which is no trigger's name (letters, digits, _ and $)`
    : Object.values(assign).some((e) => e.includes("$carry$")) ? "set holds $carry$, the carry's own quote"
    : triggers.some((t) => t.includes("$carry$")) ? "triggers holds $carry$, the carry's own quote"
    : null;
  if (problem) {
    x.refuse("carry", problem);
    return null;
  }
  // The moved columns' own checks are lifted too: the replay restates the newest check before any
  // migration runs, so on a database that skipped releases an older carry's destination (one a later
  // migration carries on) is outside it.
  return moveSql("$carry$", x.t, `${x.col} IN (${gone})`, `UPDATE ${x.t} SET ${Object.entries(assign).map(([k, e]) => `${ident(k)} = ${e}`).join(", ")} WHERE ${x.col} IN (${gone});`, triggers);
}

// Rows moved (a carry, a backfill, a copy) as one DO block, quoted by `tag`, that runs only where a
// row matches `where`, so a fresh database, or one moved already, runs nothing. Postgres checks every
// check on a row it updates, even one NOT VALID, and the replay restates every check NOT VALID, so a
// row written before a check was restated, on any of its columns, would stop the move. Every check on
// the table but `kept` is lifted around the update and put back as the database held it, NOT VALID,
// as the replay leaves it. Of `triggers`, those that exist and are on are turned off around it, and
// each is put back in the mode it had (origin, always, replica); one already off stays off. With
// triggers to turn off, the block takes the table's ACCESS EXCLUSIVE lock first, so it never climbs
// from the triggers' lock to the one lifting a check needs, which deadlocks an app transaction that
// read the table and then writes it.
function moveSql(tag, t, where, update, triggers = [], kept = []) {
  const each = "FOR pronto_i IN 1 .. coalesce(array_length(pronto_lifted, 1), 0) LOOP";
  const eachOff = "FOR pronto_t IN 1 .. coalesce(array_length(pronto_off, 1), 0) LOOP";
  return [
    `DO ${tag}`,
    "DECLARE",
    "  pronto_lifted text[];",
    "  pronto_defs text[];",
    ...(triggers.length ? ["  pronto_off text[];", "  pronto_modes text[];"] : []),
    "BEGIN",
    `  IF EXISTS (SELECT FROM ${t} WHERE ${where}) THEN`,
    ...(triggers.length ? [
      `    LOCK TABLE ${t} IN ACCESS EXCLUSIVE MODE;`,
      `    SELECT array_agg(tgname::text ORDER BY tgname), array_agg(tgenabled::text ORDER BY tgname) INTO pronto_off, pronto_modes FROM pg_trigger WHERE tgrelid = ${lit(t)}::regclass AND tgname = ANY (ARRAY[${triggers.map(lit).join(", ")}]) AND tgenabled <> 'D';`,
      `    ${eachOff} EXECUTE ${lit(`ALTER TABLE ${t} DISABLE TRIGGER `)} || quote_ident(pronto_off[pronto_t]); END LOOP;`,
    ] : []),
    `    SELECT array_agg(conname ORDER BY conname), array_agg(pg_get_constraintdef(oid) ORDER BY conname) INTO pronto_lifted, pronto_defs FROM pg_constraint WHERE conrelid = ${lit(t)}::regclass AND contype = 'c'${kept.length ? ` AND conname <> ALL (ARRAY[${kept.map(lit).join(", ")}])` : ""};`,
    `    ${each} EXECUTE ${lit(`ALTER TABLE ${t} DROP CONSTRAINT `)} || quote_ident(pronto_lifted[pronto_i]); END LOOP;`,
    `    ${update}`,
    `    ${each} EXECUTE ${lit(`ALTER TABLE ${t} ADD CONSTRAINT `)} || quote_ident(pronto_lifted[pronto_i]) || ' ' || pronto_defs[pronto_i] || CASE WHEN pronto_defs[pronto_i] LIKE '%NOT VALID' THEN '' ELSE ' NOT VALID' END; END LOOP;`,
    ...(triggers.length ? [`    ${eachOff} EXECUTE ${lit(`ALTER TABLE ${t} ENABLE `)} || CASE pronto_modes[pronto_t] WHEN 'A' THEN 'ALWAYS ' WHEN 'R' THEN 'REPLICA ' ELSE '' END || 'TRIGGER ' || quote_ident(pronto_off[pronto_t]); END LOOP;`] : []),
    "  END IF;",
    `END ${tag};`,
  ].join("\n");
}

const createIndex = (t, name, x) => `CREATE ${x.unique ? "UNIQUE " : ""}INDEX ${ident(name)} ON ${t}${x.using ? ` USING ${x.using}` : ""} (${x.cols.map(ident).join(", ")});`;

// A Postgres identifier, quoted; a string literal, quoted.
export const ident = (s) => `"${String(s).replaceAll('"', '""')}"`;
export const lit = (s) => `'${String(s).replaceAll("'", "''")}'`;

// The names the migrations, in order, leave dropped (`DROP INDEX`, `DROP CONSTRAINT`, `DROP TRIGGER`
// ... IF EXISTS, and not built again in the same migration or a later one), each to the first
// migration that dropped it since it was last built. A replay that builds one again is refused until
// that migration is folded (plan). Read from each migration's SQL, as its file is all that stays of
// it; every op says what it drops and builds, and the cases hold this reading to that.
export function droppedBy(migrations) {
  const out = {};
  for (const { name, json } of migrations) {
    // A move's DO block (a carry, a backfill, a copy) lifts and puts back checks by what the database
    // holds, naming none, and holds the app's own SQL (a set, a fill), which is left unread: no text
    // the app wrote can read as a drop or a build.
    const sql = (json.operations ?? []).map((o) => o.sql?.up ?? "").join("\n").replace(/DO (\$carry\$|\$fill\$)[\s\S]*?END \1;/g, "").replace(/^--.*$/gm, "");
    const built = new Set([...sql.matchAll(/(?:ADD CONSTRAINT|INDEX) "([^"]+)"/g)].map((m) => m[1]));
    for (const [, n] of sql.matchAll(/DROP (?:INDEX IF EXISTS "[^"]+"\.|CONSTRAINT IF EXISTS |TRIGGER IF EXISTS )"([^"]+)"/g)) {
      if (!built.has(n)) out[n] ??= name;
    }
    for (const n of built) delete out[n];
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
// The declarations the plan read (`used`) are recorded as its first line, `-- declared: <json>`, so a
// migration made again (rebase) reads them back (declaredIn) after the app has removed them.
export const migration = (ops, used = {}) => ({
  operations: [{ sql: { up: [
    ...(Object.keys(used).length ? [`-- declared: ${JSON.stringify(sorted(used))}`] : []),
    "-- Deferred constraints checked as each statement ends, so the tables can be altered after rows move.\nSET CONSTRAINTS ALL IMMEDIATE;",
    ...ops.map((o) => `-- ${`${o.at}: ${o.why}`.replace(/\r\n|\r|\n/g, "\n-- ")}\n${o.sql}`),
  ].join("\n\n") } }],
});

// The declarations a migration recorded (migration), or none.
export function declaredIn(json) {
  const line = (json.operations ?? []).map((o) => o.sql?.up ?? "").join("\n").match(/^-- declared: (.*)$/m);
  return line ? JSON.parse(line[1]) : {};
}

// A migration's name, which pgroll's ledger takes (mecha's pgroll.#Name): the day it is made, its
// four-digit count among the migrations made that day, and what it does, 20261109_0001_retire_ref.
// Its file is migrations/<name>.json; the ledger (migrations_ledger.cue) embeds every .json there but
// the snapshot, and the lint refuses one whose name is not this (strays).
const DATED = /^(\d{8})_(\d{4})_/;
const SLUG = /^[a-z][a-z0-9_]*$/;
export const isName = (n) => DATED.test(n) && SLUG.test(n.replace(DATED, ""));
export const slugOf = (n) => isName(n) ? n.replace(DATED, "") : null;
export const SNAPSHOT_FILE = "snapshot.json";
export const strays = (files) => files.filter((f) => f.endsWith(".json") && f !== SNAPSHOT_FILE && !isName(f.slice(0, -5)));

// The next migration's name, made on `date` (YYYYMMDD, the machine's calendar day), counted among
// `made` (the files and the one folded last), saying `slug`. pgroll's runner refuses a migration
// that sorts before one it has run, so the name sorts after every migration the app has (`others`:
// its own, and any written by hand): a later day already used (a machine in a zone ahead) is taken,
// with the next count. A migration written by hand that sorts after every dated name is refused: no
// name can follow it.
export function nextName(made, slug, date, others = []) {
  if (!/^\d{8}$/.test(date)) throw new Error(`"${date}": a migration's day is YYYYMMDD`);
  if (!SLUG.test(slug)) throw new Error(`"${slug}": a migration's name says what it does, in lowercase letters, digits and _, starting with a letter`);
  const all = [...made, ...others];
  const day = all.map((e) => e.match(DATED)?.[1]).filter(Boolean).reduce((a, b) => (b > a ? b : a), date);
  const count = all.map((e) => e.match(DATED)).filter((m) => m && m[1] === day).map((m) => Number(m[2])).reduce((a, b) => Math.max(a, b), 0);
  const name = `${day}_${String(count + 1).padStart(4, "0")}_${slug}`;
  const after = all.filter((o) => o > name).sort();
  if (after.length) throw new Error(`${name} sorts before the app's migration ${after.at(-1)}, which pgroll's runner has to run first: a migration written by hand is named <YYYYMMDD>_<NNNN>_<name> too`);
  return name;
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

// The model a snapshot holds. One of an older format is upgraded first (upgrade); one of a newer
// format is refused.
export function fromSnapshot(text) {
  const s = JSON.parse(text);
  if (s.format === FORMAT) return s.model;
  if (Number.isInteger(s.format) && s.format >= 1 && s.format < FORMAT) throw new Error(`migrations/snapshot.json is format ${s.format}, where this plugin reads format ${FORMAT}: run \`deno run --no-config -A migrations/migrate.ts upgrade\``);
  throw foreign("migrations/snapshot.json", `format ${s.format}`);
}

// What each format records that the one before did not, put into a model of that one from `derived`,
// the model this plugin reads, at the commit the snapshot was taken at. Format 2 records the default
// the replay writes where pronto's facts state none (a machine's initial state).
const LIFTS = {
  2: (model, derived) => mapFields(model, (f, d) => f.default === undefined && d?.machine && d.default !== undefined ? { ...f, default: d.default } : f, derived),
};

// A snapshot of an older format, carried to this one: `derived` is the model this plugin reads at
// the commit the snapshot was taken at. The old snapshot, given what each later format records from
// `derived`, must then be `derived` exactly, or the commit is not the one it was taken at (or the
// later formats changed more than they record) and nothing is written.
export function upgrade(text, derived) {
  const s = JSON.parse(text);
  if (s.format === FORMAT) throw new Error(`migrations/snapshot.json is format ${FORMAT} already`);
  if (!(Number.isInteger(s.format) && s.format >= 1 && s.format < FORMAT)) throw foreign("migrations/snapshot.json", `format ${s.format}`);
  let m = s.model;
  for (let f = s.format + 1; f <= FORMAT; f++) m = LIFTS[f](m, derived);
  const at = difference(sorted(m), sorted(derived), "");
  if (at) throw new Error(`migrations/snapshot.json, carried to format ${FORMAT}, is not the model at that commit (they differ at ${at}): name the commit the snapshot was taken at (upgrade --from <ref>)`);
  return { model: sorted(derived), from: s.format };
}

// Each field of a model, live and retired, through `f(field, the same field of derived)`.
function mapFields(model, f, derived) {
  return Object.fromEntries(Object.entries(model).map(([name, e]) => {
    const d = derived[name];
    const each = (group) => Object.fromEntries(Object.entries(e[group] ?? {}).map(([n, x]) => [n, f(x, d?.[group]?.[n])]));
    return [name, { ...e, fields: each("fields"), ...(e.retired ? { retired: each("retired") } : {}) }];
  }));
}

// The first path where two values differ, or null.
function difference(a, b, path) {
  if (JSON.stringify(a) === JSON.stringify(b)) return null;
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort(byKey)) {
      const d = difference(a[k], b[k], path ? `${path}.${k}` : k);
      if (d) return d;
    }
  }
  return path || "the model";
}

function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort(byKey).map((k) => [k, sorted(v[k])]));
  return v;
}
// Field numbers sort as numbers, everything else as text.
const byKey = (a, b) => /^\d+$/.test(a) && /^\d+$/.test(b) ? Number(a) - Number(b) : a < b ? -1 : a > b ? 1 : 0;
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
