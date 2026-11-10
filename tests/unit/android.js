// What the android suite's cases call: a page built from HTML and CSS on linkedom, compiled to a
// DivKit card by the Android terminal's compiler (android/template/terminal/compile.js), and small
// measures of the card (tests/unit/android.cue).
import { parseHTML } from "npm:linkedom@0.18.4";
import { bound, checkView, elementOf as viewElement } from "../../android/template/terminal/bound.js";
import { compile, elementOf, idOf } from "../../android/template/terminal/compile.js";
import { length, parseColor } from "../../android/template/terminal/css.js";
import { atobOf, b64u, btoaOf, credentialOf, errorOf, optionsToJson, unb64u } from "../../android/template/terminal/passkeys.js";

const pageOf = (body, base) =>
  parseHTML(`<!doctype html><html lang="en"><head>${base ? `<base href="${base}">` : ""}</head><body>${body}</body></html>`);

const asSheets = (css) => (Array.isArray(css) ? css : css ? [css] : []);

/** A page compiled: the card, its root view, the body's view and its `items`, the variables by name and what is unsupported. */
export function render(body, css, opts) {
  const o = opts ?? {};
  const { document } = pageOf(body, o.base);
  const { card, unsupported } = compile(document, { sheets: asSheets(css), width: o.width ?? 411, height: o.height, scheme: o.scheme });
  const root = card.states[0].div;
  const top = root.items[0] ?? { items: [] };
  return { card, root, body: top, items: top.items ?? [], vars: Object.fromEntries(card.variables.map((v) => [v.name, v.value])), unsupported, whats: unsupported.map((u) => u.what) };
}

const holdsAll = (got, want) => {
  if (want && typeof want === "object") {
    if (!got || typeof got !== "object") return false;
    return Object.keys(want).every((k) => holdsAll(got[k], want[k]));
  }
  return got === want;
};

const walk = (div, out) => {
  out.push(div);
  for (const c of div.items ?? []) walk(c, out);
  return out;
};

/** Every view under a view (itself first), depth first. */
export const all = (div) => walk(div, []);
/** The views under a view that hold what `want` names. */
export const findAll = (div, want) => all(div).filter((d) => holdsAll(d, want));
/** The first view under a view that holds what `want` names. */
export const find = (div, want) => findAll(div, want)[0] ?? null;
/** The types of the views under a view, depth first. */
export const types = (div) => all(div).map((d) => d.type);
/** The text of every text view under a view. */
export const texts = (div) => all(div).filter((d) => d.type === "text").map((d) => d.text);

