// The page, drawn: on any DOM change the document compiles to a DivKit card and
// goes to the host; a native gesture comes back as the DOM event it is on the web.
import { compile, elementOf, idOf } from "./compile.js";

let sheets = [];
const readSheets = () => {
  const names = JSON.parse(__native_sheets());
  sheets = names.map(__native_asset);
  return Promise.resolve();
};

let waiting = false;
let lastCard = "";
const draw = () => {
  waiting = false;
  const live = [...document.querySelectorAll("style")].map((s) => s.textContent);
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
globalThis.__onTap = (kind, id) => {
  const el = elementOf(id);
  if (!el) return;
  if (el.type === "checkbox") { el.checked = !el.checked; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); }
  if (el.type === "radio") { el.checked = true; el.dispatchEvent(new Event("change", { bubbles: true })); }
  const type = kind === "contextmenu" ? "contextmenu" : "click";
  const ev = new CustomEvent(type, { bubbles: true, cancelable: true, composed: true });
  ev.button = kind === "contextmenu" ? 2 : 0;
  el.dispatchEvent(ev);
};
// The driver's eyes in a debug build: a selector over the same DOM the web's scenarios read.
globalThis.__probe = (selector) => {
  const els = [...document.querySelectorAll(selector)];
  return JSON.stringify(els.map((el) => ({ id: idOf(el), text: el.textContent, value: el.value, attrs: Object.fromEntries([...el.attributes].map((a) => [a.name, a.value])), hidden: el.closest("[hidden]") !== null })));
};

export async function startDisplay() {
  await readSheets();
  new MutationObserver(soon).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  soon();
}
