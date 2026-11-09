// A hatch bound by the hatch contract (pronto-csharp docs/pronto-unity-hatch-contract.md, v2), run on the
// phone: the app's binding (binding.json) and its pure module (init, view, gesture, tick, ad), the same
// files the Unity host runs. The web's hatch is a host-DOM module (three.js, a canvas) the phone cannot
// draw; build@android registers, at that module's address, one made from this driver and the app's
// binding, so omnishell mounts, pauses and stops it as it would the web's, unchanged.
//
// The driver keeps the hatch's state, reads the screen for it before every call, and writes the node tree
// view() returns into the screen as elements (div#hatch-<name>, as the Unity host mounts it), which the
// display draws like any other. A tap on one of them is a gesture; an outcome is carried out only within
// the binding: one form of `submits` filled and submitted, one element of `clicks` clicked, a note. Anything
// else is a fault (`PRONTO FAULT hatch <name>: ...`) and the hatch keeps its previous state. A view that
// faults leaves the last good one drawn.
//
// A v3 scene (scene, model, anim, camera, audio; the contract's "Contract v3") is checked here as the Unity
// host's Scene.Check checks it, kept in the DOM with its attributes and classes, and drawn natively: compile.js
// turns the scene element into one DivKit custom div ("pronto-scene") that Kotlin's SceneView draws in OpenGL.
// What the phone does not do yet: a ticked hatch gets no held input (no touch layout; PRONTO-101). There is no
// ad network: an outcome's ad ends `none` at once, as the contract's
// "no ad to show".

const NODE = new Set(["tag", "key", "class", "attrs", "text", "style", "children"]);
const STYLE = new Set(["left", "top", "width", "height", "opacity"]);
const OUTCOME = new Set(["state", "submit", "click", "say", "ad"]);
const KEY = "data-hatch-key";
const SHAPES = ["cube", "sphere", "capsule", "cylinder", "plane", "quad"];
const HEX = /^#[0-9a-fA-F]{6}$/;
// A 3D kind's attributes (besides id and data-*); WORDS are the ones that are not numbers.
const ALLOWED = {
  model: ["shape", "prefab", "color", "x", "y", "z", "rx", "ry", "rz", "sx", "sy", "sz"],
  anim: ["target", "clip", "duration", "dx", "dy", "dz", "spin", "loop"],
  camera: ["x", "y", "z", "look-x", "look-y", "look-z", "fov"],
  audio: ["clip", "volume", "loop"],
};
const WORDS = new Set(["shape", "prefab", "color", "target", "clip", "loop"]);

const clone = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

/** The binding checked as the Unity host's HatchBinding.Parse checks it. */
export function bindingOf(json) {
  const d = typeof json === "string" ? JSON.parse(json) : json;
  if (!d || typeof d !== "object" || Array.isArray(d)) throw new Error("a binding is a JSON object");
  for (const k of Object.keys(d)) {
    if (!["generated", "module", "reads", "submits", "clicks", "tick", "input"].includes(k)) throw new Error(`binding: unknown field ${k}`);
  }
  if (typeof d.module !== "string" || !d.module) throw new Error("binding: module is the path of the app's ES module");
  const strings = (v, what) => {
    if (v == null) return [];
    if (!Array.isArray(v) || !v.every((x) => typeof x === "string")) throw new Error(`binding: ${what} is a list of strings`);
    return v;
  };
  const reads = [];
  for (const [k, r] of Object.entries(d.reads ?? {})) {
    if (!r || typeof r.select !== "string") throw new Error(`binding: reads.${k} needs a select`);
    reads.push({ key: k, select: r.select, attrs: strings(r.attrs, `reads.${k}.attrs`) });
  }
  let hz = 0;
  if (d.tick != null) {
    const h = d.tick?.hz;
    if (!Number.isInteger(h) || h < 1 || h > 240) throw new Error("binding: tick is {hz: 1..240}");
    hz = h;
  }
  return { module: d.module, reads, submits: strings(d.submits, "submits"), clicks: strings(d.clicks, "clicks"), hz, input: strings(d.input, "input") };
}

