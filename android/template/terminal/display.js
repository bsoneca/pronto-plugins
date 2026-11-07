// The page, drawn: on any DOM change the document compiles to a DivKit card and
// goes to the host; a native gesture comes back as the DOM event it is on the web.
import { compile, elementOf, idOf } from "./compile.js";

// The sheets are the web's: the stylesheets the app's shell/index.html links, in its order, then
// any the shell links or writes into the page as it runs. A file is the asset at its path under
// /shell/, where the web serves it.
let sheets = [];
const loaded = new Map();
const assetOf = (href) => {
  const path = new URL(href, document.querySelector("base")?.getAttribute("href") ?? location.href).pathname;
  if (!path.startsWith("/shell/")) return null;
  const name = path.slice("/shell/".length);
  if (!loaded.has(name)) {
    let text = null;
    try { text = __native_asset(name); } catch { console.warn("unsupported on Android: a stylesheet the app does not ship:", href); }
    loaded.set(name, text);
  }
  return loaded.get(name);
};
const linked = (html) => [...html.matchAll(/<link\b[^>]*>/gi)].map((m) => m[0])
  .filter((tag) => /\brel\s*=\s*["']?[^"'>]*\bstylesheet\b/i.test(tag))
  .map((tag) => (tag.match(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i) || []).slice(1).find((v) => v !== undefined))
  .filter((href) => href);
const readSheets = () => {
  sheets = linked(__native_asset("index.html")).map(assetOf).filter((s) => s !== null);
  return Promise.resolve();
};

let waiting = false;
let lastCard = "";
const draw = () => {
  waiting = false;
  const live = [...document.querySelectorAll('link[rel~="stylesheet"], style')]
    .map((s) => s.localName === "style" ? s.textContent : assetOf(s.getAttribute("href") || "")).filter((s) => s !== null);
  const { card, unsupported } = compile(document, { sheets: [...sheets, ...live], width: globalThis.innerWidth });
  const json = JSON.stringify(card);
  for (const u of unsupported) reported.has(u) || (reported.add(u), console.warn("unsupported on Android:", u));
  if (json !== lastCard) { lastCard = json; __native_emit(json); }
};
const reported = new Set();
const soon = () => { if (!waiting) { waiting = true; setTimeout(draw, 16); } };

globalThis.__onResize = (dp) => { globalThis.innerWidth = dp; soon(); };
// A typed value lands on the field, and the field's own input event follows.
globalThis.__onInput = (id, value) => {
  const el = elementOf(id);
  if (!el || el.value === value) return;
  el.value = value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
};
const press = (kind, el) => {
  if (el.type === "checkbox") { el.checked = !el.checked; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); }
  if (el.type === "radio") { el.checked = true; el.dispatchEvent(new Event("change", { bubbles: true })); }
  const type = kind === "contextmenu" ? "contextmenu" : "click";
  const ev = new CustomEvent(type, { bubbles: true, cancelable: true, composed: true });
  ev.button = kind === "contextmenu" ? 2 : 0;
  el.dispatchEvent(ev);
  // A link's own action, which no handler took: one to another origin leaves for the system
  // browser; one of the app's is the shell's (its router took it, or it is a route).
  const a = type === "click" && !ev.defaultPrevented ? el.closest("a[href]") : null;
  if (a && !a.hasAttribute("download")) globalThis.__leave(a.getAttribute("href"));
};
globalThis.__onTap = (kind, id) => {
  const el = elementOf(id);
  if (el) press(kind, el);
};
// The driver's eyes in a debug build: a selector over the same DOM the web's scenarios read.
globalThis.__probe = (selector) => {
  const els = [...document.querySelectorAll(selector)];
  return JSON.stringify(els.map((el) => ({ id: idOf(el), text: el.textContent, value: el.value, attrs: Object.fromEntries([...el.attributes].map((a) => [a.name, a.value])), hidden: el.closest("[hidden]") !== null })));
};

// The driver's other eyes and hands in a debug build: where the page is, whose session it holds
// (omnishell keeps the token in sessionStorage "pronto-token"; a guest's claims say guest), and a
// click on a selector as a script's own element.click(), which needs nothing drawn on the screen.
globalThis.__where = () => location.href;
globalThis.__session = () => {
  let token = null;
  try { token = JSON.parse(sessionStorage.getItem("pronto-token") || "null")?.token ?? null; } catch { /* none */ }
  if (!token) return "null";
  try {
    const claims = JSON.parse(globalThis.atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return JSON.stringify({ token, id: claims.sub, guest: claims.guest === true });
  } catch (e) { console.log("session unreadable", e); return "null"; }
};
globalThis.__domClick = (selector) => {
  const el = document.querySelector(selector);
  if (!el) return "false";
  press("click", el);
  return "true";
};

export async function startDisplay() {
  await readSheets();
  new MutationObserver(soon).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  soon();
}
