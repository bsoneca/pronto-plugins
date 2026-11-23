// The host battery's runner (native/battery.cue holds the cases): every native host runs it on its own engine.
// A host gives it
//   engine   { define(name, fn): puts a function on the engine's global, eval(source): the text a script returns }
//            already past SES's lockdown(), nothing of the program loaded;
//   passkeys the terminal's passkeys.js (optionsToJson, credentialOf), the one module of the bridge's two forms;
//   cases    the battery, as `cue export ./native -e battery` gives it.
// The engine already has the host's own bridges (native/bridges.cue): the runner defines none, so a storage case reads the
// host's real store. Deno's host, which has none, defines `memoryKv` first. The runner answers a list of {id, ok, why, got?}
// and never throws for a failing case: the host asserts `ok`.

// Equal as JSON, whatever order an object's keys came in.
const canon = (x) => JSON.stringify(x, (_, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : 1))) : v));
const same = (a, b) => canon(a) === canon(b);

/** The storage bridges in memory, for an engine that has no store of its own (the headless one): the behaviour a host's sealed store must match. */
export function memoryKv() {
  const spaces = new Map();
  const space = (ns) => spaces.get(ns) ?? spaces.set(ns, new Map()).get(ns);
  return {
    __native_kv_get: (ns, k) => space(ns).get(k) ?? null,
    __native_kv_set: (ns, k, v) => { space(ns).set(k, v); return null; },
    __native_kv_del: (ns, k) => { space(ns).delete(k); return null; },
    __native_kv_clear: (ns) => { space(ns).clear(); return null; },
    __native_kv_keys: (ns) => JSON.stringify([...space(ns).keys()]),
  };
}

const bytes = (v) => Array.from(new Uint8Array(v));
const buffer = (list) => new Uint8Array(list).buffer;
// The options a page passes navigator.credentials, from the case's lists of bytes.
const optionsOf = (o) => {
  const p = { ...o, challenge: buffer(o.challenge) };
  if (o.user) p.user = { ...o.user, id: buffer(o.user.id) };
  for (const k of ["allowCredentials", "excludeCredentials"]) if (o[k]) p[k] = o[k].map((c) => ({ ...c, id: buffer(c.id) }));
  return p;
};
// The credential, its buffers as lists of bytes.
const plain = (c) => ({
  id: c.id,
  rawId: bytes(c.rawId),
  type: c.type,
  response: Object.fromEntries(Object.entries(c.response).filter(([, v]) => typeof v !== "function").map(([k, v]) => [k, v === null ? null : bytes(v)])),
});

const runOne = (c, { engine, passkeys }) => {
  if (c.kind === "script") return JSON.parse(engine.eval(c.script));
  if (c.kind === "handler") {
    // The caged path a program's handler takes: its source evaluated in a Compartment with no endowments, a fresh one per
    // run, folded over the events. Two runs over one event list must give one tree list.
    const fold = `((source, events) => { const handler = new Compartment({}).evaluate(source); let state = null; return events.map((e) => { const out = handler(state, e); state = out.state; return out.tree; }); })`;
    const call = `${fold}(${JSON.stringify(c.source)}, ${JSON.stringify(c.events)})`;
    const [a, b] = [JSON.parse(engine.eval(`JSON.stringify(${call})`)), JSON.parse(engine.eval(`JSON.stringify(${call})`))];
    return same(a, b) ? a : { first: a, second: b };
  }
  if (c.kind === "compartment") return JSON.parse(engine.eval(`new Compartment({}).evaluate(${JSON.stringify(c.script)})`));
  if (c.kind === "passkey") {
    return { options: JSON.parse(passkeys.optionsToJson(optionsOf(c.options))), credential: plain(passkeys.credentialOf(c.response)) };
  }
  throw new Error(`unknown battery kind ${c.kind}`);
};

/** Runs the cases on the engine; each answer {id, why, ok, got?}. */
export function run({ engine, passkeys, cases }) {
  return cases.map((c) => {
    try {
      const got = runOne(c, { engine, passkeys });
      const ok = same(got, c.kind === "passkey" ? { options: c.wantOptions, credential: c.wantCredential } : c.want);
      return ok ? { id: c.id, why: c.why, ok } : { id: c.id, why: c.why, ok, got };
    } catch (e) {
      return { id: c.id, why: c.why, ok: false, got: String(e?.message ?? e) };
    }
  });
}