/** Checks a scene's children as the Unity host refuses them; throws the fault's words. */
function checkScene(node) {
  const bg = node.attrs?.background;
  if (bg != null && !HEX.test(String(bg))) throw new Error(`${node.key}: background is #rrggbb`);
  for (const c of node.children ?? []) {
    if (!ALLOWED[c.tag]) throw new Error(`${c.key}: a scene holds model, anim, camera and audio, not ${c.tag}`);
    if (c.children?.length || c.text != null) throw new Error(`${c.key}: a ${c.tag} has no children`);
    const a = c.attrs ?? {};
    for (const k of Object.keys(a)) {
      if (!ALLOWED[c.tag].includes(k) && k !== "id" && !k.startsWith("data-")) throw new Error(`${c.key}: a ${c.tag} has no attribute ${k} (it has ${ALLOWED[c.tag].join(", ")})`);
    }
    for (const [k, v] of Object.entries(a)) {
      if (!ALLOWED[c.tag].includes(k) || WORDS.has(k)) continue;
      if (typeof v === "boolean" || (typeof v === "string" && v.trim() === "") || !Number.isFinite(Number(v))) throw new Error(`${c.key}: ${k} is a number, not "${v}"`);
    }
    const t = (n) => (a[n] == null ? "" : String(a[n]));
    if (c.tag === "model") {
      if ((t("shape") === "") === (t("prefab") === "")) throw new Error(`${c.key}: a model has a shape or a prefab, one of them`);
      if (t("shape") !== "" && !SHAPES.includes(t("shape"))) throw new Error(`${c.key}: shape ${t("shape")} is not one of ${SHAPES.join(", ")}`);
      if (t("color") !== "" && !HEX.test(t("color"))) throw new Error(`${c.key}: color is #rrggbb`);
    } else if (c.tag === "anim") {
      if (t("target") === "" || t("clip") === "") throw new Error(`${c.key}: an anim needs a target (a model's key) and a clip (a name)`);
      if (a.duration != null && Number(a.duration) <= 0) throw new Error(`${c.key}: duration is above 0`);
    } else if (c.tag === "audio") {
      if (t("clip") === "") throw new Error(`${c.key}: an audio needs a clip (a name)`);
      if (a.volume != null && (Number(a.volume) < 0 || Number(a.volume) > 1)) throw new Error(`${c.key}: volume is 0..1`);
    }
  }
}

/** Checks a view node (the contract's strict shape); throws the fault's words. */
export function checkView(node, keys = new Set(), path = "view") {
  if (!node || typeof node !== "object" || Array.isArray(node)) throw new Error(`${path} is not a node`);
  for (const k of Object.keys(node)) if (!NODE.has(k)) throw new Error(`${path}: unknown field ${k}`);
  if (typeof node.tag !== "string" || !node.tag) throw new Error(`${path}: a node needs a tag`);
  if (typeof node.key !== "string" || !node.key) throw new Error(`${path}: a node needs a key`);
  if (keys.has(node.key)) throw new Error(`${path}: key ${node.key} is not unique`);
  keys.add(node.key);
  if (node.class != null && !(Array.isArray(node.class) && node.class.every((c) => typeof c === "string"))) throw new Error(`${node.key}: class is a list of strings`);
  for (const [a, v] of Object.entries(node.attrs ?? {})) {
    if (!["string", "number", "boolean"].includes(typeof v)) throw new Error(`${node.key}: attrs.${a} is not a string, number or boolean`);
  }
  if (node.text != null && typeof node.text !== "string") throw new Error(`${node.key}: text is a string`);
  for (const s of Object.keys(node.style ?? {})) if (!STYLE.has(s)) throw new Error(`${node.key}: style.${s} is not one of left, top, width, height, opacity`);
  if (node.children != null && !Array.isArray(node.children)) throw new Error(`${node.key}: children is a list`);
  for (const c of node.children ?? []) checkView(c, keys, node.key);
  if (node.tag === "scene") checkScene(node);
  return node;
}

/** Checks an outcome against the binding; throws the fault's words. */
export function checkOutcome(o, binding) {
  if (o == null) return {};
  if (typeof o !== "object" || Array.isArray(o)) throw new Error("an outcome is an object");
  for (const k of Object.keys(o)) if (!OUTCOME.has(k)) throw new Error(`outcome: unknown field ${k}`);
  if (o.submit != null) {
    if (!binding.submits.includes(o.submit.form)) throw new Error(`outcome: submit.form ${o.submit.form} is not one of the binding's submits`);
    for (const [n, v] of Object.entries(o.submit.values ?? {})) if (typeof v !== "string") throw new Error(`outcome: submit.values.${n} is not a string`);
  }
  if (o.click != null && !binding.clicks.includes(o.click)) throw new Error(`outcome: click ${o.click} is not one of the binding's clicks`);
  if (o.say != null && typeof o.say !== "string") throw new Error("outcome: say is a string");
  return o;
}

