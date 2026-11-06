// The browser a terminal owes the interpreter, over the host's bridges: every
// effect the web gets from the page, the phone gets from Kotlin (bridge.kt's
// __native_*), each answered by a later call into the __on* functions here. The
// interpreter itself is omnishell's, unchanged; this file is what it stands on.
import { parseHTML } from "npm:linkedom@0.18.4";
import URLImpl from "npm:core-js-pure@3.45.1/actual/url/index.js";
import URLSearchParamsImpl from "npm:core-js-pure@3.45.1/actual/url-search-params/index.js";
import { TextEncoder as TE, TextDecoder as TD } from "npm:fastestsmallesttextencoderdecoder@1.0.22";

const g = globalThis;
g.URL ??= URLImpl;
g.URLSearchParams ??= URLSearchParamsImpl;
g.TextEncoder ??= TE;
g.TextDecoder ??= TD;

// Timers: every wake comes back through __onTimer, so one JS turn at a time.
const timers = new Map();
let nextTimer = 1;
const arm = (fn, ms, args, repeat) => {
  const id = nextTimer++;
  timers.set(id, { fn, args, repeat: repeat ? Math.max(ms, 1) : 0 });
  __native_timer(id, Math.max(ms ?? 0, 0));
  return id;
};
g.setTimeout = (fn, ms, ...args) => arm(fn, ms, args, false);
g.setInterval = (fn, ms, ...args) => arm(fn, ms, args, true);
g.clearTimeout = g.clearInterval = (id) => { if (timers.delete(id)) __native_clear(id); };
g.__onTimer = (id) => {
  const t = timers.get(id);
  if (!t) return;
  if (t.repeat) __native_timer(id, t.repeat);
  else timers.delete(id);
  t.fn(...t.args);
};
g.queueMicrotask ??= (fn) => { Promise.resolve().then(fn); };
g.requestAnimationFrame = (fn) => setTimeout(() => fn(Date.now()), 16);
g.cancelAnimationFrame = clearTimeout;
g.requestIdleCallback = (fn) => setTimeout(() => fn({ didTimeout: false, timeRemaining: () => 8 }), 1);
g.cancelIdleCallback = clearTimeout;
const started = Date.now();
g.performance ??= { now: () => Date.now() - started, mark() {}, measure() {}, getEntriesByType: () => [], timeOrigin: started };

// crypto: the platform's random; subtle is absent, as the interpreter's guards expect of an insecure origin.
g.crypto ??= {
  randomUUID: () => __native_uuid(),
  getRandomValues: (a) => { const b = JSON.parse(__native_random(a.byteLength)); new Uint8Array(a.buffer, a.byteOffset, a.byteLength).set(b); return a; },
};

// One page: the document the interpreter draws into. The display reads it.
const base = __native_base();
const { window, document, Event, CustomEvent, MutationObserver, HTMLElement, Element, Node, DocumentFragment, HTMLFormElement, HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement, HTMLStyleElement } = parseHTML(
  `<!doctype html><html lang="en" dir="ltr"><head><base href="${base}/shell/"><title></title></head><body><main id="app"></main></body></html>`,
);
const events = new Map();
const on = (type, fn) => { events.set(type, [...(events.get(type) ?? []), fn]); };
const off = (type, fn) => { events.set(type, (events.get(type) ?? []).filter((h) => h !== fn)); };
g.__fireWindow = (type, event) => { for (const h of events.get(type) ?? []) h(event); };

