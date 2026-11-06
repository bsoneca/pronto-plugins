// A small CSS engine for the Android terminal: a hand-written parser, the cascade, and the value
// parsers (colours, lengths, calc) that the compiler (compile.js) reads a live linkedom DOM through.
// Only the CSS the pronto apps use. Plain ES: no globals beyond the language's own, no Intl, no
// intrinsic is touched, so it runs in QuickJS after SES lockdown.
//
//   const rules = parse(sheets, {width, scheme});   // parsed and indexed once per sheet text
//   const styler = createStyler(rules, {width, scheme});
//   const st = styler.style(el);                    // {p: {longhand: value}, fs, scope}
//
// A value in `st.p` is the cascaded text, its var() and light-dark() resolved, its shorthand
// expanded to longhands; parseColor() and length() read it.

const isWs = (c) => c === 32 || c === 9 || c === 10 || c === 13 || c === 12;

/** Splits a text at a character that is outside parentheses, brackets and strings. */
export function splitTop(s, sep) {
  const out = [];
  let d = 0, q = "", from = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = ""; continue; }
    if (c === '"' || c === "'") q = c;
    else if (c === "(" || c === "[") d++;
    else if (c === ")" || c === "]") d--;
    else if (c === sep && d === 0) { out.push(s.slice(from, i)); from = i + 1; }
  }
  out.push(s.slice(from));
  return out;
}

/** Splits a text at whitespace that is outside parentheses and strings. */
export function splitWs(s) {
  const out = [];
  let d = 0, q = "", from = -1;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = ""; continue; }
    if (c === '"' || c === "'") { q = c; if (from < 0) from = i; continue; }
    if (c === "(") d++;
    else if (c === ")") d--;
    if (isWs(s.charCodeAt(i)) && d === 0) { if (from >= 0) { out.push(s.slice(from, i)); from = -1; } }
    else if (from < 0) from = i;
  }
  if (from >= 0) out.push(s.slice(from));
  return out;
}

// The index of the parenthesis closing the one at `open`.
function matchParen(s, open) {
  let d = 0, q = "";
  for (let i = open; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = ""; continue; }
    if (c === '"' || c === "'") q = c;
    else if (c === "(") d++;
    else if (c === ")") { d--; if (d === 0) return i; }
  }
  return s.length - 1;
}

// ---------------------------------------------------------------- colours

const NAMED = {
  black: "000000", white: "ffffff", red: "ff0000", green: "008000", blue: "0000ff", yellow: "ffff00", gray: "808080", grey: "808080",
  silver: "c0c0c0", maroon: "800000", purple: "800080", fuchsia: "ff00ff", magenta: "ff00ff", lime: "00ff00", olive: "808000", navy: "000080",
  teal: "008080", aqua: "00ffff", cyan: "00ffff", orange: "ffa500", pink: "ffc0cb", brown: "a52a2a", gold: "ffd700", indigo: "4b0082",
  violet: "ee82ee", coral: "ff7f50", crimson: "dc143c", salmon: "fa8072", tomato: "ff6347", khaki: "f0e68c", beige: "f5f5dc", ivory: "fffff0",
  lavender: "e6e6fa", turquoise: "40e0d0", tan: "d2b48c", plum: "dda0dd", orchid: "da70d6", darkgray: "a9a9a9", darkgrey: "a9a9a9", lightgray: "d3d3d3",
  lightgrey: "d3d3d3", dimgray: "696969", dimgrey: "696969", whitesmoke: "f5f5f5", gainsboro: "dcdcdc", darkred: "8b0000", darkgreen: "006400",
  darkblue: "00008b", lightblue: "add8e6", lightgreen: "90ee90", skyblue: "87ceeb", royalblue: "4169e1", steelblue: "4682b4", slategray: "708090",
  // system colours, in their light appearance
  canvas: "ffffff", canvastext: "000000", buttonface: "efefef", buttontext: "000000", field: "ffffff", fieldtext: "000000", graytext: "6d6d6d",
  linktext: "0000ee", highlight: "3390ff", highlighttext: "ffffff", accentcolor: "0075ff", accentcolortext: "ffffff",
};

const hex2 = (n) => { const v = Math.max(0, Math.min(255, Math.round(n))); return (v < 16 ? "0" : "") + v.toString(16); };
const argb = (r, g, b, a) => ("#" + hex2(a * 255) + hex2(r) + hex2(g) + hex2(b)).toUpperCase();
const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);

function srgbToLinear(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
function linearToSrgb(c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }

function oklabToSrgb(L, a, b) {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const bl = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  return [clamp01(linearToSrgb(r)), clamp01(linearToSrgb(g)), clamp01(linearToSrgb(bl))];
}

function srgbToOklab(r, g, b) {
  const lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b);
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360;
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return [f(0), f(8), f(4)];
}

// A number or percentage: a percentage is `pct` per 100%.
function num(t, pct) {
  if (t === undefined || t === "none") return 0;
  if (t[t.length - 1] === "%") return (parseFloat(t) / 100) * pct;
  return parseFloat(t);
}
function hueOf(t) {
  if (t === undefined || t === "none") return 0;
  const v = parseFloat(t);
  if (/turn$/.test(t)) return v * 360;
  if (/rad$/.test(t)) return (v * 180) / Math.PI;
  if (/grad$/.test(t)) return v * 0.9;
  return v;
}
const alphaOf = (t) => (t === undefined ? 1 : clamp01(num(t, 1)));

// A colour as [r, g, b, a], channels 0..1, or null.
function colorParts(s, current, dark) {
  if (s === "transparent") return [0, 0, 0, 0];
  if (s === "currentcolor") return current ? partsOfArgb(current) : null;
  if (s[0] === "#") {
    const h = s.slice(1);
    if (!/^[0-9a-f]+$/.test(h)) return null;
    if (h.length === 3 || h.length === 4) {
      const v = (i) => parseInt(h[i] + h[i], 16) / 255;
      return [v(0), v(1), v(2), h.length === 4 ? v(3) : 1];
    }
    if (h.length === 6 || h.length === 8) {
      const v = (i) => parseInt(h.slice(i, i + 2), 16) / 255;
      return [v(0), v(2), v(4), h.length === 8 ? v(6) : 1];
    }
    return null;
  }
  const named = NAMED[s];
  if (named) return [parseInt(named.slice(0, 2), 16) / 255, parseInt(named.slice(2, 4), 16) / 255, parseInt(named.slice(4, 6), 16) / 255, 1];
  const m = /^([a-z-]+)\((.*)\)$/.exec(s);
  if (!m) return null;
  const fn = m[1], inner = m[2];
  if (fn === "light-dark") {
    const args = splitTop(inner, ",");
    return args.length === 2 ? colorParts(args[dark ? 1 : 0].trim().toLowerCase(), current, dark) : null;
  }
  if (fn === "color-mix") return mixParts(inner, current, dark);
  const t = inner.replace("/", " ").trim().split(/[\s,]+/);
  if (fn === "rgb" || fn === "rgba") {
    if (t.length < 3) return null;
    return [clamp01(num(t[0], 255) / 255), clamp01(num(t[1], 255) / 255), clamp01(num(t[2], 255) / 255), alphaOf(t[3])];
  }
  if (fn === "hsl" || fn === "hsla") {
    if (t.length < 3) return null;
    const rgb = hslToRgb(hueOf(t[0]), clamp01(num(t[1], 1)), clamp01(num(t[2], 1)));
    return [rgb[0], rgb[1], rgb[2], alphaOf(t[3])];
  }
  if (fn === "oklab") {
    if (t.length < 3) return null;
    const rgb = oklabToSrgb(num(t[0], 1), num(t[1], 0.4), num(t[2], 0.4));
    return [rgb[0], rgb[1], rgb[2], alphaOf(t[3])];
  }
  if (fn === "oklch") {
    if (t.length < 3) return null;
    const c = num(t[1], 0.4), h = (hueOf(t[2]) * Math.PI) / 180;
    const rgb = oklabToSrgb(num(t[0], 1), c * Math.cos(h), c * Math.sin(h));
    return [rgb[0], rgb[1], rgb[2], alphaOf(t[3])];
  }
  if (fn === "color" && t[0] === "srgb" && t.length >= 4) return [clamp01(num(t[1], 1)), clamp01(num(t[2], 1)), clamp01(num(t[3], 1)), alphaOf(t[4])];
  return null;
}

