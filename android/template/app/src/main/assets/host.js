// What the host owes a screen before SES loads, and the row store it keeps.
// Evaluated after __shell (the program's shell.json) and __persisted (the
// device tables the store bridge unsealed), before ses.umd.min.js.

// A console, and Iterator.prototype's faux accessors as data properties:
// QuickJS's getters throw on an undefined receiver and SES 1.15 calls them bare.
globalThis.console = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) => [k, (...a) => __log(k, ...a.map(String))]));
for (const [key, value] of [["constructor", Iterator], [Symbol.toStringTag, "Iterator"]]) {
  Object.defineProperty(Iterator.prototype, key, { value, writable: true, enumerable: false, configurable: true });
}

const actionHandlers = [];
globalThis.onAction = (h) => { actionHandlers.push(h); };
// `now` and `key` are the host's: the clock a form stamps and the key a create
// mints, the two things a screen may not invent.
globalThis.__dispatchAction = (url, now, key) => { for (const h of actionHandlers) h(url, { now, key }); };
globalThis.emitUiAst = (ast) => __emitUiAst(typeof ast === "string" ? ast : JSON.stringify(ast));

// Every table the program declares: a `device` one from the store, any other
// from its seed. The screen reads `rows` and writes only through `commit`.
const schema = __shell.schema ?? {};
const durable = (table) => (__shell.local ?? {})[table] === "device";
globalThis.rows = Object.fromEntries(Object.keys(schema).map((t) => [
  t,
  (durable(t) ? (__persisted[t] ?? []) : ((__shell.seed ?? {})[t] ?? [])).map((r) => ({ ...r })),
]));

// The field shell.json's schema refuses, or undefined: the store's refusal, so
// the phone says no where the browser's store does.
const refusal = (table, row) => {
  for (const f of schema[table]?.fields ?? []) {
    const v = row[f.name];
    if (v === undefined || v === null) {
      if (f.required) return f.name;
      continue;
    }
    if (f.enum && !f.enum.includes(v)) return f.name;
    const b = f.bounds ?? {};
    if (typeof v === "string") {
      const size = [...v].length;
      if (b.sizeMin !== undefined && size < b.sizeMin) return f.name;
      if (b.sizeMax !== undefined && size > b.sizeMax) return f.name;
      if (b.regex !== undefined && !new RegExp(b.regex).test(v)) return f.name;
    }
  }
  return undefined;
};

// Applies a reduce's updates as the browser's store does: each names its op,
// `entity` defaults to `table`, and one refusal aborts the rest of the batch.
// Returns the refused event a reduce would hear, or undefined.
globalThis.commit = (table, updates) => {
  for (const u of updates) {
    const entity = u.entity ?? table;
    const list = rows[entity];
    if (list === undefined) throw new Error(`no table ${entity}`);
    const at = list.findIndex((r) => r.id === u.id);
    if (u.op === "delete") {
      if (at >= 0) list.splice(at, 1);
      if (durable(entity)) __storeDrop(entity, u.id);
      continue;
    }
    if (u.op !== "put" && u.op !== "patch") throw new Error(`update without an op: ${JSON.stringify(u)}`);
    if (u.row === undefined) throw new Error(`${u.op} without a row: ${JSON.stringify(u)}`);
    const row = { ...(u.op === "patch" && at >= 0 ? list[at] : {}), ...u.row, id: u.id };
    const field = refusal(entity, row);
    if (field !== undefined) return { type: "refused", entity, kind: "refused", id: u.id, field };
    if (at >= 0) list[at] = row; else list.push(row);
    if (durable(entity)) __storePut(entity, u.id, JSON.stringify(row));
  }
  return undefined;
};

// One handler, caged as the web terminal cages it, its compartment kept.
const caged = {};
globalThis.reduce = (name, state, event) => {
  caged[name] ??= new Compartment().evaluate(__handlers[name]);
  return caged[name](state, event);
};

// A fold run to rest, as data-on-mutation runs it: each pass reads `reads`,
// commits, and wakes it again until it states nothing.
globalThis.settle = (name, table, reads) => {
  for (let pass = 0; pass < 32; pass++) {
    const state = { items: rows[table], rows: Object.fromEntries(reads.map((t) => [t, rows[t]])) };
    const { updates } = reduce(name, state, { type: "mutation" });
    if (updates.length === 0) return;
    const refused = commit(table, updates);
    if (refused !== undefined) throw new Error(`store refused ${refused.entity}.${refused.field}`);
  }
  throw new Error(`handler chain did not settle: ${name}`);
};

// The headless commit a host service calls: the refusal, or null.
globalThis.__commit = (table, updates) => JSON.stringify(commit(table, JSON.parse(updates)) ?? null);

// The headless entry a host service calls: run `name` against the current rows
// with some tables stated, and hand back its reply. Nothing is committed.
globalThis.__ask = (name, reads, stated, event) => JSON.stringify(reduce(name, {
  rows: Object.fromEntries(reads.map((t) => [t, JSON.parse(stated)[t] ?? rows[t]])),
}, JSON.parse(event)));
undefined;
