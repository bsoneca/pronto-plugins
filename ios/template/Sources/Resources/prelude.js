// What JavaScriptCore lacks that SES and the terminal bundle stand on, evaluated first, before SES and before lockdown().
// The bundle's browser.js supplies the rest of the globals a terminal owes (URL, URLSearchParams, TextEncoder, TextDecoder,
// atob, btoa) with `??=`, as it does on Android, so none is defined here a second time.

// A console: SES logs through it, and JavaScriptCore's own has no host to write to.
globalThis.console = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) => [k, (...a) =>
  __native_log(k, a.map((v) => (v instanceof Error ? `${v.message}\n${v.stack}` : typeof v === "object" ? (() => { try { return JSON.stringify(v); } catch { return String(v); } })() : String(v))).join(" "))]));

// JavaScriptCore has no queueMicrotask, and a context no event loop, so a timer is the host's: every wake comes back
// through __onTimer, one JS turn at a time, on the clock the host gives __native_timer (the engine's `schedule`).
globalThis.queueMicrotask = (fn) => { Promise.resolve().then(fn).catch((e) => console.error("microtask failed", e)); };
{
  const timers = new Map();
  let next = 1;
  const arm = (fn, ms, args, repeat) => {
    const id = next++;
    timers.set(id, { fn, args, repeat: repeat ? Math.max(ms ?? 0, 1) : 0 });
    __native_timer(id, Math.max(ms ?? 0, 0));
    return id;
  };
  globalThis.setTimeout = (fn, ms, ...args) => arm(fn, ms, args, false);
  globalThis.setInterval = (fn, ms, ...args) => arm(fn, ms, args, true);
  globalThis.clearTimeout = globalThis.clearInterval = (id) => { if (timers.delete(id)) __native_clear(id); };
  globalThis.__onTimer = (id) => {
    const t = timers.get(id);
    if (!t) return;
    if (t.repeat) __native_timer(id, t.repeat);
    else timers.delete(id);
    t.fn(...t.args);
  };
}

// Intl is JavaScriptCore's own, and the bridge the bundle's Intl calls answers from it: the four arguments Android
// answers from ICU (native/bridges.cue: kind, language tag, options as JSON, value as text).
{
  // Taken now, before anything can replace them; the engine hardens them once SES has loaded.
  const { PluralRules, NumberFormat, DateTimeFormat, getCanonicalLocales } = Intl;
  const tagOf = (tag) => (tag === "" ? undefined : tag);
  globalThis.__native_intl = (kind, tag, options, value) => {
    const o = JSON.parse(options);
    if (kind === "canonical") return getCanonicalLocales(tagOf(tag) ?? "en-US")[0];
    if (kind === "plural") return new PluralRules(tagOf(tag)).select(Number(value));
    if (kind === "number") return new NumberFormat(tagOf(tag), o).format(Number(value));
    if (kind === "date") return new DateTimeFormat(tagOf(tag), o).format(Number(value));
    throw new Error(`Intl: ${kind}`);
  };
}
undefined;