/** Each text view's text, and whether a tap and a long press are set and name its own id. */
export const taps = (div) => all(div).filter((d) => d.type === "text").map((d) => ({
  text: d.text,
  tap: d.actions ? d.actions[0].url === `pronto://tap/${d.id}` && d.actions[0].log_id === d.id : false,
  long: d.longtap_actions ? d.longtap_actions[0].url === `pronto://contextmenu/${d.id}` : false,
}));
/** Whether each field view's variable is v_ and its id, and each variable a field view's. */
export function variablesNamedByIds(page) {
  const fields = all(page.root).filter((d) => d.text_variable || d.value_variable);
  const names = fields.map((d) => d.text_variable ?? d.value_variable);
  return fields.length > 0 && fields.every((d) => (d.text_variable ?? d.value_variable) === `v_${d.id}`) && same(names, page.card.variables.map((v) => v.name));
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** What was reported unsupported, each as "what | selector" (or just "what"). */
export const reported = (page) => page.unsupported.map((u) => (u.selector ? `${u.what} | ${u.selector}` : u.what));
/** How many times a text is in a list. */
export const count = (list, what) => list.filter((x) => x === what).length;
/** Whether compiling the same page again gives the same card. */
export function repeats(body, css) {
  const { document } = pageOf(body);
  const run = () => JSON.stringify(compile(document, { sheets: asSheets(css), width: 411 }));
  return run() === run();
}

/** A CSS colour as DivKit writes it. */
export const colour = (text, dark) => parseColor(text, "#FF336699", !!dark);
/** A CSS length in dp, for a viewport 411 wide and a basis of 200 for percentages. */
export const dp = (text) => length(text, { fs: 16, rem: 16, width: 411, basis: 200 });

/** Compiles a page twice, with a new element before the others in between: the ids of the first. */
export function twice(body, css) {
  const { document } = pageOf(body);
  const run = () => compile(document, { sheets: asSheets(css), width: 411 }).card.states[0].div;
  const first = run();
  const ids = all(first).map((d) => d.id).filter((id) => /^e\d+$/.test(id));
  const extra = document.createElement("p");
  extra.textContent = "new";
  document.body.insertBefore(extra, document.body.firstChild);
  const second = run();
  const after = all(second).map((d) => d.id).filter((id) => /^e\d+$/.test(id));
  const input = document.querySelector("input");
  return {
    kept: ids.every((id) => after.indexOf(id) >= 0),
    count: ids.length,
    elementTag: elementOf(ids[ids.length - 1])?.tagName ?? null,
    inputId: input ? idOf(input) : null,
    sameInput: input ? elementOf(idOf(input)) === input : null,
    unknown: elementOf("e0"),
    newOne: after.filter((id) => ids.indexOf(id) < 0).length,
  };
}

/** The best of nine cold compiles (after two for the engine to warm; a busy machine spoils some) of `rules` rules over `elements` elements, in ms. */
export function perf(rules, elements) {
  const sheet = [":root { --a: #123456; --gap: 8px; color-scheme: light dark; }"];
  for (let i = 0; i < rules; i++) {
    const k = i % 5;
    if (k === 0) sheet.push(`.c${i} { padding: var(--gap); color: var(--a); border: 1px solid #ddd; }`);
    else if (k === 1) sheet.push(`.group .c${i} { margin-block: calc(var(--gap) * 2); background: light-dark(#fff, #111); }`);
    else if (k === 2) sheet.push(`.c${i}:not(.off) > span { font-weight: 600; color: oklch(0.6 0.1 ${i % 360}); }`);
    else if (k === 3) sheet.push(`@media (min-width: ${300 + (i % 400)}px) { .c${i} { display: flex; gap: 0.5rem; } }`);
    else sheet.push(`div.c${i}, section.c${i} { border-radius: 8px; font-size: clamp(14px, 4vw, 18px); }`);
  }
  let body = '<main class="group">';
  for (let i = 0; i < elements; i += 4) body += `<section class="c${i % rules} c${(i + 3) % rules}"><div class="c${(i + 1) % rules}"><span>text ${i}</span></div><p class="c${(i + 2) % rules}">more</p></section>`;
  body += "</main>";
  let best = Infinity;
  let drawn = 0;
  for (let run = -2; run < 9; run++) {
    const { document } = pageOf(body);
    const css = sheet.join("\n") + `\n/* run ${run} ${perfRuns++} */`;
    const t = performance.now();
    const { card } = compile(document, { sheets: [css], width: 411 });
    if (run >= 0) best = Math.min(best, performance.now() - t);
    drawn = all(card.states[0].div).length;
  }
  return { ms: Math.round(best * 10) / 10, under: best < 100, rules: sheet.length, elements: document_count(body), drawn };
}

let perfRuns = 0;
const document_count = (body) => (body.match(/<(section|div|span|p|main)\b/g) ?? []).length;

// --- the guestbook's home screen (apps/guestbook/shell), read where the pronto checkout is beside
// this one, else the copy below, which holds the same markup and rules.

const FALLBACK = {
  "screens/home.html": `<section class="screen" data-screen="home">
  <header class="intro">
    <h2 data-text="{msg.title}">Guestbook</h2>
    <p class="hint" data-text="{msg.hint}">Leave a name and a few words. Everyone who opens this page reads them.</p>
  </header>
  <form class="sign" data-entity="entry" data-action="create">
    <input type="hidden" name="created" data-value="{now}">
    <label><span data-text="{msg.name}">Your name</span>
      <input name="name" required maxlength="40" autocomplete="name"></label>
    <label><span data-text="{msg.note}">Your note</span>
      <textarea name="note" required maxlength="280" rows="3"></textarea></label>
    <button type="submit" class="primary" data-text="{msg.sign}">Sign the guestbook</button>
    <p class="store-error" hidden data-text="{msg.refused}">Couldn't sign: keep the name to 40 characters and the note to 280.</p>
  </form>
  <section class="wall">
    <h3 data-text="{msg.wall}">The wall</h3>
    <ul class="entries" data-live="entry" data-order="created.desc" data-empty="{msg.empty}">
      <template data-item>
        <li class="entry">
          <span class="who"><b data-text="{name}"></b> <span class="when" data-text="{created}" data-text-format="date"></span></span>
          <span class="note" data-text="{note}"></span>
        </li>
      </template>
    </ul>
  </section>
</section>
`,
  "screens/home.css": `.intro { padding-block: var(--sp-4) var(--sp-2); }
.intro .hint { color: var(--secondary); }

.sign, .wall {
  margin-block: var(--sp-4); padding: var(--sp-4);
  border: var(--border-size-1) solid var(--border); border-radius: var(--r-lg); background: var(--surface);
}
.sign { display: grid; gap: var(--sp-3); }
.sign label { display: grid; gap: var(--sp-1); }
.sign button { min-height: 2.75rem; justify-self: start; }
.wall h3 { margin-block: 0 var(--sp-2); }

.entries { list-style: none; margin: 0; padding: 0; display: grid; gap: var(--sp-2); }
.entry {
  display: grid; gap: var(--sp-1);
  padding: var(--sp-3); border: var(--border-size-1) solid var(--border); border-radius: var(--r-md); background: var(--surface-muted);
}
.entry .when { color: var(--secondary); }
.entry .note { overflow-wrap: anywhere; }
`,
  "shell.css": "/* The terminal ships no style. */\n",
  "design.css": `:where(html) { --border-size-1: 1px; --size-1: .25rem; --size-2: .5rem; --size-3: 1rem; --size-4: 1.25rem; }
:root {
  --neutral: light-dark(#FBF8F3, #15130F);
  --surface: light-dark(#FFFFFF, #1E1B16);
  --surface-muted: light-dark(#F4EFE6, #26221C);
  --border: light-dark(#E7DFD1, #3A342A);
  --primary: light-dark(#2A241C, #F5F0E6);
  --secondary: light-dark(#6B6152, #B5AB9A);
  --r-sm: 4px; --r-md: 8px; --sp-sm: 8px; --sp-md: 16px; --sp-lg: 24px;
  --shell-bg: var(--neutral); --shell-fg: var(--primary);
  color-scheme: light dark;
}
body { margin: 0; font: var(--shell-font, 1rem/1.5 system-ui, sans-serif); background: var(--shell-bg); color: var(--shell-fg); }
`,
};

const shellDirs = () => {
  const dirs = [];
  const env = Deno.env.get("GUESTBOOK_SHELL");
  if (env) dirs.push(env.endsWith("/") ? env : env + "/");
  dirs.push(new URL("../../../pronto/apps/guestbook/shell/", import.meta.url).pathname);
  return dirs;
};

/** The guestbook's home screen with two entries on its wall, compiled; `source` says where its files came from. */
export function guestbook(opts) {
  const o = opts ?? {};
  let files = null;
  let source = "copy";
  for (const dir of shellDirs()) {
    try {
      files = Object.fromEntries(Object.keys(FALLBACK).map((f) => [f, Deno.readTextFileSync(dir + f)]));
      source = "pronto";
      break;
    } catch { /* not beside this checkout */ }
  }
  files = files ?? FALLBACK;
  const entries = [["Ana", "Nov 5", "Hello from Recife"], ["Bruno", "Nov 4", "First!"]]
    .map(([n, d, t]) => `<li class="entry" data-id="${n}"><span class="who"><b>${n}</b> <span class="when">${d}</span></span><span class="note">${t}</span></li>`).join("");
  const home = files["screens/home.html"].replace("</template>", `</template>${entries}`);
  const out = render(`<main id="app">${home}</main>`, [files["shell.css"], files["design.css"], files["screens/home.css"]], { base: "/shell/", width: o.width, scheme: o.scheme });
  return { ...out, source };
}

// The passkeys bridge's two forms (android/template/terminal/passkeys.js), as a page would meet them.
const buf = (bytes) => new Uint8Array(bytes).buffer;
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

/** The JSON the host takes for options made of an ArrayBuffer, a view on a larger buffer and bytes lists. */
export function passkeyOptions(kind) {
  const base = new Uint8Array([9, 9, 1, 2, 3, 9]);
  if (kind === "create") {
    return JSON.parse(optionsToJson({
      rp: { name: "App", id: "localhost" }, user: { id: buf([7, 8]), name: "ana", displayName: "Ana" },
      challenge: base.subarray(2, 5), pubKeyCredParams: [{ type: "public-key", alg: -7 }],
      excludeCredentials: [{ type: "public-key", id: buf([255]), transports: ["internal"] }], timeout: 60000,
    }));
  }
  return JSON.parse(optionsToJson({ challenge: buf([251, 255, 254]), allowCredentials: [{ type: "public-key", id: buf([0, 0]) }], userVerification: "preferred" }));
}

/** base64url both ways: the text of some bytes, and the bytes of that text as hex. */
export function passkeyBase64(bytes) {
  const text = b64u(new Uint8Array(bytes));
  return { text, back: hex(unb64u(text)), padded: hex(unb64u(text + "=".repeat((4 - (text.length % 4)) % 4))) };
}

/** What a page reads of a credential built from the host's answer: ids and buffers as hex, the functions called. */
export function passkeyCredential(answer) {
  const c = credentialOf(answer);
  const r = c.response;
  return {
    id: c.id, type: c.type, rawId: hex(c.rawId), attachment: c.authenticatorAttachment, extensions: c.getClientExtensionResults(),
    buffers: Object.fromEntries(Object.entries(r).filter(([, v]) => v instanceof ArrayBuffer).map(([k, v]) => [k, hex(v)])),
    userHandle: r.userHandle === null ? null : undefined, transports: r.getTransports?.(),
  };
}

/** The error a refusal is: its name and message, and whether it is an Error. */
export function passkeyError(refusal) {
  const e = errorOf(refusal);
  return { name: e.name, message: e.message, error: e instanceof Error };
}

/** btoa and atob as a browser's: Latin1 text to padded base64 and back, a char beyond Latin1 refused. */
export function passkeyAtob(text) {
  const encoded = btoaOf(text);
  const refused = (() => { try { btoaOf("\u0100"); return null; } catch (e) { return e.name; } })();
  return { encoded, back: atobOf(encoded), unpadded: atobOf(encoded.replace(/=+$/, "")), refused };
}

// --- the hatch contract's v3 scene (bound.js checks it, compile.js types it)

const sceneView = (children, attrs = {}) => ({ tag: "scene", key: "scene", attrs: { id: "scene", ...attrs }, children });

/** The fault bound.js gives a scene whose children are `children` (and its own `attrs`), or "" when it holds. */
export function sceneFault(children, attrs) {
  try { checkView({ tag: "div", key: "root", children: [sceneView(children, attrs)] }); return ""; } catch (e) { return e.message; }
}

/** A scene view drawn as bound.js draws it, then compiled: the elements' facts, and the card's custom div(s). */
export function sceneDrawn(children, attrs, css) {
  const { document } = pageOf("");
  const root = viewElement(document, { tag: "div", key: "root", children: [sceneView(children, attrs)] });
  document.body.appendChild(root);
  const { card, unsupported } = compile(document, { sheets: asSheets(css), width: 411 });
  const el = document.querySelector("#scene");
  return {
    hidden: el.hasAttribute("hidden"),
    fight: el.getAttribute("data-fight"),
    models: document.querySelectorAll("#scene .model").length,
    tags: [...el.children].map((c) => c.localName),
    customs: all(card.states[0].div).filter((d) => d.type === "custom"),
    idMatches: all(card.states[0].div).some((d) => d.type === "custom" && elementOf(d.id) === el),
    unsupported: unsupported.map((u) => u.what),
  };
}

// --- a ticked hatch's held input: its touch layout (bound.js mounts it, compile.js gives it press start and end)

/**
 * A ticked probe hatch whose binding lists `input` (no tick when `hz` is 0), mounted on a page of linkedom, its
 * frames stepped by hand. `moves` are "down <control>", "up <control>", "cancel <control>" (a pointer event on the
 * pad's button) and "tick" (one frame). The pad's controls in order (null with no pad), what each tick was given,
 * and the card the page compiles to, as the pad's buttons' press actions and accessibility.
 */
export function held(input, hz, moves) {
  const { document, CustomEvent } = pageOf("<section data-screen></section>");
  const screen = document.querySelector("[data-screen]");
  const binding = { generated: "test", module: "probe.js", reads: {}, submits: [], clicks: [], input };
  if (hz) binding.tick = { hz };
  const inputs = [];
  const probe = {
    init: () => ({ n: 0 }),
    view: (st) => ({ tag: "p", key: "n", text: String(st.n) }),
    tick: (st, _reads, given) => { inputs.push(given); return { state: { n: st.n + 1 } }; },
  };
  let frame = null;
  const every = (fn) => { frame = fn; return () => { frame = null; }; };
  const faults = [];
  const log = { error: (m) => faults.push(m), log: () => {} };
  const stop = bound("probe", binding, probe, { log, every })(screen, {});
  for (const m of moves) {
    if (m === "tick") { frame?.(); continue; }
    const [what, c] = m.split(" ");
    const type = { down: "pointerdown", up: "pointerup", cancel: "pointercancel" }[what];
    screen.querySelector(`[data-hatch-hold="${c}"]`)?.dispatchEvent(new CustomEvent(type, { bubbles: true, cancelable: true }));
  }
  const pad = screen.querySelector("#hatch-probe-pad");
  const controls = pad ? [...pad.querySelectorAll("[data-hatch-hold]")].map((b) => b.getAttribute("data-hatch-hold")) : null;
  const { card } = compile(document, { sheets: [], width: 411 });
  const buttons = all(card.states[0].div).filter((d) => d.press_start_actions).map((d) => ({
    control: elementOf(d.id)?.getAttribute("data-hatch-hold") ?? null,
    start: d.press_start_actions.map((a) => a.url.replace(/[^/]+$/, "<id>")),
    end: d.press_end_actions?.map((a) => a.url.replace(/[^/]+$/, "<id>")) ?? [],
    tap: !!d.actions,
    type: d.accessibility?.type ?? null,
  }));
  stop();
  return { controls, inputs, buttons, faults, padAfterStop: screen.querySelector("#hatch-probe-pad") !== null };
}
