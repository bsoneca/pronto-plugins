// A handler file is one arrow expression, not a module: evaluating its text
// yields the function, the way the terminal's compartment does, and the
// Android host's.
type Update = { op: string; id: string; row?: Record<string, unknown> };
type Handler = (state: { items?: unknown[] }, event: Record<string, unknown>) => { updates: Update[] };

const load = async (name: string): Promise<Handler> =>
  (0, eval)(await Deno.readTextFile(new URL(`../shell/handlers/${name}.js`, import.meta.url)));

const assertEquals = (actual: unknown, expected: unknown) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
};

Deno.test("count tells its buttons apart by element id", async () => {
  const count = await load("count");
  const state = { items: [{ id: "counter", n: 4 }] };
  assertEquals(count(state, { type: "click", id: "counter", from: "inc" }).updates, [{ op: "patch", id: "counter", row: { n: 5 } }]);
  assertEquals(count(state, { type: "click", id: "counter", from: "dec" }).updates, [{ op: "patch", id: "counter", row: { n: 3 } }]);
});

// A write past the CEL bound is refused where no region hears it, so the button
// would look dead; the handler states nothing instead.
Deno.test("count stops at its bound rather than writing a refused row", async () => {
  const count = await load("count");
  assertEquals(count({ items: [{ id: "counter", n: 99 }] }, { type: "click", id: "counter", from: "inc" }).updates, []);
  assertEquals(count({ items: [{ id: "counter", n: -99 }] }, { type: "click", id: "counter", from: "dec" }).updates, []);
});