// The address: a URL the host starts at, moved by history and heard by popstate.
let here = new URL(__native_start(), base);
const stack = [{ url: here.href, state: null }];
let at = 0;
const location = {
  get href() { return here.href; }, set href(v) { location.assign(v); },
  get origin() { return here.origin; }, get protocol() { return here.protocol; }, get host() { return here.host; }, get hostname() { return here.hostname; }, get port() { return here.port; },
  get pathname() { return here.pathname; }, get search() { return here.search; }, get hash() { return here.hash; },
  assign(v) { history.pushState(null, "", v); __fireWindow("popstate", new Event("popstate")); },
  replace(v) { history.replaceState(null, "", v); __fireWindow("popstate", new Event("popstate")); },
  reload() { __native_reload(); },
  toString() { return here.href; },
};
const history = {
  get state() { return stack[at].state; }, get length() { return stack.length; }, scrollRestoration: "manual",
  pushState(state, _t, url) { here = new URL(url ?? here.href, here); stack.length = ++at; stack.push({ url: here.href, state }); },
  replaceState(state, _t, url) { here = new URL(url ?? here.href, here); stack[at] = { url: here.href, state }; },
  go(n) {
    const to = at + n;
    if (to < 0 || to >= stack.length) { if (to < 0) __native_exit(); return; }
    at = to; here = new URL(stack[at].url);
    setTimeout(() => { const e = new Event("popstate"); e.state = stack[at].state; __fireWindow("popstate", e); }, 0);
  },
  back() { history.go(-1); }, forward() { history.go(1); },
};
g.__goBack = () => history.back();

// Storage: the host's, by namespace; a session outlives the process on a phone.
const storage = (ns) => new Proxy({
  getItem: (k) => __native_kv_get(ns, String(k)) ?? null,
  setItem: (k, v) => __native_kv_set(ns, String(k), String(v)),
  removeItem: (k) => __native_kv_del(ns, String(k)),
  clear: () => __native_kv_clear(ns),
  key: (i) => JSON.parse(__native_kv_keys(ns))[i] ?? null,
  get length() { return JSON.parse(__native_kv_keys(ns)).length; },
}, { ownKeys: () => JSON.parse(__native_kv_keys(ns)), getOwnPropertyDescriptor: (t, k) => k in t ? Object.getOwnPropertyDescriptor(t, k) : { enumerable: true, configurable: true, value: __native_kv_get(ns, String(k)) } });

// One page, so a lock is only ever contended within it: a queue per name.
const held = new Map();
const locks = {
  async request(name, options, callback) {
    const cb = callback ?? options;
    const opts = callback ? options : {};
    if (opts.signal?.aborted) throw opts.signal.reason;
    const prior = held.get(name) ?? Promise.resolve();
    if (opts.ifAvailable && held.has(name)) return cb(null);
    let release;
    const mine = new Promise((r) => { release = r; });
    held.set(name, mine);
    await prior;
    try {
      return await cb({ name, mode: opts.mode ?? "exclusive" });
    } finally {
      if (held.get(name) === mine) held.delete(name);
      release();
    }
  },
  query: async () => ({ held: [], pending: [] }),
};
const navigator = { userAgent: "pronto-android", language: __native_locale(), languages: [__native_locale()], onLine: true, credentials: undefined, serviceWorker: undefined, locks };