function partsOfArgb(c) {
  return [parseInt(c.slice(3, 5), 16) / 255, parseInt(c.slice(5, 7), 16) / 255, parseInt(c.slice(7, 9), 16) / 255, parseInt(c.slice(1, 3), 16) / 255];
}

// color-mix(in <space>, c1 [p1], c2 [p2]) in srgb or oklab (other spaces are mixed in oklab).
function mixParts(inner, current, dark) {
  const args = splitTop(inner, ",");
  if (args.length < 3) return null;
  const space = /\b(srgb|oklab)\b/.exec(args[0].toLowerCase());
  const items = args.slice(1, 3).map((a) => {
    const toks = splitWs(a.trim());
    let pct = null;
    const rest = [];
    for (const tk of toks) { if (/^[\d.]+%$/.test(tk)) pct = parseFloat(tk) / 100; else rest.push(tk); }
    return { pct, c: colorParts(rest.join(" ").toLowerCase(), current, dark) };
  });
  if (!items[0].c || !items[1].c) return null;
  let [p1, p2] = [items[0].pct, items[1].pct];
  if (p1 === null && p2 === null) { p1 = 0.5; p2 = 0.5; } else if (p1 === null) p1 = 1 - p2; else if (p2 === null) p2 = 1 - p1;
  const sum = p1 + p2;
  if (sum <= 0) return null;
  const alphaScale = sum < 1 ? sum : 1;
  p1 /= sum; p2 /= sum;
  const a = items[0].c, b = items[1].c;
  const alpha = a[3] * p1 + b[3] * p2;
  const prem = (x, y) => (alpha === 0 ? 0 : (x * a[3] * p1 + y * b[3] * p2) / alpha);
  let rgb;
  if (space && space[1] === "srgb") rgb = [prem(a[0], b[0]), prem(a[1], b[1]), prem(a[2], b[2])];
  else {
    const la = srgbToOklab(a[0], a[1], a[2]), lb = srgbToOklab(b[0], b[1], b[2]);
    rgb = oklabToSrgb(prem(la[0], lb[0]), prem(la[1], lb[1]), prem(la[2], lb[2]));
  }
  return [rgb[0], rgb[1], rgb[2], alpha * alphaScale];
}

const colorMemo = new Map();
/** A CSS colour as `#AARRGGBB`, or null. `current` is the element's own colour (for currentColor). */
export function parseColor(str, current, dark) {
  const key = (dark ? "d" : "l") + (current || "") + "|" + str;
  let r = colorMemo.get(key);
  if (r !== undefined) return r;
  const parts = colorParts(String(str).trim().toLowerCase(), current, dark);
  r = parts ? argb(parts[0] * 255, parts[1] * 255, parts[2] * 255, parts[3]) : null;
  if (colorMemo.size > 4000) colorMemo.clear();
  colorMemo.set(key, r);
  return r;
}

// ---------------------------------------------------------------- lengths

