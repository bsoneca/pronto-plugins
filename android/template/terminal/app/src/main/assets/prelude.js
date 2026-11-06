// What QuickJS lacks and SES needs before it loads: a console, and
// Iterator.prototype's faux accessors as data properties (QuickJS's getters
// throw on an undefined receiver and SES calls them bare). Evaluated first.
globalThis.console = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) => [k, (...a) =>
  __native_log(k, a.map((v) => (v instanceof Error ? `${v.message}\n${v.stack}` : typeof v === "object" ? (() => { try { return JSON.stringify(v); } catch { return String(v); } })() : String(v))).join(" "))]));
for (const [key, value] of [["constructor", Iterator], [Symbol.toStringTag, "Iterator"]]) {
  Object.defineProperty(Iterator.prototype, key, { value, writable: true, enumerable: false, configurable: true });
}
undefined;