// fetch: one bridge call, one whole answer. A live read is a long poll, so
// nothing the interpreter asks needs a body as a stream.
class Headers {
  constructor(init) { this.m = new Map(); if (init) for (const [k, v] of init[Symbol.iterator] ? init : Object.entries(init)) this.set(k, v); }
  get(k) { return this.m.get(String(k).toLowerCase()) ?? null; }
  set(k, v) { this.m.set(String(k).toLowerCase(), String(v)); }
  has(k) { return this.m.has(String(k).toLowerCase()); }
  delete(k) { this.m.delete(String(k).toLowerCase()); }
  append(k, v) { const p = this.get(k); this.set(k, p === null ? v : `${p}, ${v}`); }
  forEach(fn) { for (const [k, v] of this.m) fn(v, k, this); }
  entries() { return this.m.entries(); } keys() { return this.m.keys(); } values() { return this.m.values(); }
  [Symbol.iterator]() { return this.m.entries(); }
}
class Response {
  constructor(body, init = {}) {
    this._body = body ?? ""; this.status = init.status ?? 200; this.statusText = init.statusText ?? ""; this.headers = new Headers(init.headers); this.url = init.url ?? ""; this.ok = this.status >= 200 && this.status < 300; this.redirected = false; this.type = "basic"; this.body = null; this.bodyUsed = false;
  }
  async text() { return this._body; }
  async json() { return JSON.parse(this._body); }
  clone() { return new Response(this._body, this); }
}
class Request {
  constructor(input, init = {}) { this.url = typeof input === "string" ? input : input.url ?? String(input); this.method = init.method ?? input.method ?? "GET"; this.headers = new Headers(init.headers ?? input.headers); this.body = init.body ?? input.body; this.signal = init.signal ?? input.signal; }
}
class AbortSignalImpl extends EventTargetLite() {
  constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
  throwIfAborted() { if (this.aborted) throw this.reason; }
  static any(signals) { const c = new AbortController(); for (const s of signals) { if (s.aborted) c.abort(s.reason); else s.addEventListener("abort", () => c.abort(s.reason), { once: true }); } return c.signal; }
  static timeout(ms) { const c = new AbortController(); setTimeout(() => c.abort(abortError("timed out", "TimeoutError")), ms); return c.signal; }
  static abort(reason) { const c = new AbortController(); c.abort(reason); return c.signal; }
}
function EventTargetLite() {
  return class {
    constructor() { this._l = new Map(); }
    addEventListener(t, fn, o) { const l = this._l.get(t) ?? []; l.push({ fn, once: !!o?.once }); this._l.set(t, l); }
    removeEventListener(t, fn) { this._l.set(t, (this._l.get(t) ?? []).filter((e) => e.fn !== fn)); }
    dispatchEvent(ev) { for (const e of [...(this._l.get(ev.type) ?? [])]) { e.fn(ev); if (e.once) this.removeEventListener(ev.type, e.fn); } if (typeof this[`on${ev.type}`] === "function") this[`on${ev.type}`](ev); return true; }
  };
}
const abortError = (m, name = "AbortError") => { const e = new Error(m); e.name = name; return e; };
class AbortController {
  constructor() { this.signal = new AbortSignalImpl(); }
  abort(reason) { if (this.signal.aborted) return; this.signal.aborted = true; this.signal.reason = reason ?? abortError("aborted"); this.signal.dispatchEvent({ type: "abort" }); }
}
g.AbortController = AbortController;
g.AbortSignal = AbortSignalImpl;
const pending = new Map();
let nextFetch = 1;
g.__onFetch = (id, status, headers, body) => { const p = pending.get(id); if (!p) return; pending.delete(id); p.resolve(new Response(body, { status, headers: JSON.parse(headers), url: p.url })); };
g.__onFetchFailed = (id, message) => { const p = pending.get(id); if (!p) return; pending.delete(id); p.reject(new TypeError(`fetch failed: ${message}`)); };
g.fetch = (input, init = {}) => new Promise((resolve, reject) => {
  const req = new Request(input, init);
  const url = new URL(req.url, here).href;
  if (req.signal?.aborted) return reject(req.signal.reason);
  const id = nextFetch++;
  pending.set(id, { resolve, reject, url });
  req.signal?.addEventListener("abort", () => { if (pending.delete(id)) { __native_fetch_abort(id); reject(req.signal.reason); } }, { once: true });
  __native_fetch(id, url, req.method.toUpperCase(), JSON.stringify(Object.fromEntries(req.headers.m)), req.body === undefined || req.body === null ? null : String(req.body));
});
g.Response = Response; g.Request = Request; g.Headers = Headers;

// A wake as a task of its own: a channel over the host's timer.
g.MessageChannel = class {
  constructor() {
    const mk = () => ({ onmessage: null, peer: null, closed: false, close() { this.closed = true; }, start() {}, addEventListener(_t, fn) { this.onmessage = fn; }, removeEventListener() {},
      postMessage(data) { const p = this.peer; setTimeout(() => { if (!p.closed) p.onmessage?.({ data }); }, 0); } });
    this.port1 = mk(); this.port2 = mk(); this.port1.peer = this.port2; this.port2.peer = this.port1;
  }
};
g.BroadcastChannel = class { constructor() {} postMessage() {} close() {} addEventListener() {} removeEventListener() {} };
g.structuredClone ??= (v) => JSON.parse(JSON.stringify(v));