const NUMBER = /([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)([a-z%]*)/iy;

/**
 * A length in dp (1px = 1, 1rem = 16): a number, calc(), min(), max() and clamp() of lengths.
 * ctx: {fs: font size for em, rem, basis: what % is of, width: viewport width, vh}. null when it is
 * not a length, or needs a basis or a viewport height the caller did not give.
 */
export function length(str, ctx) {
  const s = String(str).trim();
  const fast = /^(-?\d*\.?\d+)(px|rem|em)?$/.exec(s);
  if (fast) {
    const n = parseFloat(fast[1]);
    if (!fast[2]) return n === 0 ? 0 : null;
    return n * (fast[2] === "px" ? 1 : fast[2] === "rem" ? (ctx.rem || 16) : (ctx.fs || 16));
  }
  const v = lenExpr(s, ctx);
  if (v === null) return null;
  if (v.s) return v.v === 0 ? 0 : null;
  return v.v;
}

/** `auto`, a percentage, or a length: {auto: true} | {pct: n} | {px: n} | null. */
export function size(str, ctx) {
  const s = String(str).trim().toLowerCase();
  if (s === "auto" || s === "") return { auto: true };
  const pm = /^(-?\d*\.?\d+)%$/.exec(s);
  if (pm) return ctx.basis !== undefined && ctx.basis !== null ? { px: (parseFloat(pm[1]) / 100) * ctx.basis, pct: parseFloat(pm[1]) } : { pct: parseFloat(pm[1]) };
  const px = length(s, ctx);
  return px === null ? null : { px };
}

function lenExpr(src, ctx) {
  let i = 0, fail = false;
  const n = src.length;
  const ws = () => { while (i < n && isWs(src.charCodeAt(i))) i++; };
  const unit = (v, u) => {
    u = u.toLowerCase();
    if (u === "") return { v, s: true };
    const fs = ctx.fs || 16, vw = ctx.width || 411;
    switch (u) {
      case "px": return { v };
      case "rem": return { v: v * (ctx.rem || 16) };
      case "em": return { v: v * fs };
      case "ch": case "ex": return { v: v * fs * 0.5 };
      case "pt": return { v: (v * 96) / 72 };
      case "pc": return { v: v * 16 };
      case "in": return { v: v * 96 };
      case "cm": return { v: (v * 96) / 2.54 };
      case "mm": return { v: (v * 96) / 25.4 };
      case "vw": case "svw": case "lvw": case "dvw": return { v: (v * vw) / 100 };
      case "vh": case "svh": case "lvh": case "dvh":
        if (ctx.vh === undefined || ctx.vh === null) { fail = true; return { v: 0 }; }
        return { v: (v * ctx.vh) / 100 };
      case "%":
        if (ctx.basis === undefined || ctx.basis === null) { fail = true; return { v: 0 }; }
        return { v: (v * ctx.basis) / 100 };
      default: fail = true; return { v: 0 };
    }
  };
  const add = (a, b, sub) => {
    if (!a || !b || !!a.s !== !!b.s) { fail = true; return a; }
    return { v: sub ? a.v - b.v : a.v + b.v, s: a.s };
  };
  const mul = (a, b) => {
    if (!a || !b) { fail = true; return a; }
    if (a.s) return { v: a.v * b.v, s: b.s };
    if (b.s) return { v: a.v * b.v };
    fail = true; return a;
  };
  const div = (a, b) => {
    if (!a || !b || !b.s || b.v === 0) { fail = true; return a; }
    return { v: a.v / b.v, s: a.s };
  };
  function sum() {
    let a = prod();
    ws();
    while (!fail && i < n && (src[i] === "+" || src[i] === "-")) {
      const op = src[i++];
      const b = prod();
      a = add(a, b, op === "-");
      ws();
    }
    return a;
  }
  function prod() {
    let a = atom();
    ws();
    while (!fail && i < n && (src[i] === "*" || src[i] === "/")) {
      const op = src[i++];
      const b = atom();
      a = op === "*" ? mul(a, b) : div(a, b);
      ws();
    }
    return a;
  }
  function atom() {
    ws();
    if (i >= n) { fail = true; return null; }
    if (src[i] === "(") {
      i++;
      const v = sum();
      ws();
      if (src[i] === ")") i++; else fail = true;
      return v;
    }
    NUMBER.lastIndex = i;
    const m = NUMBER.exec(src);
    if (m) { i += m[0].length; return unit(parseFloat(m[1]), m[2]); }
    const f = /^([a-z-]+)\(/i.exec(src.slice(i));
    if (!f) { fail = true; return null; }
    const name = f[1].toLowerCase();
    i += f[0].length;
    const args = [];
    for (;;) {
      args.push(sum());
      ws();
      if (src[i] === ",") { i++; continue; }
      if (src[i] === ")") { i++; break; }
      fail = true;
      return null;
    }
    if (fail) return null;
    if (name === "calc" && args.length === 1) return args[0];
    if (args.some((x) => !x || !!x.s !== !!args[0].s)) { fail = true; return null; }
    const vs = args.map((x) => x.v);
    if (name === "min") return { v: Math.min(...vs), s: args[0].s };
    if (name === "max") return { v: Math.max(...vs), s: args[0].s };
    if (name === "clamp" && args.length === 3) return { v: Math.max(vs[0], Math.min(vs[1], vs[2])), s: args[0].s };
    fail = true;
    return null;
  }
  const out = sum();
  ws();
  if (fail || i < n || !out) return null;
  return out;
}

// ---------------------------------------------------------------- selectors

const idEnd = (s, i) => {
  while (i < s.length) {
    const c = s.charCodeAt(i);
    if (c === 92) { i += 2; continue; }
    if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 45 || c === 95 || c > 127) i++;
    else break;
  }
  return i;
};

// [ids, classes+attributes+pseudo-classes, tags+pseudo-elements] of a complex selector.
function specTriple(sel) {
  let a = 0, b = 0, c = 0, i = 0;
  const n = sel.length;
  const take = (t) => { a += t[0]; b += t[1]; c += t[2]; };
  while (i < n) {
    const ch = sel[i];
    if (ch === "#") { a++; i = idEnd(sel, i + 1); }
    else if (ch === ".") { b++; i = idEnd(sel, i + 1); }
    else if (ch === "[") { b++; i = sel.indexOf("]", i) + 1 || n; }
    else if (ch === ":") {
      if (sel[i + 1] === ":") { c++; i = idEnd(sel, i + 2); continue; }
      const j = idEnd(sel, i + 1);
      const name = sel.slice(i + 1, j).toLowerCase();
      if (sel[j] === "(") {
        const e = matchParen(sel, j);
        const inner = sel.slice(j + 1, e);
        if (name === "where") { /* no weight */ }
        else if (name === "is" || name === "not" || name === "has" || name === "matches" || name === "-webkit-any") {
          let best = [0, 0, 0];
          for (const part of splitTop(inner, ",")) {
            const t = specTriple(part);
            if (t[0] > best[0] || (t[0] === best[0] && (t[1] > best[1] || (t[1] === best[1] && t[2] > best[2])))) best = t;
          }
          take(best);
        } else b++;
        i = e + 1;
      } else if (name === "before" || name === "after") { c++; i = j; }
      else { b++; i = j; }
    }
    else if (ch === "*") i++;
    else if (/[a-zA-Z_]/.test(ch)) { c++; i = idEnd(sel, i); }
    else i++;
  }
  return [a, b, c];
}
const specificity = (sel) => {
  const t = specTriple(sel);
  return Math.min(t[0], 999) * 1000000 + Math.min(t[1], 999) * 1000 + Math.min(t[2], 999);
};

// The rightmost compound of a complex selector.
function lastCompound(sel) {
  let d = 0, q = "", start = 0;
  for (let i = 0; i < sel.length; i++) {
    const c = sel[i];
    if (q) { if (c === "\\") i++; else if (c === q) q = ""; continue; }
    if (c === "\\") { i++; continue; }
    if (c === '"' || c === "'") q = c;
    else if (c === "(" || c === "[") d++;
    else if (c === ")" || c === "]") d--;
    else if (d === 0 && (c === " " || c === ">" || c === "+" || c === "~" || c === "\t" || c === "\n")) start = i + 1;
  }
  return sel.slice(start);
}

// The index keys of a rule: the one bucket (or buckets) an element must be in to match it.
function keysOf(sel) {
  const comp = lastCompound(sel);
  let d = 0;
  let id = null, cls = null, tag = null;
  for (let i = 0; i < comp.length; i++) {
    const c = comp[i];
    if (c === "\\") { i++; continue; }
    if (c === "(" || c === "[") { d++; continue; }
    if (c === ")" || c === "]") { d--; continue; }
    if (d !== 0) continue;
    if (c === "#" && id === null) { id = comp.slice(i + 1, idEnd(comp, i + 1)); }
    else if (c === "." && cls === null) { cls = comp.slice(i + 1, idEnd(comp, i + 1)); }
    else if (i === 0 && /[a-zA-Z]/.test(c)) { tag = comp.slice(0, idEnd(comp, 0)).toLowerCase(); }
  }
  if (id) return ["#" + id];
  if (cls) return ["." + cls];
  if (tag) return [tag];
  // :where(a, b) / :is(.x, .y) alone: one key for each simple argument
  const m = /^:(?:where|is)\(([^()]*)\)$/.exec(comp);
  if (m) {
    const keys = [];
    for (const part of splitTop(m[1], ",")) {
      const p = part.trim();
      if (/^#[\w-]+$/.test(p)) keys.push(p);
      else if (/^\.[\w-]+$/.test(p)) keys.push(p);
      else if (/^[a-zA-Z][\w-]*$/.test(p)) keys.push(p.toLowerCase());
      else return ["*"];
    }
    if (keys.length) return keys;
  }
  return ["*"];
}

const INTERACTION = /:(?:hover|active|focus-visible|focus-within|focus|visited|target|user-invalid|user-valid|current|playing|paused)(?![\w-])/g;
const SILENT_PSEUDO = /^(?:selection|marker|backdrop|-webkit-.*|-moz-.*|scrollbar.*|file-selector-button|view-transition.*|cue|slider.*|spelling-error|grammar-error|highlight.*|target-text)$/;

// ---------------------------------------------------------------- media queries

function mediaFeature(inner, env, report) {
  const width = env.width, height = env.height || 800;
  const px = (v) => length(v, { fs: 16, rem: 16, width });
  const m = /^([\w-]+)\s*:\s*(.+)$/.exec(inner);
  if (m) {
    const name = m[1], val = m[2].trim();
    switch (name) {
      case "min-width": { const v = px(val); return v !== null && width >= v; }
      case "max-width": { const v = px(val); return v !== null && width <= v; }
      case "width": { const v = px(val); return v !== null && width === v; }
      case "min-height": { const v = px(val); return v !== null && height >= v; }
      case "max-height": { const v = px(val); return v !== null && height <= v; }
      case "height": { const v = px(val); return v !== null && height === v; }
      case "prefers-color-scheme": return val === (env.scheme === "dark" ? "dark" : "light");
      case "prefers-reduced-motion": case "prefers-reduced-data": case "prefers-reduced-transparency": case "prefers-contrast": return val === "no-preference";
      case "orientation": return val === (height >= width ? "portrait" : "landscape");
      case "hover": case "any-hover": return val === "none";
      case "pointer": case "any-pointer": return val === "coarse";
      case "forced-colors": case "inverted-colors": return val === "none";
      case "color-gamut": return val === "srgb";
      case "scripting": return val === "enabled";
      case "display-mode": return val === "browser";
      default: report("@media (" + name + ")"); return false;
    }
  }
  const range = inner.split(/\s*(<=|>=|<|>|=)\s*/);
  if (range.length === 3 || range.length === 5) {
    // `width >= 600px`, `600px <= width`, `400px <= width <= 800px`
    const at = (left, op, right) => {
      if (left === "width" || left === "height") {
        const v = px(right), x = left === "width" ? width : height;
        if (v === null) return false;
        return op === "<=" ? x <= v : op === ">=" ? x >= v : op === "<" ? x < v : op === ">" ? x > v : x === v;
      }
      if (right === "width" || right === "height") {
        const v = px(left), x = right === "width" ? width : height;
        if (v === null) return false;
        return op === "<=" ? v <= x : op === ">=" ? v >= x : op === "<" ? v < x : op === ">" ? v > x : v === x;
      }
      return null;
    };
    const first = at(range[0], range[1], range[2]);
    if (first === null) { report("@media (" + inner + ")"); return false; }
    if (range.length === 5) return first && !!at(range[2], range[3], range[4]);
    return first;
  }
  if (inner === "color" || inner === "monochrome") return inner === "color";
  report("@media (" + inner + ")");
  return false;
}

function mediaMatches(prelude, env, report) {
  const q = prelude.trim().toLowerCase();
  if (!q) return true;
  return splitTop(q, ",").some((one) => {
    let part = one.trim(), neg = false;
    if (part.startsWith("not ")) { neg = true; part = part.slice(4); }
    if (part.startsWith("only ")) part = part.slice(5);
    const conds = part.split(/\)\s*and\s*|\s+and\s+\(/);
    let ok = true;
    for (let c of conds) {
      c = c.trim();
      if (c === "screen" || c === "all") continue;
      if (c === "print" || c === "speech") { ok = false; continue; }
      if (c.startsWith("screen and ")) c = c.slice(11).trim();
      if (c[0] === "(") c = c.slice(1);
      if (c[c.length - 1] === ")") c = c.slice(0, -1);
      c = c.trim();
      if (c === "screen" || c === "all") continue;
      if (!mediaFeature(c, env, report)) ok = false;
    }
    return neg ? !ok : ok;
  });
}

// ---------------------------------------------------------------- the user-agent sheet

const UA = `
html, body, div, section, article, header, footer, main, nav, aside, form, fieldset, figure, figcaption, details, summary, address,
blockquote, pre, hr, p, h1, h2, h3, h4, h5, h6, ul, ol, li, dl, dt, dd, menu, dialog, legend, table, thead, tbody, tfoot, search, hgroup { display: block; }
head, script, style, template, meta, link, title, base, noscript, area, datalist, param, source, track, [popover], dialog:not([open]) { display: none; }
[data-popover-open] { display: block; }
tr { display: flex; } td, th { display: block; flex: 1 1 0; }
button, input, select, textarea { display: inline-block; }
body { margin: 8px; }
h1 { font-size: 2em; margin-block: .67em; font-weight: bold; }
h2 { font-size: 1.5em; margin-block: .83em; font-weight: bold; }
h3 { font-size: 1.17em; margin-block: 1em; font-weight: bold; }
h4 { margin-block: 1.33em; font-weight: bold; }
h5 { font-size: .83em; margin-block: 1.67em; font-weight: bold; }
h6 { font-size: .67em; margin-block: 2.33em; font-weight: bold; }
p, dl, pre, blockquote, menu { margin-block: 1em; }
blockquote { margin-inline: 40px; }
ul, ol, menu { padding-inline-start: 40px; }
dd { margin-inline-start: 40px; }
figure { margin-block: 1em; margin-inline: 40px; }
ul, menu { list-style-type: disc; } ol { list-style-type: decimal; }
b, strong, th { font-weight: bold; }
i, em, cite, dfn, var, address { font-style: italic; }
small, sub, sup { font-size: smaller; }
u, ins { text-decoration-line: underline; }
s, del, strike { text-decoration-line: line-through; }
code, pre, kbd, samp, tt { font-family: monospace; }
pre { white-space: pre; }
a[href] { color: #0000EE; text-decoration-line: underline; }
mark { background-color: #FFFF00; color: #000000; }
hr { margin-block: .5em; border: 1px solid #9A9A9A; }
th { text-align: center; }
button, input[type=submit], input[type=button], input[type=reset] { text-align: center; color: #000000; background-color: #EFEFEF; border: 1px solid #767676; border-radius: 3px; padding: 1px 6px; font: 13.3333px system-ui; }
input, textarea, select { color: #000000; background-color: #FFFFFF; border: 1px solid #767676; border-radius: 2px; padding: 1px 2px; font: 13.3333px system-ui; }
textarea { padding: 2px; }
img { display: inline; }
`;

// ---------------------------------------------------------------- the parser

function newReports() {
  const seen = new Set();
  const list = [];
  return {
    list,
    add(what, selector) {
      const k = what + "\u0001" + (selector || "");
      if (!seen.has(k)) { seen.add(k); list.push({ what, selector: selector || "" }); }
    },
  };
}

const ALIAS = {};
(function () {
  const sides = [["block-start", "top"], ["block-end", "bottom"], ["inline-start", "left"], ["inline-end", "right"]];
  for (const [l, p] of sides) {
    ALIAS["margin-" + l] = "margin-" + p;
    ALIAS["padding-" + l] = "padding-" + p;
    ALIAS["inset-" + l] = p;
    for (const k of ["width", "style", "color"]) ALIAS["border-" + l + "-" + k] = "border-" + p + "-" + k;
  }
  const sz = { "block-size": "height", "inline-size": "width", "min-block-size": "min-height", "min-inline-size": "min-width", "max-block-size": "max-height", "max-inline-size": "max-width" };
  for (const k of Object.keys(sz)) ALIAS[k] = sz[k];
  ALIAS["border-start-start-radius"] = "border-top-left-radius";
  ALIAS["border-start-end-radius"] = "border-top-right-radius";
  ALIAS["border-end-end-radius"] = "border-bottom-right-radius";
  ALIAS["border-end-start-radius"] = "border-bottom-left-radius";
  ALIAS["grid-gap"] = "gap"; ALIAS["grid-row-gap"] = "row-gap"; ALIAS["grid-column-gap"] = "column-gap";
})();

const SIDES = ["top", "right", "bottom", "left"];
const CORNERS = ["top-left", "top-right", "bottom-right", "bottom-left"];
const box4 = (v) => {
  const a = v[0], b = v.length > 1 ? v[1] : a, c = v.length > 2 ? v[2] : a, d = v.length > 3 ? v[3] : b;
  return [a, b, c, d];
};

// The longhands a shorthand sets (so `inherit`, `initial` and `unset` reach each of them).
const LONG = {
  margin: SIDES.map((s) => "margin-" + s),
  padding: SIDES.map((s) => "padding-" + s),
  "margin-block": ["margin-top", "margin-bottom"], "margin-inline": ["margin-left", "margin-right"],
  "padding-block": ["padding-top", "padding-bottom"], "padding-inline": ["padding-left", "padding-right"],
  border: [].concat(...SIDES.map((s) => ["width", "style", "color"].map((k) => "border-" + s + "-" + k))),
  "border-radius": CORNERS.map((c) => "border-" + c + "-radius"),
  background: ["background-color", "background-image"],
  font: ["font-style", "font-weight", "font-size", "line-height", "font-family"],
  flex: ["flex-grow", "flex-shrink", "flex-basis"],
  "flex-flow": ["flex-direction", "flex-wrap"],
  gap: ["row-gap", "column-gap"],
  overflow: ["overflow-x", "overflow-y"],
  "text-decoration": ["text-decoration-line"],
  "place-items": ["align-items", "justify-items"], "place-content": ["align-content", "justify-content"], "place-self": ["align-self", "justify-self"],
  "list-style": ["list-style-type"],
  inset: SIDES.slice(),
};

export const INHERITED = [
  "color", "font-style", "font-weight", "font-size", "font-family", "line-height", "letter-spacing", "text-align", "text-transform",
  "text-decoration-line", "visibility", "white-space", "list-style-type", "cursor", "direction", "accent-color", "text-indent", "word-break", "overflow-wrap",
];
const INHERITED_SET = new Set(INHERITED);

function borderSide(tokens) {
  let w = null, s = null, c = null;
  for (const t of tokens) {
    const l = t.toLowerCase();
    if (/^(none|hidden|dotted|dashed|solid|double|groove|ridge|inset|outset)$/.test(l)) s = l;
    else if (/^(thin|medium|thick)$/.test(l) || /^[+-]?[\d.]/.test(l) || /^(calc|min|max|clamp)\(/.test(l)) w = l;
    else c = t;
  }
  return { w: w === null ? "medium" : w, s: s === null ? "none" : s, c: c === null ? "currentcolor" : c };
}

function expand(prop, v, set) {
  switch (prop) {
    case "margin": case "padding": {
      const b = box4(splitWs(v));
      SIDES.forEach((s, i) => set(prop + "-" + s, b[i]));
      return;
    }
    case "margin-block": case "padding-block": {
      const t = splitWs(v), b = box4(t);
      const base = prop.slice(0, prop.indexOf("-"));
      set(base + "-top", b[0]); set(base + "-bottom", t.length > 1 ? t[1] : t[0]);
      return;
    }
    case "margin-inline": case "padding-inline": {
      const t = splitWs(v);
      const base = prop.slice(0, prop.indexOf("-"));
      set(base + "-left", t[0]); set(base + "-right", t.length > 1 ? t[1] : t[0]);
      return;
    }
    case "inset": {
      const b = box4(splitWs(v));
      SIDES.forEach((s, i) => set(s, b[i]));
      return;
    }
    case "inset-block": { const t = splitWs(v); set("top", t[0]); set("bottom", t[t.length > 1 ? 1 : 0]); return; }
    case "inset-inline": { const t = splitWs(v); set("left", t[0]); set("right", t[t.length > 1 ? 1 : 0]); return; }
    case "border": case "border-top": case "border-right": case "border-bottom": case "border-left": case "border-block": case "border-inline":
    case "border-block-start": case "border-block-end": case "border-inline-start": case "border-inline-end": {
      const o = borderSide(splitWs(v));
      let sides = SIDES;
      if (prop === "border-top" || prop === "border-block-start") sides = ["top"];
      else if (prop === "border-bottom" || prop === "border-block-end") sides = ["bottom"];
      else if (prop === "border-left" || prop === "border-inline-start") sides = ["left"];
      else if (prop === "border-right" || prop === "border-inline-end") sides = ["right"];
      else if (prop === "border-block") sides = ["top", "bottom"];
      else if (prop === "border-inline") sides = ["left", "right"];
      for (const s of sides) { set("border-" + s + "-width", o.w); set("border-" + s + "-style", o.s); set("border-" + s + "-color", o.c); }
      return;
    }
    case "border-width": case "border-style": case "border-color": {
      const b = box4(splitWs(v)), k = prop.slice(7);
      SIDES.forEach((s, i) => set("border-" + s + "-" + k, b[i]));
      return;
    }
    case "border-radius": {
      const b = box4(splitWs(v.split("/")[0].trim()));
      CORNERS.forEach((c, i) => set("border-" + c + "-radius", b[i]));
      return;
    }
    case "background": {
      let color = "transparent";
      const images = [];
      for (const layer of splitTop(v, ",")) {
        for (const t of splitWs(layer.trim())) {
          if (/^(?:repeating-)?(?:linear|radial|conic)-gradient\(/i.test(t) || /^url\(/i.test(t)) images.push(t);
          else if (t.toLowerCase() === "none") continue;
          else if (parseColor(t, "#FF000000", false) !== null || /^(?:rgb|rgba|hsl|hsla|oklch|oklab|color-mix|light-dark|color)\(/i.test(t) || t[0] === "#") color = t;
        }
      }
      set("background-color", color);
      set("background-image", images.length ? images.join(", ") : "none");
      return;
    }
    case "font": {
      const t = splitWs(v);
      let style = "normal", weight = "normal", sz = null, lh = "normal", k = 0;
      for (; k < t.length; k++) {
        const l = t[k].toLowerCase();
        if (l === "normal" || l === "small-caps") continue;
        if (l === "italic" || l === "oblique") { style = l; continue; }
        if (l === "bold" || l === "bolder" || l === "lighter" || /^(?:[1-9]\d\d|1000)$/.test(l)) { weight = l; continue; }
        const parts = t[k].split("/");
        sz = parts[0];
        if (parts.length > 1 && parts[1]) lh = parts[1];
        else if (t[k + 1] === "/") { lh = t[k + 2] || "normal"; k += 2; }
        else if (t[k + 1] && t[k + 1][0] === "/") { lh = t[k + 1].slice(1); k += 1; }
        k++;
        break;
      }
      if (sz === null) return;
      set("font-style", style); set("font-weight", weight); set("font-size", sz); set("line-height", lh);
      set("font-family", t.slice(k).join(" "));
      return;
    }
    case "flex": {
      const t = splitWs(v.toLowerCase());
      if (t[0] === "none") { set("flex-grow", "0"); set("flex-shrink", "0"); set("flex-basis", "auto"); return; }
      if (t[0] === "auto") { set("flex-grow", "1"); set("flex-shrink", "1"); set("flex-basis", "auto"); return; }
      if (t[0] === "initial") { set("flex-grow", "0"); set("flex-shrink", "1"); set("flex-basis", "auto"); return; }
      let grow = "1", shrink = "1", basis = "0%";
      const nums = t.filter((x) => /^[\d.]+$/.test(x));
      const lens = t.filter((x) => !/^[\d.]+$/.test(x));
      if (nums.length > 0) grow = nums[0];
      if (nums.length > 1) shrink = nums[1];
      if (lens.length) basis = lens[0];
      else if (nums.length === 3) basis = nums[2] + "px";
      set("flex-grow", grow); set("flex-shrink", shrink); set("flex-basis", basis);
      return;
    }
    case "flex-flow": {
      for (const x of splitWs(v.toLowerCase())) {
        if (x === "wrap" || x === "nowrap" || x === "wrap-reverse") set("flex-wrap", x); else set("flex-direction", x);
      }
      return;
    }
    case "gap": {
      const t = splitWs(v);
      set("row-gap", t[0]); set("column-gap", t.length > 1 ? t[1] : t[0]);
      return;
    }
    case "overflow": {
      const t = splitWs(v);
      set("overflow-x", t[0]); set("overflow-y", t.length > 1 ? t[1] : t[0]);
      return;
    }
    case "text-decoration": {
      const line = splitWs(v.toLowerCase()).filter((x) => x === "underline" || x === "line-through" || x === "overline" || x === "none");
      set("text-decoration-line", line.length ? line.join(" ") : "none");
      return;
    }
    case "place-items": case "place-content": case "place-self": {
      const t = splitWs(v), base = prop.slice(6);
      set("align-" + base, t[0]); set("justify-" + base, t.length > 1 ? t[1] : t[0]);
      return;
    }
    case "list-style": {
      const t = splitWs(v.toLowerCase());
      set("list-style-type", t.indexOf("none") >= 0 ? "none" : (t.find((x) => /^(disc|circle|square|decimal|[a-z-]+)$/.test(x) && x !== "inside" && x !== "outside") || "disc"));
      return;
    }
    default:
      set(ALIAS[prop] || prop, v);
  }
}

function applyDecl(p, parentP, prop, value) {
  const lv = value.toLowerCase();
  if (lv === "inherit" || lv === "initial" || lv === "unset" || lv === "revert" || lv === "revert-layer") {
    const keys = LONG[prop] || [ALIAS[prop] || prop];
    for (const k of keys) {
      if (lv === "inherit" || (lv === "unset" && INHERITED_SET.has(k))) {
        const pv = parentP[k];
        if (pv === undefined) delete p[k]; else p[k] = pv;
      } else delete p[k];
    }
    return;
  }
  expand(prop, value, (k, val) => { p[k] = val; });
}

function parseDeclText(text) {
  const out = [];
  for (const part of splitTop(text, ";")) {
    const k = part.indexOf(":");
    if (k < 0) continue;
    let prop = part.slice(0, k).trim();
    if (!prop) continue;
    if (prop.charCodeAt(0) !== 45 || prop.charCodeAt(1) !== 45) prop = prop.toLowerCase();
    let value = part.slice(k + 1).trim();
    let imp = false;
    const im = /\s*!\s*important\s*$/i.exec(value);
    if (im) { imp = true; value = value.slice(0, im.index); }
    if (value === "" && prop.slice(0, 2) !== "--") continue;
    out.push({ prop, value, imp });
  }
  return out;
}

let parsed = null;

/**
 * The sheets as rules, indexed by the id, class or tag of each selector's rightmost compound.
 * Parsed once for the same sheet texts, width and scheme. env: {width, scheme}.
 */
export function parse(sheets, env) {
  if (parsed && parsed.width === env.width && parsed.scheme === env.scheme && parsed.sheets.length === sheets.length && parsed.sheets.every((s, i) => s === sheets[i])) return parsed.rules;
  const reports = newReports();
  const st = { entries: [], byId: new Map(), byClass: new Map(), byTag: new Map(), universal: [], pseudo: [], layers: new Map(), order: 0, reports, env };
  const rules = { byId: st.byId, byClass: st.byClass, byTag: st.byTag, universal: st.universal, pseudo: st.pseudo, reports, layerCount: 0 };
  parseSheet(UA, st, -2);
  for (const sheet of sheets) parseSheet(String(sheet), st, -1);
  rules.layerCount = st.layers.size;
  parsed = { sheets: sheets.slice(), width: env.width, scheme: env.scheme, rules };
  return rules;
}

function parseSheet(text, st, baseLayer) {
  const src = text.replace(/\/\*[\s\S]*?\*\//g, "");
  const n = src.length;
  let i = 0;
  const report = (what, sel) => st.reports.add(what, sel);

  const skipWs = () => { while (i < n && isWs(src.charCodeAt(i))) i++; };
  const scanTo = () => {
    let d = 0, q = "";
    for (let j = i; j < n; j++) {
      const c = src[j];
      if (q) { if (c === "\\") j++; else if (c === q) q = ""; continue; }
      if (c === '"' || c === "'") { q = c; continue; }
      if (c === "(" || c === "[") d++;
      else if (c === ")" || c === "]") d--;
      else if (d <= 0 && (c === ";" || c === "{" || c === "}")) return j;
    }
    return n;
  };
  const skipBlock = (open) => {
    let d = 0, q = "";
    for (let j = open; j < n; j++) {
      const c = src[j];
      if (q) { if (c === "\\") j++; else if (c === q) q = ""; continue; }
      if (c === '"' || c === "'") q = c;
      else if (c === "{") d++;
      else if (c === "}") { d--; if (d === 0) { i = j + 1; return; } }
    }
    i = n;
  };

  const layerIndex = (name) => {
    if (!st.layers.has(name)) st.layers.set(name, st.layers.size);
    return st.layers.get(name);
  };

  const resolveSelectors = (prelude, parent) => {
    const parts = splitTop(prelude, ",").map((s) => s.trim()).filter(Boolean);
    if (!parent) return parts;
    const simple = splitTop(parent, ",").length === 1;
    const par = simple ? parent : ":is(" + parent + ")";
    return parts.map((p) => (p.indexOf("&") >= 0 ? p.split("&").join(par) : par + " " + p));
  };

  const register = (sels, rule, active) => {
    if (!active) return;
    for (const sel of sels) addEntry(sel, rule, st);
  };

  const block = (ctx) => {
    const decls = [];
    for (;;) {
      skipWs();
      if (i >= n) return decls;
      if (src[i] === "}") { i++; return decls; }
      if (src[i] === ";") { i++; continue; }
      const j = scanTo();
      const c = src[j];
      const prelude = src.slice(i, j).trim();
      if (src[i] === "@") { atRule(prelude, j, ctx, decls); continue; }
      if (c === "{") {
        i = j + 1;
        const sels = resolveSelectors(prelude, ctx.sel);
        const rule = { normal: [], imp: [], order: st.order++, layer: ctx.layer };
        register(sels, rule, ctx.active);
        const own = block({ sel: sels.join(", "), layer: ctx.layer, active: ctx.active, top: false });
        for (const d of own) (d.imp ? rule.imp : rule.normal).push([d.prop, d.value]);
        continue;
      }
      i = c === ";" ? j + 1 : j;
      if (ctx.top) continue;
      for (const d of parseDeclText(prelude)) decls.push(d);
    }
  };

  const atRule = (prelude, j, ctx) => {
    const m = /^@([\w-]+)\s*([\s\S]*)$/.exec(prelude);
    const name = m ? m[1].toLowerCase() : "";
    const rest = m ? m[2].trim() : "";
    const opens = src[j] === "{";
    if (!opens) {
      i = src[j] === ";" ? j + 1 : j;
      if (name === "import") report("@import", rest);
      else if (name === "layer") for (const l of rest.split(",")) { const nm = l.trim(); if (nm) layerIndex(nm); }
      return;
    }
    switch (name) {
      case "media": case "supports": case "layer": case "container": case "scope": {
        if (name === "container" || name === "scope") { report("@" + name, rest); skipBlock(j); return; }
        i = j + 1;
        let active = ctx.active, layer = ctx.layer;
        if (name === "media") active = active && mediaMatches(rest, st.env, (w) => report(w, ""));
        if (name === "layer") layer = layerIndex(rest || "\u0000anonymous" + st.order);
        if (ctx.sel) {
          // inside a style rule: its declarations apply to that rule's selector
          const rule = { normal: [], imp: [], order: st.order++, layer };
          register(splitTop(ctx.sel, ",").map((s) => s.trim()), rule, active);
          const own = block({ sel: ctx.sel, layer, active, top: false });
          for (const d of own) (d.imp ? rule.imp : rule.normal).push([d.prop, d.value]);
        } else block({ sel: null, layer, active, top: true });
        return;
      }
      case "font-face": case "keyframes": case "-webkit-keyframes": case "starting-style": case "counter-style": case "font-feature-values": case "page": case "view-transition":
        skipBlock(j); return;
      default:
        report("@" + name, rest);
        skipBlock(j);
    }
  };

  block({ sel: null, layer: baseLayer, active: true, top: true });
  // a stray closing brace must not hide the rest of the sheet
  while (i < n) block({ sel: null, layer: baseLayer, active: true, top: true });
}

function addEntry(sel, rule, st) {
  let s = sel.trim();
  if (!s) return;
  let pseudo = null;
  const pm = /::?(before|after|placeholder)\s*$/i.exec(s);
  if (pm) {
    pseudo = pm[1].toLowerCase();
    s = s.slice(0, pm.index).trim();
    if (!s || /[>+~]$/.test(s)) s += "*";
  } else {
    const em = /::([\w-]+)(?:\([^)]*\))?\s*$/.exec(s);
    if (em) {
      if (!SILENT_PSEUDO.test(em[1].toLowerCase())) st.reports.add("pseudo-element ::" + em[1], sel);
      return;
    }
  }
  const spec = specificity(s);
  s = s.replace(INTERACTION, ":not(*)").replace(/:popover-open(?![\w-])/g, "[data-popover-open]").replace(/:(?:any-link|link)(?![\w-])/g, ":is(a,area)[href]");
  const entry = { sel: s, spec, rule, pseudo, dead: false, stamp: 0 };
  if (pseudo) { st.pseudo.push(entry); return; }
  for (const key of keysOf(s)) {
    if (key === "*") st.universal.push(entry);
    else {
      const map = key[0] === "#" ? st.byId : key[0] === "." ? st.byClass : st.byTag;
      const k = key[0] === "#" || key[0] === "." ? key.slice(1) : key;
      const list = map.get(k);
      if (list) list.push(entry); else map.set(k, [entry]);
    }
  }
}

// ---------------------------------------------------------------- the cascade

let STAMP = 0;
const BIG = 1e9;

function subst(text, get, depth) {
  if (text.indexOf("var(") < 0) return text;
  if ((depth || 0) > 16) return null;
  let out = "", i = 0;
  for (;;) {
    const k = text.indexOf("var(", i);
    if (k < 0) return out + text.slice(i);
    const e = matchParen(text, k + 3);
    const inner = text.slice(k + 4, e);
    const parts = splitTop(inner, ",");
    const name = parts[0].trim();
    let v = get(name);
    if (v === undefined) {
      if (parts.length < 2) return null;
      v = subst(inner.slice(inner.indexOf(",") + 1).trim(), get, (depth || 0) + 1);
      if (v === null) return null;
    }
    out += text.slice(i, k) + v;
    i = e + 1;
  }
}

function lightDark(text, dark) {
  let k;
  while ((k = text.indexOf("light-dark(")) >= 0) {
    const e = matchParen(text, k + 10);
    const args = splitTop(text.slice(k + 11, e), ",");
    text = text.slice(0, k) + (args[dark ? 1 : 0] || "").trim() + text.slice(e + 1);
  }
  return text;
}

function resolve(raw, scope) {
  let r = scope.cache.get(raw);
  if (r === undefined) {
    r = raw;
    if (r.indexOf("var(") >= 0) r = subst(r, (n) => scope.vars[n]);
    if (r !== null && r.indexOf("light-dark(") >= 0) r = lightDark(r, scope.dark);
    scope.cache.set(raw, r);
  }
  return r;
}

const FONT_KEYWORDS = { "xx-small": 9, "x-small": 10, small: 13, medium: 16, large: 18, "x-large": 24, "xx-large": 32, "xxx-large": 48 };

function fontSize(v, parentFs) {
  if (v === undefined) return parentFs;
  const l = v.toLowerCase();
  if (FONT_KEYWORDS[l] !== undefined) return FONT_KEYWORDS[l];
  if (l === "smaller") return parentFs / 1.2;
  if (l === "larger") return parentFs * 1.2;
  const px = length(l, { fs: parentFs, basis: parentFs });
  return px === null || px < 0 ? parentFs : px;
}

/** A styler over parsed rules: style(el), pseudo(el, 'before'|'after'|'placeholder'). env: {width, scheme}. */
export function createStyler(rules, env) {
  const memo = new Map();
  const pseudoMemo = new Map();
  const L = rules.layerCount;
  const envDark = env.scheme === "dark";
  const ROOT = { p: Object.create(null), fs: 16, scope: { vars: Object.create(null), dark: false, cache: new Map() } };

  const lname = (el) => el.localName || String(el.tagName).toLowerCase();

  const sorted = (items) => items.sort((a, b) => a.imp - b.imp || a.lk - b.lk || a.spec - b.spec || a.order - b.order);

  const pushItems = (items, entry) => {
    const rule = entry.rule;
    const lr = rule.layer === -2 ? 0 : rule.layer === -1 ? L + 1 : rule.layer + 1;
    if (rule.normal.length) items.push({ imp: 0, lk: lr, spec: entry.spec, order: rule.order, decls: rule.normal });
    if (rule.imp.length) items.push({ imp: 1, lk: L + 1 - lr, spec: entry.spec, order: rule.order, decls: rule.imp });
  };

  const matches = (el, entry) => {
    try { return el.matches(entry.sel); } catch (_) {
      entry.dead = true;
      rules.reports.add("selector not understood", entry.sel);
      return false;
    }
  };

  function gather(el) {
    const stamp = ++STAMP;
    const hits = [];
    const test = (list) => {
      if (!list) return;
      for (const e of list) {
        if (e.stamp === stamp || e.dead) continue;
        e.stamp = stamp;
        if (matches(el, e)) hits.push(e);
      }
    };
    const id = el.getAttribute("id");
    if (id) test(rules.byId.get(id));
    const cls = el.getAttribute("class");
    if (cls) for (const c of cls.split(/\s+/)) if (c) test(rules.byClass.get(c));
    test(rules.byTag.get(lname(el)));
    test(rules.universal);
    const items = [];
    for (const e of hits) pushItems(items, e);
    const inline = el.getAttribute("style");
    if (inline) {
      const normal = [], imp = [];
      for (const d of parseDeclText(inline)) (d.imp ? imp : normal).push([d.prop, d.value]);
      if (normal.length) items.push({ imp: 0, lk: L + 1, spec: BIG, order: BIG, decls: normal });
      if (imp.length) items.push({ imp: 1, lk: 0, spec: BIG, order: BIG, decls: imp });
    }
    return sorted(items);
  }

  function scopeFor(items, ps) {
    let own = null;
    for (const it of items) for (const d of it.decls) if (d[0].charCodeAt(0) === 45 && d[0].charCodeAt(1) === 45) (own = own || Object.create(null))[d[0]] = d[1];
    let scope = ps.scope;
    if (own) {
      const vars = Object.create(ps.scope.vars);
      const done = new Set(), visiting = new Set();
      const get = (name) => {
        if (!(name in own)) return ps.scope.vars[name];
        if (done.has(name)) return vars[name];
        if (visiting.has(name)) return ps.scope.vars[name];
        visiting.add(name);
        const r = subst(own[name], get);
        visiting.delete(name);
        done.add(name);
        vars[name] = r === null ? undefined : r;
        return vars[name];
      };
      for (const name in own) get(name);
      scope = { vars, dark: ps.scope.dark, cache: new Map() };
    }
    let scheme = null;
    for (const it of items) for (const d of it.decls) if (d[0] === "color-scheme") scheme = d[1];
    if (scheme !== null) {
      const v = resolve(scheme, scope);
      if (v !== null) {
        const words = v.toLowerCase().split(/\s+/);
        const hasDark = words.indexOf("dark") >= 0, hasLight = words.indexOf("light") >= 0;
        const dark = hasDark && !hasLight ? true : hasLight && !hasDark ? false : hasDark && hasLight ? envDark : false;
        if (dark !== scope.dark) scope = { vars: scope.vars, dark, cache: new Map() };
      }
    }
    return scope;
  }

  function style(el) {
    let s = memo.get(el);
    if (s) return s;
    const par = el.parentElement;
    const ps = par ? style(par) : ROOT;
    const items = gather(el);
    const scope = scopeFor(items, ps);
    const p = Object.create(null);
    for (const k of INHERITED) { const v = ps.p[k]; if (v !== undefined) p[k] = v; }
    for (const it of items) {
      for (const d of it.decls) {
        if (d[0].charCodeAt(0) === 45 && d[0].charCodeAt(1) === 45) continue;
        const v = resolve(d[1], scope);
        if (v === null) continue;
        applyDecl(p, ps.p, d[0], v.trim());
      }
    }
    const fs = fontSize(p["font-size"], ps.fs);
    p["font-size"] = fs + "px";
    const lh = p["line-height"];
    if (lh !== undefined && lh !== "normal" && !/^[\d.]+$/.test(lh)) {
      const px = length(lh, { fs, basis: fs });
      if (px === null) delete p["line-height"]; else p["line-height"] = px + "px";
    }
    const ls = p["letter-spacing"];
    if (ls !== undefined && ls !== "normal") {
      const px = length(ls, { fs });
      p["letter-spacing"] = px === null ? "normal" : px + "px";
    }
    s = { p, fs, scope, el };
    memo.set(el, s);
    return s;
  }

  // The declarations a ::before, ::after or ::placeholder of the element gets, as {prop: value}, or null.
  function pseudo(el, which) {
    if (!rules.pseudo.length) return null;
    const key = which;
    let byEl = pseudoMemo.get(key);
    if (!byEl) { byEl = new Map(); pseudoMemo.set(key, byEl); }
    if (byEl.has(el)) return byEl.get(el);
    const items = [];
    let any = false;
    for (const e of rules.pseudo) {
      if (e.pseudo !== which || e.dead) continue;
      if (matches(el, e)) { pushItems(items, e); any = true; }
    }
    let out = null;
    if (any) {
      sorted(items);
      const scope = style(el).scope;
      out = {};
      for (const it of items) for (const d of it.decls) {
        const v = resolve(d[1], scope);
        if (v !== null) out[d[0]] = v.trim();
      }
    }
    byEl.set(el, out);
    return out;
  }

  return { style, pseudo, reports: rules.reports };
}