/** The attributes a node's element carries: its own, its key, its class, its style. */
function attrsOf(node) {
  const out = { [KEY]: node.key };
  for (const [a, v] of Object.entries(node.attrs ?? {})) if (v !== false) out[a] = v === true ? "" : String(v);
  if (node.class?.length) out.class = node.class.join(" ");
  const s = node.style ?? {};
  const css = [];
  if (s.left != null || s.top != null) css.push("position: absolute");
  for (const p of ["left", "top", "width", "height", "opacity"]) if (s[p] != null) css.push(`${p}: ${s[p]}`);
  if (css.length) out.style = css.join("; ");
  return out;
}

/** The view as new elements of `doc`. */
export function elementOf(doc, node) {
  const el = doc.createElement(node.tag);
  for (const [a, v] of Object.entries(attrsOf(node))) el.setAttribute(a, v);
  if (node.text != null) el.appendChild(doc.createTextNode(node.text));
  for (const c of node.children ?? []) el.appendChild(elementOf(doc, c));
  return el;
}

/**
 * The view written over `el`, the element an earlier view drew for the same key: attributes, text and
 * children changed in place, a child kept while its key and tag stay. An element the display drew keeps
 * its identity, so a tap the driver aimed at it still lands, as on Unity, whose elements are its keys.
 */
export function patch(doc, el, node) {
  const want = attrsOf(node);
  for (const a of [...el.attributes].map((x) => x.name)) if (!(a in want)) el.removeAttribute(a);
  for (const [a, v] of Object.entries(want)) if (el.getAttribute(a) !== v) el.setAttribute(a, v);
  const old = new Map();
  for (const c of [...el.children]) old.set(c.getAttribute(KEY), c);
  const kids = [];
  if (node.text != null) {
    const t = el.firstChild?.nodeType === 3 ? el.firstChild : doc.createTextNode("");
    if (t.data !== node.text) t.data = node.text;
    kids.push(t);
  }
  for (const c of node.children ?? []) {
    const had = old.get(c.key);
    kids.push(had && had.localName === c.tag ? (old.delete(c.key), patch(doc, had, c)) : elementOf(doc, c));
  }
  for (const n of [...el.childNodes]) if (!kids.includes(n)) n.remove();
  kids.forEach((k, i) => { if (el.childNodes[i] !== k) el.insertBefore(k, el.childNodes[i] ?? null); });
  return el;
}

/**
 * The host-DOM mount for hatch `name`: omnishell calls it with the screen it covers, and calls the cleanup it
 * returns (or aborts `signal`) when the screen pauses, stops or morphs.
 * @param {string} name
 * @param {object | string} bindingJson
 * @param {Record<string, any>} module
 * @param {{log?: {error: (m: string) => unknown, log: (m: string) => unknown}, css?: string | null}} [options]
 *   css: the hatch's own stylesheet (android.json hatches.<name>.css), linked while it is mounted.
 */
