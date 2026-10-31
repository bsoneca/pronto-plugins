// host.js under the SES the phone loads, in one realm per test the way the
// engine evaluates it: the row store's refusals, persistence and folds.
const assets = new URL("../template/app/src/main/assets/", import.meta.url);
const read = (name: string) => Deno.readTextFileSync(new URL(name, assets));

const shell = {
  local: { note: "device", pick: "tab" },
  seed: { pick: [{ id: "pick", n: 0 }] },
  schema: {
    note: { fields: [
      { name: "id", pk: true, type: "uuid", required: true },
      { name: "text", type: "string", required: true, bounds: { sizeMin: 1, sizeMax: 3, regex: "^[a-z]+$" } },
      { name: "kind", type: "string", required: true, enum: ["a", "b"] },
    ] },
    pick: { fields: [{ name: "id", pk: true, type: "string", required: true }, { name: "n", type: "int32", required: true }] },
  },
};
// A fold that counts notes into the pick row and settles once it agrees.
const handlers = {
  count: "(state, event) => { const n = state.rows.note.length; const p = state.rows.pick[0]; return p.n === n ? { updates: [] } : { updates: [{ op: 'patch', entity: 'pick', id: 'pick', row: { n } }] }; }",
};

const disk = new Map<string, string>();
const g = globalThis as Record<string, unknown>;
g.__log = () => {};
g.__emitUiAst = () => {};
g.__storePut = (t: string, id: string, json: string) => disk.set(`${t}/${id}`, json);
g.__storeDrop = (t: string, id: string) => disk.delete(`${t}/${id}`);
g.__shell = shell;
g.__persisted = { note: [{ id: "n0", text: "old", kind: "a" }] };
(0, eval)(read("host.js"));
(0, eval)(read("ses.umd.min.js"));
g.__handlers = handlers;
(0, eval)('lockdown({ errorTaming: "unsafe" })');

type Store = {
  __commit: (t: string, u: string) => string;
  rows: Record<string, Record<string, unknown>[]>;
  commit: (t: string, u: unknown[]) => unknown;
  settle: (n: string, t: string, r: string[]) => void;
  __ask: (n: string, r: string[], s: string, e: string) => string;
};
const h = g as unknown as Store;
const eq = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
};

Deno.test("device rows come from the store, tab rows from the seed", () => {
  eq(h.rows.note.map((r) => r.id), ["n0"]);
  eq(h.rows.pick, [{ id: "pick", n: 0 }]);
});

Deno.test("a put the schema allows is kept and persisted; a delete unpersists", () => {
  eq(h.commit("note", [{ op: "put", id: "n1", row: { text: "abc", kind: "b" } }]), undefined);
  eq(JSON.parse(disk.get("note/n1")!), { text: "abc", kind: "b", id: "n1" });
  eq(h.commit("note", [{ op: "delete", id: "n1" }]), undefined);
  eq(disk.has("note/n1"), false);
  eq(h.rows.note.length, 1);
});

// The browser's store refuses these; the phone must refuse the same rows.
Deno.test("bounds, regex, enum and required refuse, and abort the batch", () => {
  for (const [row, field] of [
    [{ text: "", kind: "a" }, "text"], [{ text: "abcd", kind: "a" }, "text"],
    [{ text: "AB", kind: "a" }, "text"], [{ text: "ab", kind: "c" }, "kind"], [{ text: "ab" }, "kind"],
  ] as const) {
    eq((h.commit("note", [{ op: "put", id: "x", row }, { op: "put", id: "y", row: { text: "ok", kind: "a" } }]) as { field: string }).field, field);
  }
  eq(h.rows.note.map((r) => r.id), ["n0"]);
  eq(disk.has("note/y"), false);
});

Deno.test("a tab row is never persisted", () => {
  eq(h.commit("pick", [{ op: "patch", id: "pick", row: { n: 7 } }]), undefined);
  eq(h.rows.pick, [{ id: "pick", n: 7 }]);
  eq([...disk.keys()].some((k) => k.startsWith("pick/")), false);
});

Deno.test("settle runs a caged fold until it states nothing", () => {
  h.settle("count", "pick", ["note", "pick"]);
  eq(h.rows.pick[0].n, 1);
});

Deno.test("ask answers over stated tables and commits nothing", () => {
  const reply = JSON.parse(h.__ask("count", ["note", "pick"], JSON.stringify({ pick: [{ id: "pick", n: 5 }] }), JSON.stringify({ type: "mutation" })));
  eq(reply.updates, [{ op: "patch", entity: "pick", id: "pick", row: { n: 1 } }]);
  eq(h.rows.pick[0].n, 1);
});

Deno.test("a handler runs caged: no clock, no ambient globals", () => {
  const g2 = globalThis as unknown as { reduce: (n: string, s: unknown, e: unknown) => unknown; __handlers: Record<string, string> };
  g2.__handlers.peek = "(s, e) => ({ updates: [], t: typeof Deno, d: (() => { try { return Date.now(); } catch { return 'threw'; } })() })";
  eq(g2.reduce("peek", {}, {}), { updates: [], t: "undefined", d: "threw" });
});

// A service pins through the same commit a screen writes with, refusals included.
Deno.test("the headless commit persists, and answers a refusal as the screen hears it", () => {
  eq(h.__commit("note", JSON.stringify([{ op: "patch", id: "n0", row: { text: "new" } }])), "null");
  eq(JSON.parse(disk.get("note/n0")!).text, "new");
  eq(JSON.parse(h.__commit("note", JSON.stringify([{ op: "patch", id: "n0", row: { kind: "z" } }]))).field, "kind");
});