// Intl: the platform's ICU, one sync call per format. QuickJS has none.
const intl = (kind, locale, options, value) => __native_intl(kind, Array.isArray(locale) ? locale[0] ?? "" : locale ?? "", JSON.stringify(options ?? {}), value === undefined ? "" : String(value));
// Intl's constructors answer without `new` too, and a format is a bound function.
const callable = (C) => { const f = function (...a) { return new C(...a); }; f.prototype = C.prototype; return f; };
g.Intl = {
  getCanonicalLocales: (l) => [l].flat().filter(Boolean).map((t) => intl("canonical", t)),
  DateTimeFormat: callable(class {
    constructor(l, o) { this.l = l; this.o = o; this.format = (d) => intl("date", l, o, new Date(d ?? Date.now()).getTime()); }
    formatToParts(d) { return [{ type: "literal", value: this.format(d) }]; }
    resolvedOptions() { return { locale: intl("canonical", [this.l].flat()[0] || navigator.language), timeZone: this.o?.timeZone ?? __native_zone(), ...this.o }; }
  }),
  NumberFormat: callable(class { constructor(l, o) { this.l = l; this.o = o; this.format = (n) => intl("number", l, o, n); } resolvedOptions() { return { locale: this.l, ...this.o }; } }),
  PluralRules: class { constructor(l, o) { this.l = l; this.o = o; } select(n) { return intl("plural", this.l, this.o, n); } resolvedOptions() { return { locale: this.l, ...this.o }; } },
  Collator: callable(class { constructor(l) { this.l = l; this.compare = (a, b) => String(a).localeCompare(String(b)); } resolvedOptions() { return { locale: this.l }; } }),
  Locale: class { constructor(t) { this.tag = t; const rtl = /^(ar|he|fa|ur)\b/.test(t); this.textInfo = { direction: rtl ? "rtl" : "ltr" }; } getTextInfo() { return this.textInfo; } toString() { return this.tag; } },
  RelativeTimeFormat: class { constructor(l) { this.l = l; } format(v, u) { return `${v} ${u}`; } },
  ListFormat: class { constructor(l) { this.l = l; } format(a) { return [...a].join(", "); } },
  Segmenter: class { constructor(l) { this.l = l; } segment(s) { return [...s].map((c, i) => ({ segment: c, index: i, input: s })); } },
};