export function bound(name, bindingJson, module, { log = console, css = null } = {}) {
  const binding = bindingOf(bindingJson);
  for (const f of ["init", "view"]) if (typeof module[f] !== "function") throw new Error(`hatch ${name}: the module exports no ${f}`);
  if (binding.hz && typeof module.tick !== "function") throw new Error(`hatch ${name}: a ticked binding needs tick`);
  const fault = (e) => log.error(`PRONTO FAULT hatch ${name}: ${e?.message ?? e}`);

  return function mount(screen, { signal } = {}) {
    const doc = screen.ownerDocument;
    const ctx = () => {
      const seed = Number.parseInt(new URL(globalThis.location?.href ?? "https://terminal.invalid/").searchParams.get("seed") ?? "0", 10);
      return { seed: Number.isInteger(seed) ? seed : 0, locale: doc.documentElement.getAttribute("lang") ?? "en", now: Date.now(), flags: globalThis.__hatchFlags ?? {} };
    };
    const mountEl = doc.createElement("div");
    mountEl.setAttribute("id", `hatch-${name}`);
    mountEl.setAttribute("class", `hatch hatch--${name.replace(/[^A-Za-z0-9_-]/g, "-")}`);
    mountEl.setAttribute(KEY, `hatch:${name}`);
    screen.appendChild(mountEl);
    const sheet = css ? doc.createElement("link") : null;
    if (sheet) {
      sheet.setAttribute("rel", "stylesheet");
      sheet.setAttribute("href", css);
      sheet.setAttribute("data-hatch-css", name);
      (doc.head ?? doc.documentElement).appendChild(sheet);
    }

    const outside = (el) => !mountEl.contains(el);
    const reads = () => {
      const r = {};
      for (const { key, select, attrs } of binding.reads) {
        r[key] = [...screen.querySelectorAll(select)].filter(outside).map((el) => ({
          key: el.getAttribute("id") ?? "",
          attrs: Object.fromEntries(attrs.filter((a) => el.hasAttribute(a)).map((a) => [a, el.getAttribute(a)])),
          text: el.textContent ?? "",
        }));
      }
      return r;
    };

    let state;
    try { state = clone(module.init(ctx())); } catch (e) { fault(e); state = null; }
    let drawing = false;
    const draw = () => {
      let tree;
      try { tree = checkView(module.view(clone(state), reads(), ctx())); } catch (e) { fault(e); return; }
      drawing = true;
      try {
        const was = mountEl.firstElementChild;
        if (was && was.getAttribute(KEY) === tree.key && was.localName === tree.tag) patch(doc, was, tree);
        else mountEl.replaceChildren(elementOf(doc, tree));
      } finally { drawing = false; }
    };

    const submit = ({ form, values }) => {
      const f = screen.querySelector(form);
      if (!f) throw new Error(`outcome: no ${form} on the screen`);
      for (const [n, v] of Object.entries(values ?? {})) {
        const field = f.elements?.namedItem?.(n) ?? f.querySelector(`[name="${n}"]`);
        if (field) field.value = v;
      }
      f.requestSubmit();
    };
    const click = (selector) => {
      const el = screen.querySelector(selector);
      if (!el) throw new Error(`outcome: no ${selector} on the screen`);
      el.dispatchEvent(new (doc.defaultView?.CustomEvent ?? CustomEvent)("click", { bubbles: true, cancelable: true }));
    };
    // An outcome, carried out: the state kept, then the one submit or click, then the view drawn.
    const apply = (outcome) => {
      let o;
      try { o = checkOutcome(outcome, binding); } catch (e) { fault(e); return; }
      const before = state;
      if ("state" in o) state = clone(o.state);
      try {
        if (o.submit) submit(o.submit);
        if (o.click) click(o.click);
      } catch (e) { state = before; fault(e); return; }
      if (o.say) log.log(`PRONTO HATCH ${name}: ${o.say}`);
      if (o.ad) {
        if (typeof module.ad !== "function") { fault(new Error("outcome: an ad and no ad export")); return draw(); }
        draw();
        return call(() => module.ad(clone(state), reads(), { result: "none" }, ctx()));
      }
      draw();
    };
    const call = (fn) => { let o; try { o = fn(); } catch (e) { fault(e); return; } apply(o); };

    const onGesture = (event) => {
      const el = event.target?.closest?.(`[${KEY}]`);
      if (!el || el === mountEl || !mountEl.contains(el) || typeof module.gesture !== "function") return;
      const attrs = Object.fromEntries([...el.attributes].filter((a) => a.name !== KEY).map((a) => [a.name, a.value]));
      call(() => module.gesture(clone(state), reads(), { type: event.type, key: el.getAttribute(KEY), attrs }, ctx()));
    };
    mountEl.addEventListener("click", onGesture);
    mountEl.addEventListener("contextmenu", onGesture);

    // The screen's answer (a fold wrote a row, a region re-rendered) is what the next view reads.
    let pending = null;
    const Observer = doc.defaultView?.MutationObserver ?? globalThis.MutationObserver;
    const observer = new Observer((records) => {
      if (drawing || pending || records.every((r) => r.target === mountEl || mountEl.contains(r.target))) return;
      pending = setTimeout(() => { pending = null; draw(); }, 0);
    });
    observer.observe(screen, { subtree: true, childList: true, attributes: true, characterData: true });

    const ticker = binding.hz ? setInterval(() => call(() => module.tick(clone(state), reads(), [], ctx())), 1000 / binding.hz) : null;
    draw();

    let stopped = false;
    const cleanup = () => {
      if (stopped) return;
      stopped = true;
      observer.disconnect();
      if (pending) clearTimeout(pending);
      if (ticker) clearInterval(ticker);
      mountEl.removeEventListener("click", onGesture);
      mountEl.removeEventListener("contextmenu", onGesture);
      mountEl.remove();
      sheet?.remove();
    };
    signal?.addEventListener?.("abort", cleanup);
    return cleanup;
  };
}