// What linkedom leaves to a browser and the interpreter asks of a form: values
// as properties, the platform's constraints, submit and reset.
const fieldProto = (P) => {
  if (!P) return;
  Object.defineProperty(P, "value", {
    configurable: true,
    get() { if (this.localName === "textarea") return this._value ?? this.textContent ?? ""; if (this.localName === "select") { const o = [...this.querySelectorAll("option")]; const s = o.find((x) => x.hasAttribute("selected")) ?? o[0]; return this._value ?? s?.getAttribute("value") ?? s?.textContent ?? ""; } return this._value ?? this.getAttribute("value") ?? (this.getAttribute("type") === "checkbox" ? "on" : ""); },
    set(v) { this._value = String(v ?? ""); },
  });
  Object.defineProperty(P, "defaultValue", { configurable: true, get() { return this.localName === "textarea" ? this.textContent : this.getAttribute("value") ?? ""; }, set(v) { if (this.localName === "textarea") this.textContent = v; else this.setAttribute("value", v); } });
  Object.defineProperty(P, "checked", { configurable: true, get() { return this._checked ?? this.hasAttribute("checked"); }, set(v) { this._checked = !!v; } });
  Object.defineProperty(P, "type", { configurable: true, get() { return this.localName === "textarea" ? "textarea" : this.localName === "select" ? "select-one" : this.getAttribute("type") ?? "text"; }, set(v) { this.setAttribute("type", v); } });
  Object.defineProperty(P, "name", { configurable: true, get() { return this.getAttribute("name") ?? ""; }, set(v) { this.setAttribute("name", v); } });
  Object.defineProperty(P, "required", { configurable: true, get() { return this.hasAttribute("required"); }, set(v) { this.toggleAttribute("required", !!v); } });
  Object.defineProperty(P, "disabled", { configurable: true, get() { return this.hasAttribute("disabled"); }, set(v) { this.toggleAttribute("disabled", !!v); } });
  Object.defineProperty(P, "form", { configurable: true, get() { return this.closest("form"); } });
  P.validity_ = function () {
    const v = this.value, a = (n) => this.getAttribute(n), t = this.type;
    if (this.disabled || t === "hidden" || t === "submit" || t === "button") return {};
    const missing = this.required && (t === "checkbox" || t === "radio" ? !this.checked : v === "");
    if (missing) return { valueMissing: true };
    if (v === "") return {};
    const size = [...v].length;
    if (a("maxlength") !== null && size > +a("maxlength")) return { tooLong: true };
    if (a("minlength") !== null && size < +a("minlength")) return { tooShort: true };
    if (a("pattern") !== null && !new RegExp(`^(?:${a("pattern")})$`, "v").test(v)) return { patternMismatch: true };
    if (t === "email" && !/^[^\s@]+@[^\s@]+$/.test(v)) return { typeMismatch: true };
    if (t === "url" && !URL.canParse?.(v)) return { typeMismatch: true };
    if (t === "number") {
      const n = Number(v);
      if (Number.isNaN(n)) return { badInput: true };
      if (a("min") !== null && n < +a("min")) return { rangeUnderflow: true };
      if (a("max") !== null && n > +a("max")) return { rangeOverflow: true };
    }
    return this._custom ? { customError: true } : {};
  };
  Object.defineProperty(P, "validity", { configurable: true, get() { const v = this.validity_(); return { ...v, valid: Object.keys(v).length === 0 }; } });
  Object.defineProperty(P, "validationMessage", { configurable: true, get() { return this._custom ?? (this.validity.valid ? "" : Object.keys(this.validity_())[0]); } });
  P.setCustomValidity = function (m) { this._custom = m || undefined; };
  P.checkValidity = function () { const ok = this.validity.valid; if (!ok) this.dispatchEvent(new Event("invalid", { cancelable: true })); return ok; };
  P.reportValidity = P.checkValidity;
  Object.defineProperty(P, "options", { configurable: true, get() { return [...this.querySelectorAll("option")]; } });
};
for (const P of [HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement]) fieldProto(P?.prototype);
const F = HTMLFormElement.prototype;
const fieldsOf = (f) => [...f.querySelectorAll("input,textarea,select,button")];
Object.defineProperty(F, "elements", { configurable: true, get() { const l = fieldsOf(this); for (const e of l) if (e.getAttribute("name")) l[e.getAttribute("name")] ??= e; l.namedItem = (n) => l[n] ?? null; return l; } });
F.checkValidity = function () { return fieldsOf(this).filter((e) => e.localName !== "button").map((e) => e.checkValidity()).every(Boolean); };
F.reportValidity = F.checkValidity;
F.reset = function () { for (const e of fieldsOf(this)) { e._value = undefined; e._checked = undefined; e._custom = undefined; } this.dispatchEvent(new Event("reset", { bubbles: true })); };
F.requestSubmit = function (submitter) { if (!this.hasAttribute("novalidate") && !this.checkValidity()) return; const e = new Event("submit", { bubbles: true, cancelable: true }); e.submitter = submitter ?? null; this.dispatchEvent(e); };
F.submit = F.requestSubmit;
g.FormData = class {
  constructor(form, submitter) { this.e = []; for (const f of form ? fieldsOf(form) : []) { const n = f.getAttribute("name"); if (!n || f.disabled) continue; if (f.localName === "button") { if (f === submitter) this.e.push([n, f.getAttribute("value") ?? ""]); continue; } if ((f.type === "checkbox" || f.type === "radio") && !f.checked) continue; this.e.push([n, f.value]); } }
  get(n) { return this.e.find(([k]) => k === n)?.[1] ?? null; } getAll(n) { return this.e.filter(([k]) => k === n).map(([, v]) => v); } has(n) { return this.e.some(([k]) => k === n); }
  set(n, v) { this.delete(n); this.e.push([n, v]); } append(n, v) { this.e.push([n, v]); } delete(n) { this.e = this.e.filter(([k]) => k !== n); }
  entries() { return this.e[Symbol.iterator](); } keys() { return this.e.map(([k]) => k)[Symbol.iterator](); } values() { return this.e.map(([, v]) => v)[Symbol.iterator](); } [Symbol.iterator]() { return this.entries(); }
};
// Popovers and dialogs: their open state as attributes the compiler reads.
const E = (HTMLElement ?? Element).prototype;
E.showPopover = function () { this.setAttribute("data-popover-open", ""); this.dispatchEvent(new Event("toggle")); };
E.hidePopover = function () { this.removeAttribute("data-popover-open"); this.dispatchEvent(new Event("toggle")); };
E.togglePopover = function () { if (this.hasAttribute("data-popover-open")) this.hidePopover(); else this.showPopover(); };
E.showModal = E.show = function () { this.setAttribute("open", ""); };
E.close = function () { if (this.hasAttribute("open")) { this.removeAttribute("open"); this.dispatchEvent(new Event("close")); } };
E.getBoundingClientRect = () => ({ x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
E.scrollIntoView = E.focus = E.blur = function () {};
E.animate = function () { return { finished: Promise.resolve(), cancel() {}, onfinish: null }; };
if (!("isContentEditable" in E)) Object.defineProperty(E, "isContentEditable", { configurable: true, get() { return this.hasAttribute("contenteditable"); } });
if (!("parentElement" in E)) Object.defineProperty(E, "parentElement", { configurable: true, get() { return this.parentNode?.nodeType === 1 ? this.parentNode : null; } });
// A sheet is ready once it is in: the interpreter waits on its load, which only a browser fires.
if (HTMLStyleElement) {
  const listen = HTMLStyleElement.prototype.addEventListener;
  HTMLStyleElement.prototype.addEventListener = function (type, fn, opts) {
    if (type === "load") { setTimeout(() => fn(new Event("load")), 0); return; }
    return listen.call(this, type, fn, opts);
  };
}
// A click on a submit button submits its form; a link stays with the interpreter.
document.addEventListener("click", (ev) => {
  if (ev.defaultPrevented) return;
  const el = ev.target?.closest?.("button,input");
  if (!el) return;
  const t = el.localName === "button" ? el.getAttribute("type") ?? "submit" : el.getAttribute("type");
  if (t === "submit" && el.closest("form")) el.closest("form").requestSubmit(el);
  if (t === "reset" && el.closest("form")) el.closest("form").reset();
  const cmd = el.getAttribute("commandfor"), target = cmd && document.getElementById(cmd);
  if (target) { const c = el.getAttribute("command"); if (c === "show-modal") target.showModal(); else if (c === "close") target.close(); else if (c === "toggle-popover") target.togglePopover(); }
  const pop = el.getAttribute("popovertarget"), ptarget = pop && document.getElementById(pop);
  if (ptarget) ptarget.togglePopover();
});
document.visibilityState = "visible";
document.hasFocus = () => true;

Object.assign(g, { window: g, document, Event, CustomEvent, MutationObserver, HTMLElement, Element, Node, DocumentFragment, HTMLFormElement, HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement });
Object.defineProperties(g, {
  location: { value: location, configurable: true }, history: { value: history, configurable: true }, navigator: { value: navigator, configurable: true },
  localStorage: { value: storage("local"), configurable: true }, sessionStorage: { value: storage("session"), configurable: true },
  indexedDB: { value: undefined, configurable: true }, scrollY: { value: 0, configurable: true, writable: true },
  innerWidth: { value: 411, configurable: true, writable: true }, innerHeight: { value: 900, configurable: true, writable: true },
});
g.addEventListener = on; g.removeEventListener = off;
g.scrollTo = () => {};
g.getComputedStyle = () => ({ getPropertyValue: () => "" });
g.matchMedia = (q) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
g.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
g.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
void window;
