// The compiler of the Android terminal: a live DOM (omnishell's interpreter over linkedom) and the
// app's CSS in, a DivKit card (native views, no WebView) out.
//
//   const {card, unsupported} = compile(document, {sheets, width: 411, scheme: "light"});
//
// `card` is DivKit DivData: every element that draws gets a stable id (idOf) that DivKit keeps as
// the view's tag; every form field has a variable v_<id>. `unsupported` lists, deduplicated, what
// was seen and has no peer on Android, as {what, selector}: nothing is dropped silently. The CSS
// engine is css.js. Plain ES, no globals beyond the language's own, so it runs in QuickJS after
// SES lockdown.
import { createStyler, length, parse, parseColor, size, splitTop, splitWs } from "./css.js";

// ---------------------------------------------------------------- identity

const ids = new WeakMap();
let nextId = 1;
let live = new Map();

/** The element's stable id, `e<N>`: the same for the same element across compiles. */
export function idOf(el) {
  let id = ids.get(el);
  if (!id) { id = "e" + nextId++; ids.set(el, id); }
  return id;
}

/** The element an id names in the last compile, or null. */
export function elementOf(id) {
  return live.get(id) || null;
}

// ---------------------------------------------------------------- small helpers

const lname = (el) => el.localName || String(el.tagName).toLowerCase();
const attr = (el, name) => el.getAttribute(name);
const has = (el, name) => el.hasAttribute(name);
const isBlank = (s) => /^[ \t\r\n\f]*$/.test(s);
const round = (n) => Math.round(n);

// DivKit reads "@{" as an expression in any text.
const lit = (s) => (String(s).indexOf("@{") >= 0 ? String(s).split("\\").join("\\\\").split("@{").join("\\@{") : String(s));

const SKIP_TAGS = new Set(["head", "script", "style", "template", "meta", "link", "title", "base", "noscript", "option", "optgroup", "datalist", "source", "track", "param", "area", "map", "colgroup", "col"]);
const NO_PEER = { svg: "inline svg", canvas: "canvas", video: "video", audio: "audio", iframe: "iframe", object: "object", embed: "embed", math: "math" };
const REPLACED = new Set(["img", "input", "textarea", "select", "button", "svg", "video", "audio", "canvas", "iframe", "object", "embed", "hr", "picture", "progress", "meter"]);

function desc(el) {
  let s = lname(el);
  const id = attr(el, "id");
  if (id) s += "#" + id;
  const cls = attr(el, "class");
  if (cls) s += "." + cls.trim().split(/\s+/).slice(0, 2).join(".");
  return s;
}

function resolveUrl(src, base) {
  if (!base || /^[a-z][a-z0-9+.-]*:/i.test(src)) return src;
  const m = /^([a-z][a-z0-9+.-]*:)(\/\/[^/?#]*)?([^?#]*)/i.exec(base);
  if (!m) return src;
  if (src.slice(0, 2) === "//") return m[1] + src;
  const origin = m[1] + (m[2] || "");
  if (src[0] === "/") return origin + src;
  if (src[0] === "?" || src[0] === "#") return origin + m[3] + src;
  const dir = m[3].slice(0, m[3].lastIndexOf("/") + 1) || "/";
  const out = [];
  for (const seg of (dir + src).split("/")) {
    if (seg === "..") out.pop();
    else if (seg !== ".") out.push(seg);
  }
  return origin + out.join("/");
}

// ---------------------------------------------------------------- compile state

function newState(document, opts, styler, rules) {
  const seen = new Map();
  const reportSeen = new Set();
  const reports = [];
  return {
    document, styler, rules, width: opts.width, scheme: opts.scheme, base: document.baseURI || "",
    style: styler.style, seen, vars: [], reports,
    drawnMemo: new Map(), phrasingMemo: new Map(), tapMemo: new Map(),
    rep(what, selector) {
      const k = what + "\u0001" + selector;
      if (!reportSeen.has(k)) { reportSeen.add(k); reports.push({ what, selector }); }
    },
    reg(el) { const id = idOf(el); seen.set(id, el); return id; },
    noBg: null,
    edges: new Map(),
    bevels: new Map(),
  };
}

// ---------------------------------------------------------------- what is drawn

function drawn(el, C) {
  let v = C.drawnMemo.get(el);
  if (v === undefined) { v = computeDrawn(el, C); C.drawnMemo.set(el, v); }
  return v;
}

function computeDrawn(el, C) {
  const tag = lname(el);
  if (SKIP_TAGS.has(tag) || has(el, "hidden")) return false;
  if (tag === "input" && (attr(el, "type") || "").toLowerCase() === "hidden") return false;
  if (tag === "dialog" && !has(el, "open")) return false;
  if (has(el, "popover") && !has(el, "data-popover-open")) return false;
  const par = el.parentElement;
  if (par && lname(par) === "details" && !has(par, "open") && tag !== "summary") return false;
  const p = C.style(el).p;
  if (p.display === "none") return false;
  if (p.visibility === "hidden" || p.visibility === "collapse") return false;
  if (NO_PEER[tag]) { C.rep(NO_PEER[tag], desc(el)); return false; }
  return true;
}

function layoutKind(st) {
  const d = (st.p.display || "inline").split(/\s+/)[0];
  if (d === "flex" || d === "inline-flex") return "flex";
  if (d === "grid" || d === "inline-grid") return "grid";
  if (d === "contents") return "contents";
  return "block";
}
const inlineLevel = (st) => /^inline/.test(st.p.display || "inline");

function isTappable(el) {
  const tag = lname(el);
  if (has(el, "disabled") || attr(el, "aria-disabled") === "true") return false;
  for (let a = el.parentElement; a; a = a.parentElement) if (lname(a) === "fieldset" && has(a, "disabled")) return false;
  if (tag === "button" || tag === "summary") return true;
  if (tag === "a" && has(el, "href")) return true;
  if (tag === "input") return /^(checkbox|radio|submit|button|reset|image)$/.test((attr(el, "type") || "").toLowerCase());
  const role = attr(el, "role");
  return has(el, "data-route") || has(el, "data-on-click") || has(el, "onclick") || role === "button" || role === "link";
}

// Whether an element is text that flows in a line: inline, and all it holds is text and inline elements.
function isPhrasing(el, C) {
  let v = C.phrasingMemo.get(el);
  if (v !== undefined) return v;
  v = true;
  const tag = lname(el);
  if (REPLACED.has(tag)) v = false;
  else if ((C.style(el).p.display || "inline") !== "inline") v = false;
  else if (tag !== "br") {
    for (const n of el.childNodes) {
      if (n.nodeType === 1 && drawn(n, C) && !isPhrasing(n, C)) { v = false; break; }
    }
  }
  C.phrasingMemo.set(el, v);
  return v;
}

// The one drawn child of an element that is all it holds, when that is a tappable inline element.
function loneTapChild(el, C) {
  let only = null;
  for (const n of el.childNodes) {
    if (n.nodeType === 3) { if (!isBlank(n.data)) return null; continue; }
    if (n.nodeType !== 1 || !drawn(n, C)) continue;
    if (only) return null;
    only = n;
  }
  return only && isTappable(only) ? only : null;
}

// ---------------------------------------------------------------- colours and text style

const colorOf = (st) => {
  if (st.argb === undefined) st.argb = parseColor(st.p.color || (st.scope.dark ? "#FFFFFF" : "#000000"), null, st.scope.dark) || (st.scope.dark ? "#FFFFFFFF" : "#FF000000");
  return st.argb;
};
const colorProp = (st, name) => {
  const v = st.p[name];
  return v === undefined ? null : parseColor(v, colorOf(st), st.scope.dark);
};
const opaque = (c) => c && c !== "#00000000" && c.slice(1, 3).toUpperCase() !== "00";

function weightOf(st) {
  const w = (st.p["font-weight"] || "normal").toLowerCase();
  if (w === "normal") return 400;
  if (w === "bold" || w === "bolder") return 700;
  if (w === "lighter") return 300;
  const n = parseFloat(w);
  return isNaN(n) ? 400 : Math.max(100, Math.min(900, round(n / 100) * 100));
}
const weightName = (w) => (w <= 300 ? "light" : w < 500 ? "regular" : w < 600 ? "medium" : "bold");
const mono = (st) => /(^|[\s,'"])(monospace|ui-monospace|courier|menlo|consolas|monaco)/i.test(st.p["font-family"] || "");
const lines = (st) => st.p["text-decoration-line"] || "none";

function transform(s, st) {
  const t = st.p["text-transform"];
  if (t === "uppercase") return s.toUpperCase();
  if (t === "lowercase") return s.toLowerCase();
  if (t === "capitalize") return s.replace(/(^|\s)(\S)/g, (_m, a, b) => a + b.toUpperCase());
  return s;
}

function lineHeight(st) {
  const lh = st.p["line-height"];
  if (lh === undefined || lh === "normal") return null;
  if (/^[\d.]+$/.test(lh)) return round(parseFloat(lh) * st.fs);
  const px = parseFloat(lh);
  return isNaN(px) ? null : round(px);
}

function textProps(st) {
  const o = { font_size: round(st.fs), text_color: colorOf(st) };
  const w = weightOf(st);
  if (w !== 400) { o.font_weight = weightName(w); o.font_weight_value = w; }
  const lh = lineHeight(st);
  if (lh !== null) o.line_height = lh;
  const ls = parseFloat(st.p["letter-spacing"]);
  if (!isNaN(ls) && ls !== 0) o.letter_spacing = Math.round(ls * 100) / 100;
  if (mono(st)) o.font_family = "monospace";
  const ta = st.p["text-align"];
  if (ta === "center") o.text_alignment_horizontal = "center";
  else if (ta === "right" || ta === "end") o.text_alignment_horizontal = "right";
  else if (ta === "left") o.text_alignment_horizontal = "left";
  const l = lines(st);
  if (l.indexOf("underline") >= 0) o.underline = "single";
  if (l.indexOf("line-through") >= 0) o.strike = "single";
  if (st.p["white-space"] === "nowrap") o.max_lines = 1;
  return o;
}

// The range fields where an inline element's style differs from the style around it.
function diffRange(cs, ps) {
  const r = {};
  if (round(cs.fs) !== round(ps.fs)) r.font_size = round(cs.fs);
  const w = weightOf(cs);
  if (w !== weightOf(ps)) { r.font_weight = weightName(w); r.font_weight_value = w; }
  if (colorOf(cs) !== colorOf(ps)) r.text_color = colorOf(cs);
  const ul = lines(cs).indexOf("underline") >= 0, st = lines(cs).indexOf("line-through") >= 0;
  if (ul !== (lines(ps).indexOf("underline") >= 0)) r.underline = ul ? "single" : "none";
  if (st !== (lines(ps).indexOf("line-through") >= 0)) r.strike = st ? "single" : "none";
  if (cs.p["letter-spacing"] !== ps.p["letter-spacing"]) { const ls = parseFloat(cs.p["letter-spacing"]); if (!isNaN(ls)) r.letter_spacing = ls; }
  if (mono(cs) !== mono(ps)) r.font_family = mono(cs) ? "monospace" : "sans-serif";
  const bg = colorProp(cs, "background-color");
  if (opaque(bg)) r.background = { type: "solid", color: bg };
  return r;
}

// ---------------------------------------------------------------- text runs

function pseudoText(el, which, C) {
  const pr = C.styler.pseudo(el, which);
  if (!pr || pr.content === undefined) return "";
  const c = pr.content.trim();
  if (c === "none" || c === "normal" || c === "") return "";
  let out = "";
  for (const t of splitWs(c)) {
    const q = /^(["'])([\s\S]*)\1$/.exec(t);
    if (q) out += q[2].replace(/\\([0-9a-f]{1,6})\s?/gi, (_m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/\\(.)/g, "$1");
    else if (/^attr\(/i.test(t)) out += attr(el, t.slice(5, -1).trim()) || "";
    else C.rep("content: " + t, desc(el) + "::" + which);
  }
  return out;
}

// The text and the ranges of a run of text nodes and inline elements. `base` is the style around
// them; `owner` the element whose own ::before and ::after wrap the run (none for a part of one).
function buildRun(nodes, base, C, owner, prefix) {
  let out = prefix || "";
  const ranges = [];
  const add = (s, st) => {
    s = transform(s, st);
    const ws = st.p["white-space"] || "normal";
    if (ws === "pre" || ws === "pre-wrap" || ws === "break-spaces") { out += s; return; }
    s = ws === "pre-line" ? s.replace(/[ \t\r\f]*\n[ \t\r\f]*/g, "\n").replace(/[ \t\r\f]+/g, " ") : s.replace(/[ \t\r\n\f]+/g, " ");
    if (s[0] === " " && (out === "" || out[out.length - 1] === " " || out[out.length - 1] === "\n")) s = s.slice(1);
    out += s;
  };
  const walk = (list, st) => {
    for (const n of list) {
      if (n.nodeType === 3) { add(n.data, st); continue; }
      if (n.nodeType !== 1 || !drawn(n, C)) continue;
      if (lname(n) === "br") { out = out.replace(/ +$/, "") + "\n"; continue; }
      const cs = C.style(n);
      checkProps(n, cs, C, st);
      const start = out.length;
      add(pseudoText(n, "before", C), cs);
      walk(n.childNodes, cs);
      add(pseudoText(n, "after", C), cs);
      const r = diffRange(cs, st);
      if (isTappable(n)) { const id = C.reg(n); r.actions = [{ log_id: id, url: "pronto://tap/" + id }]; }
      if (Object.keys(r).length && out.length > start) { r.start = start; r.end = out.length; ranges.push(r); }
    }
  };
  if (owner) add(pseudoText(owner, "before", C), base);
  walk(nodes, base);
  if (owner) add(pseudoText(owner, "after", C), base);
  const trimmed = out.replace(/[ \n]+$/, "");
  const final = [];
  for (const r of ranges) {
    r.end = Math.min(r.end, trimmed.length);
    if (r.end > r.start) final.push(r);
  }
  return { text: trimmed, ranges: final };
}

// ---------------------------------------------------------------- the box: size, spacing, paint

function parseShadow(v, st) {
  if (!v || v === "none") return null;
  for (const layer of splitTop(v, ",")) {
    const toks = splitWs(layer.trim());
    if (toks.indexOf("inset") >= 0) continue;
    const nums = [];
    let color = null;
    for (const t of toks) {
      const n = length(t, { fs: st.fs });
      if (n !== null && /^[+-]?[\d.]/.test(t)) nums.push(n);
      else color = t;
    }
    if (nums.length < 2) continue;
    const c = color ? parseColor(color, colorOf(st), st.scope.dark) : colorOf(st);
    if (!c) continue;
    const a = parseInt(c.slice(1, 3), 16) / 255;
    if (a === 0) continue;
    return { alpha: Math.round(a * 100) / 100, blur: round(nums[2] || 0), color: "#" + c.slice(3), offset: { x: round(nums[0]), y: round(nums[1]) } };
  }
  return null;
}

function gradientOf(str, st, C, el) {
  const m = /^(repeating-)?linear-gradient\(([\s\S]*)\)$/i.exec(str.trim());
  if (!m) { C.rep(str.split("(")[0] + " background", desc(el)); return null; }
  if (m[1]) C.rep("repeating-linear-gradient", desc(el));
  const args = splitTop(m[2], ",").map((s) => s.trim());
  let css = 180;
  const first = args[0].toLowerCase();
  if (/^to\s/.test(first)) {
    const dir = { "to top": 0, "to top right": 45, "to right top": 45, "to right": 90, "to bottom right": 135, "to right bottom": 135, "to bottom": 180, "to bottom left": 225, "to left bottom": 225, "to left": 270, "to top left": 315, "to left top": 315 };
    css = dir[first] === undefined ? 180 : dir[first];
    args.shift();
  } else if (/^-?[\d.]+(deg|turn|rad|grad)$/.test(first)) {
    const v = parseFloat(first);
    css = /turn$/.test(first) ? v * 360 : /rad$/.test(first) ? (v * 180) / Math.PI : /grad$/.test(first) ? v * 0.9 : v;
    args.shift();
  }
  const stops = [];
  for (const a of args) {
    const toks = splitWs(a);
    let pos = null;
    const rest = [];
    for (const t of toks) { if (/^[\d.]+%$/.test(t)) pos = parseFloat(t) / 100; else rest.push(t); }
    const color = parseColor(rest.join(" "), colorOf(st), st.scope.dark);
    if (!color) return null;
    stops.push({ color, pos });
  }
  if (stops.length < 2) return null;
  // DivKit's angle runs counter-clockwise from left-to-right; CSS's clockwise from bottom-to-top.
  const angle = ((round(90 - css) % 360) + 360) % 360;
  if (stops.every((s) => s.pos === null)) return { type: "gradient", angle, colors: stops.map((s) => s.color) };
  if (stops[0].pos === null) stops[0].pos = 0;
  if (stops[stops.length - 1].pos === null) stops[stops.length - 1].pos = 1;
  for (let i = 1; i < stops.length - 1; i++) {
    if (stops[i].pos !== null) continue;
    let j = i;
    while (stops[j].pos === null) j++;
    const a = stops[i - 1].pos, b = stops[j].pos;
    for (let k = i; k < j; k++) stops[k].pos = a + ((b - a) * (k - i + 1)) / (j - i + 1);
  }
  return { type: "gradient", angle, color_map: stops.map((s) => ({ color: s.color, position: Math.max(0, Math.min(1, s.pos)) })) };
}

function backgroundOf(el, st, C) {
  const out = [];
  const color = colorProp(st, "background-color");
  if (opaque(color)) out.push({ type: "solid", color });
  const img = st.p["background-image"];
  if (img && img !== "none") {
    const layers = splitTop(img, ",").map((s) => s.trim()).reverse();
    for (const l of layers) {
      const u = /^url\(\s*(["']?)([\s\S]*?)\1\s*\)$/i.exec(l);
      if (u) {
        const bs = (st.p["background-size"] || "").toLowerCase();
        out.push({ type: "image", image_url: resolveUrl(u[2], C.base), scale: bs === "cover" ? "fill" : bs === "contain" ? "fit" : "no_scale" });
      } else {
        const g = gradientOf(l, st, C, el);
        if (g) out.push(g);
      }
    }
  }
  return out;
}

function borderOf(el, st, C, lctx) {
  const p = st.p;
  const side = (s) => {
    const style = p["border-" + s + "-style"];
    if (style === undefined || style === "none" || style === "hidden") return null;
    const wv = (p["border-" + s + "-width"] || "medium").toLowerCase();
    const w = wv === "thin" ? 1 : wv === "medium" ? 3 : wv === "thick" ? 5 : length(wv, lctx);
    if (w === null || w <= 0) return null;
    const c = parseColor(p["border-" + s + "-color"] || "currentcolor", colorOf(st), st.scope.dark);
    if (style !== "solid") C.rep("border-style: " + style, desc(el));
    return { w, c: c || colorOf(st) };
  };
  const sides = ["top", "right", "bottom", "left"].map(side);
  const present = sides.filter(Boolean);
  const border = {};
  let width = 0;
  if (present.length === 4 && sides.every((s) => s.w === sides[0].w && s.c === sides[0].c)) {
    width = sides[0].w;
    if (opaque(sides[0].c)) border.stroke = { color: sides[0].c, width: Math.max(1, round(width)) };
  } else if (present.length) {
    // a rule above or below alone is drawn as a separator beside the view (decorate)
    const lone = !sides[1] && !sides[3] && (!sides[0] || !sides[2] || (sides[0].w === sides[2].w && sides[0].c === sides[2].c));
    if (lone) C.edges.set(el, { top: sides[0], bottom: sides[2] });
    else if (present.length < 4) C.rep("border on some sides only", desc(el));
    else {
      width = Math.max(...present.map((s) => s.w));
      const [t, r, b, l] = sides;
      if (t.w === r.w && r.w === b.w && b.w === l.w && t.c === l.c && r.c === b.c && opaque(t.c) && opaque(b.c)) {
        // A bevel (a light edge above and left, a dark one below and right): DivKit has one stroke for all
        // four sides, so the view is framed by layers (see `bevel`), the box model unchanged.
        C.bevels.set(el, { light: t.c, dark: b.c, w: width });
      } else {
        // Anything else is drawn as one outline in the shadowed edge's colour, half the width, so the control
        // keeps its edge instead of vanishing into its surround.
        const edge = b || r || t || l;
        if (opaque(edge.c)) border.stroke = { color: edge.c, width: Math.max(1, round(width / 2)) };
        C.rep("border on some sides only (drawn as one outline)", desc(el));
      }
    }
  }
  const radius = ["top-left", "top-right", "bottom-right", "bottom-left"].map((c) => {
    const v = p["border-" + c + "-radius"];
    if (v === undefined) return 0;
    const pm = /^([\d.]+)%$/.exec(v);
    if (pm) return parseFloat(pm[1]) >= 50 ? 999 : (C.rep("border-radius: " + v, desc(el)), 0);
    const n = length(v, lctx);
    return n === null ? 0 : Math.min(999, round(n));
  });
  if (radius.every((r) => r === radius[0])) { if (radius[0]) border.corner_radius = radius[0]; }
  else border.corners_radius = { "top-left": radius[0], "top-right": radius[1], "bottom-right": radius[2], "bottom-left": radius[3] };
  const shadow = parseShadow(p["box-shadow"], st);
  if (shadow) { border.has_shadow = true; border.shadow = shadow; }
  return { border: Object.keys(border).length ? border : null, width };
}

function crossAlign(v) {
  switch (v) {
    case "center": return "center";
    case "flex-end": case "end": case "self-end": case "right": return "end";
    case "flex-start": case "start": case "self-start": case "left": return "start";
    case "baseline": return "baseline";
    default: return null; // stretch, normal, auto
  }
}

// The common fields of the view an element becomes, and what its children are told of it.
function outerBox(el, st, pctx, C, type, hint) {
  const p = st.p, fs = st.fs;
  const lctx = { fs, basis: pctx.avail, width: C.width };
  const sel = desc(el);
  const L = (name) => {
    const v = p[name];
    if (v === undefined) return 0;
    if (v === "auto") return "auto";
    const n = length(v, lctx);
    if (n === null) { C.rep(name + ": " + v, sel); return 0; }
    return n;
  };
  const mt = L("margin-top"), mr = L("margin-right"), mb = L("margin-bottom"), ml = L("margin-left");
  const auto = { t: mt === "auto", r: mr === "auto", b: mb === "auto", l: ml === "auto" };
  const num = (x) => (x === "auto" ? 0 : x);
  const m = { top: num(mt), right: num(mr), bottom: num(mb), left: num(ml) };
  const pad = { top: Math.max(0, L("padding-top")), right: Math.max(0, L("padding-right")), bottom: Math.max(0, L("padding-bottom")), left: Math.max(0, L("padding-left")) };
  const bd = borderOf(el, st, C, lctx);
  const bw = bd.width;
  const pads = { top: pad.top + bw, right: pad.right + bw, bottom: pad.bottom + bw, left: pad.left + bw };
  const padW = pads.left + pads.right, padH = pads.top + pads.bottom;
  const borderBox = (p["box-sizing"] || "").indexOf("border-box") === 0;
  const sctx = { fs, basis: pctx.avail, width: C.width };
  const kind = pctx.kind;
  const block = !inlineLevel(st);
  const fields = {};

  // --- width
  const availW = Math.max(0, pctx.avail - num(ml) - num(mr));
  let wpx = null, stretch = false, weight = null, alignH = null, shrink = false;
  const wv = p.width;
  if (wv !== undefined && wv !== "auto") {
    // A content-sized box is what DivKit's wrap_content is: the box takes its children's width, at the start.
    if (/^(max-content|min-content|fit-content(\(.*\))?)$/.test(wv.trim().toLowerCase())) shrink = true;
    else {
    const sz = size(wv, sctx);
    if (!sz) C.rep("width: " + wv, sel);
    else if (sz.pct === 100 && num(ml) === 0 && num(mr) === 0) stretch = true;
    else if (sz.px !== undefined) wpx = borderBox ? sz.px : sz.px + padW;
    else C.rep("width: " + wv, sel);
    }
  } else if (hint && hint.w !== undefined) wpx = hint.w + (borderBox ? 0 : padW);
  const grow = parseFloat(p["flex-grow"] || "0") || 0;
  const self = p["align-self"] && p["align-self"] !== "auto" ? p["align-self"] : null;
  const selfJ = p["justify-self"] && p["justify-self"] !== "auto" ? p["justify-self"] : null;
  if (wpx === null && !stretch && !shrink) {
    const control = type === "control";
    if (kind === "row") {
      const basis = p["flex-basis"];
      const bs = basis && basis !== "auto" && basis !== "content" ? size(basis, sctx) : null;
      if (bs && bs.px !== undefined && grow === 0) wpx = borderBox ? bs.px : bs.px + padW;
      else if (grow > 0 || control) { stretch = true; weight = grow > 0 ? grow : 1; }
    } else if (kind === "col" || kind === "grid") {
      const a = crossAlign(kind === "col" ? (pctx.g ? selfJ || pctx.ai : self || pctx.ai) : selfJ || pctx.ji);
      if (a === null || control) stretch = true;
      else alignH = a === "end" ? "right" : a === "center" ? "center" : "left";
    } else if (control) stretch = true;
    else if (block && type !== "image") stretch = true;
    else if (pctx.ta === "center" || pctx.ta === "right") alignH = pctx.ta;
  }
  if (kind === "row" && grow > 0 && wpx !== null && wv === undefined) { wpx = null; stretch = true; weight = grow; }
  let wrapMin = null, wrapMax = null;
  const maxv = p["max-width"];
  if (maxv && maxv !== "none") {
    const mx = size(maxv, sctx);
    if (mx && mx.px !== undefined) {
      const mpx = borderBox ? mx.px : mx.px + padW;
      if (stretch && weight === null) { if (availW > mpx) { wpx = mpx; stretch = false; } }
      else if (wpx !== null) wpx = Math.min(wpx, mpx);
      else if (!stretch) wrapMax = mpx;
    } else if (!mx) C.rep("max-width: " + maxv, sel);
  }
  const minv = p["min-width"];
  if (minv && minv !== "auto" && minv !== "0") {
    const mn = size(minv, sctx);
    if (mn && mn.px !== undefined && mn.px > 0) {
      const npx = borderBox ? mn.px : mn.px + padW;
      if (wpx !== null) wpx = Math.max(wpx, npx);
      else if (stretch) { if (availW < npx && weight === null) { wpx = npx; stretch = false; } }
      else wrapMin = npx;
    }
  }
  if (wpx !== null) {
    fields.width = { type: "fixed", value: round(wpx) };
    if (auto.l && auto.r) alignH = "center";
    else if (auto.l) alignH = "right";
  } else if (stretch) fields.width = weight !== null ? { type: "match_parent", weight } : { type: "match_parent" };
  else {
    const w = { type: "wrap_content" };
    if (wrapMin !== null) w.min_size = { value: round(wrapMin) };
    if (wrapMax !== null) { w.max_size = { value: round(wrapMax) }; w.constrained = true; }
    if (type === "image" && /^100%$/.test((p["max-width"] || "").trim())) w.constrained = true;
    fields.width = w;
  }
  if (alignH) fields.alignment_horizontal = alignH;
  const contentW = Math.max(0, (wpx !== null ? wpx : availW) - padW);

  // --- height
  let hpx = null, hMatch = false, hWeight = null;
  const hv = p.height;
  if (hv !== undefined && hv !== "auto") {
    const sz = size(hv, { fs, width: C.width });
    if (!sz) C.rep("height: " + hv, sel);
    else if (sz.pct === 100) hMatch = true;
    else if (sz.px !== undefined) hpx = borderBox ? sz.px : sz.px + padH;
    else C.rep("height: " + hv, sel);
  } else if (hint && hint.h !== undefined) hpx = hint.h + (borderBox ? 0 : padH);
  if (kind === "col" && grow > 0 && hpx === null) { hMatch = true; hWeight = grow; }
  let hMin = null, hMax = null;
  const minh = p["min-height"];
  if (minh && minh !== "auto" && minh !== "0") {
    const mn = size(minh, { fs, width: C.width });
    if (mn && mn.px !== undefined && mn.px > 0) hMin = borderBox ? mn.px : mn.px + padH;
    else if (!mn || mn.pct !== undefined) C.rep("min-height: " + minh, sel);
  }
  const maxh = p["max-height"];
  if (maxh && maxh !== "none") {
    const mx = size(maxh, { fs, width: C.width });
    if (mx && mx.px !== undefined) hMax = borderBox ? mx.px : mx.px + padH;
    else C.rep("max-height: " + maxh, sel);
  }
  const background = C.noBg === el ? [] : backgroundOf(el, st, C);
  const aself = p["align-self"] && p["align-self"] !== "auto" ? p["align-self"] : null;
  const alignV = crossAlign(kind === "row" ? aself || pctx.ai : kind === "grid" ? aself || pctx.ai : null);
  if (hpx !== null) fields.height = { type: "fixed", value: round(hMin !== null ? Math.max(hpx, hMin) : hpx) };
  else if (hMatch) fields.height = hWeight !== null ? { type: "match_parent", weight: hWeight } : { type: "match_parent" };
  else if (kind === "row" && alignV === null && (background.length || bd.border) && pctx.ai !== "flex-start" && pctx.ai !== "start") fields.height = { type: "match_parent" };
  else {
    const h = { type: "wrap_content" };
    if (hMin !== null) h.min_size = { value: round(hMin) };
    if (hMax !== null) { h.max_size = { value: round(hMax) }; h.constrained = true; }
    fields.height = h;
  }
  if (alignV && alignV !== "start") fields.alignment_vertical = alignV === "end" ? "bottom" : alignV;
  else if (alignV === "start") fields.alignment_vertical = "top";
  if (auto.t && auto.b) fields.alignment_vertical = "center";
  else if (auto.t) fields.alignment_vertical = "bottom";

  const ar = p["aspect-ratio"];
  if (ar && ar !== "auto") {
    const parts = ar.split("/").map((x) => parseFloat(x));
    const ratio = parts.length === 2 ? parts[0] / parts[1] : parts[0];
    if (ratio > 0 && isFinite(ratio)) fields.aspect = { ratio: Math.round(ratio * 1000) / 1000 };
  }

  // --- spacing and paint
  const edge = (e) => {
    const o = {};
    if (e.top) o.top = round(e.top);
    if (e.right) o.right = round(e.right);
    if (e.bottom) o.bottom = round(e.bottom);
    if (e.left) o.left = round(e.left);
    return Object.keys(o).length ? o : null;
  };
  const mg = edge(m), pd = edge(pads);
  if (mg) fields.margins = mg;
  if (pd) fields.paddings = pd;
  if (background.length) fields.background = background;
  if (bd.border) fields.border = bd.border;
  const op = parseFloat(p.opacity);
  if (!isNaN(op) && op < 1) fields.alpha = Math.max(0, Math.round(op * 100) / 100);
  if (/^(hidden|clip)$/.test(p["overflow-x"] || "") || /^(hidden|clip)$/.test(p["overflow-y"] || "")) fields.clip_to_bounds = true;

  const visible = background.length > 0 || !!bd.border || hpx !== null || hMin !== null || padH + padW > 0 || !!fields.aspect;
  return { fields, contentW, visible, auto, pads, wFixed: wpx };
}

// ---------------------------------------------------------------- accessibility and actions

function labelText(el, C) {
  const own = attr(el, "aria-label");
  if (own) return own;
  const by = attr(el, "aria-labelledby");
  if (by) {
    const t = by.split(/\s+/).map((id) => { const n = C.document.getElementById(id); return n ? (n.textContent || "").trim() : ""; }).filter(Boolean).join(" ");
    if (t) return t;
  }
  const textOf = (n) => {
    let s = "";
    for (const c of n.childNodes) {
      if (c.nodeType === 3) s += c.data;
      else if (c.nodeType === 1 && !/^(input|textarea|select|button|script|style)$/.test(lname(c))) s += textOf(c);
    }
    return s;
  };
  for (let a = el.parentElement; a; a = a.parentElement) {
    if (lname(a) === "label") return textOf(a).replace(/\s+/g, " ").trim();
  }
  const id = attr(el, "id");
  if (id) {
    for (const l of C.document.querySelectorAll("label")) if (attr(l, "for") === id) return textOf(l).replace(/\s+/g, " ").trim();
  }
  return "";
}

function a11y(el, kind, _C, extra) {
  const tag = lname(el);
  const role = attr(el, "role");
  const o = {};
  const label = attr(el, "aria-label");
  if (label) o.description = lit(label);
  if (extra && extra.description && !o.description) o.description = lit(extra.description);
  if (/^h[1-6]$/.test(tag) || role === "heading") o.type = "header";
  else if (kind === "image") o.type = "image";
  else if (extra && extra.type) o.type = extra.type;
  else if (isTappable(el)) o.type = "button";
  if (attr(el, "aria-hidden") === "true") o.mode = "exclude";
  else if (kind === "image" && attr(el, "alt") === "") o.mode = "exclude";
  else if (kind === "container" && isTappable(el)) o.mode = "merge";
  else if (Object.keys(o).length) o.mode = "default";
  if (extra && extra.checked !== undefined) o.is_checked = extra.checked;
  return Object.keys(o).length ? o : null;
}

function interact(div, el, C, kind, extra) {
  if (isTappable(el)) {
    const id = C.reg(el);
    div.actions = [{ log_id: id, url: "pronto://tap/" + id }];
  }
  if (has(el, "data-on-contextmenu") && !has(el, "disabled")) {
    const id = C.reg(el);
    div.longtap_actions = [{ log_id: id, url: "pronto://contextmenu/" + id }];
  }
  const a = a11y(el, kind, C, extra);
  if (a) div.accessibility = a;
  return div;
}

// ---------------------------------------------------------------- unsupported properties

function checkProps(el, st, C, par) {
  const p = st.p;
  const sel = desc(el);
  const pos = p.position;
  if (pos === "absolute" || pos === "fixed" || pos === "sticky") C.rep("position: " + pos, sel);
  if (p.float === "left" || p.float === "right") C.rep("float", sel);
  for (const name of ["transform", "filter", "backdrop-filter", "clip-path", "mix-blend-mode", "text-shadow", "column-count", "columns", "mask", "mask-image"]) {
    const v = p[name];
    if (v !== undefined && v !== "none" && v !== "normal" && v !== "auto") C.rep(name, sel);
  }
  if (p["writing-mode"] && p["writing-mode"] !== "horizontal-tb") C.rep("writing-mode", sel);
  for (const axis of ["overflow-x", "overflow-y"]) {
    if (p[axis] === "auto" || p[axis] === "scroll") C.rep("overflow: " + p[axis] + " (no inner scrolling)", sel);
  }
  if (p["grid-template-areas"] && p["grid-template-areas"] !== "none") C.rep("grid-template-areas", sel);
  const fstyle = p["font-style"];
  if ((fstyle === "italic" || fstyle === "oblique") && (!par || par.p["font-style"] !== fstyle)) C.rep("font-style: italic", sel);
  const fam = p["font-family"];
  if (fam && (!par || par.p["font-family"] !== fam)) {
    const first = fam.split(",")[0].trim().replace(/^["']|["']$/g, "").toLowerCase();
    if (!/^(system-ui|sans-serif|ui-sans-serif|-apple-system|blinkmacsystemfont|roboto|inherit|monospace|ui-monospace|courier|menlo|consolas|monaco)$/.test(first)) C.rep("font-family: " + first, sel);
  }
  const h = p.height;
  if (h && /(vh|svh|dvh|lvh)$/.test(h)) C.rep("height: " + h, sel);
}

// ---------------------------------------------------------------- conversion

// An element with a border above or below only gets a separator before or after it.
function decorate(el, divs, C) {
  const e = C.edges.get(el);
  if (!e || divs.length !== 1 || !opaque((e.top || e.bottom).c)) return divs;
  const d = divs[0];
  const wrap = { type: "container", id: d.id + "_w", orientation: "vertical", width: d.width || { type: "match_parent" }, height: { type: "wrap_content" } };
  for (const k of ["margins", "alignment_horizontal", "alignment_vertical"]) if (d[k]) { wrap[k] = d[k]; delete d[k]; }
  if (d.height && d.height.type === "match_parent") { wrap.height = d.height; }
  d.width = { type: "match_parent" };
  const line = (s, n) => ({ type: "separator", id: d.id + "_" + n, delimiter_style: { color: s.c, orientation: "horizontal" }, height: { type: "fixed", value: Math.max(1, round(s.w)) } });
  wrap.items = [].concat(e.top ? [line(e.top, "top")] : [], [d], e.bottom ? [line(e.bottom, "bottom")] : []);
  return [wrap];
}

// A bevel is four strips over the view's face: light along the top and left, dark along the bottom and
// right, as a border paints only its own edges and leaves the inside to what lies behind. The view itself,
// which keeps its padding for the edge, its action and its id, lies over them without a background.
function bevel(el, divs, C) {
  const e = C.bevels.get(el);
  if (!e || divs.length !== 1) return divs;
  const d = divs[0];
  const face = d.background;
  const wrap = { type: "container", id: d.id + "_b", orientation: "overlap", width: d.width, height: d.height };
  for (const k of ["margins", "alignment_horizontal", "alignment_vertical"]) if (d[k]) { wrap[k] = d[k]; delete d[k]; }
  // A grid that stretches (css grids size to their tracks) stays as wide as its content inside the frame, which
  // stretches for it: a match_parent view under an overlap adds nothing to the width its parents wrap to.
  d.width = d.width && d.width.type === "wrap_content" ? d.width : d.width && d.width.type === "match_parent" && layoutKind(C.style(el)) === "grid" ? { type: "wrap_content" } : { type: "match_parent" };
  d.height = d.height && d.height.type === "wrap_content" ? d.height : { type: "match_parent" };
  delete d.background;
  const w = Math.max(1, round(e.w));
  const strip = (n, color, width, height, h, v) => {
    const o = { type: "container", id: d.id + "_" + n, width, height, background: [{ type: "solid", color }], items: [] };
    if (h) o.alignment_horizontal = h;
    if (v) o.alignment_vertical = v;
    return o;
  };
  const all = { type: "match_parent" }, edge = { type: "fixed", value: w };
  wrap.items = [
    ...(face ? [{ type: "container", id: d.id + "_face", width: all, height: all, background: face, items: [] }] : []),
    strip("top", e.light, all, edge),
    strip("left", e.light, edge, all),
    strip("bottom", e.dark, all, edge, null, "bottom"),
    strip("right", e.dark, edge, all, "right"),
    d,
  ];
  return [wrap];
}

function convert(el, pctx, C) {
  let out = convertOne(el, pctx, C);
  if (C.edges.size) out = decorate(el, out, C);
  if (C.bevels.size) out = bevel(el, out, C);
  return out;
}

function convertOne(el, pctx, C) {
  if (!drawn(el, C)) return [];
  const tag = lname(el);
  const st = C.style(el);
  checkProps(el, st, C, el.parentElement ? C.style(el.parentElement) : null);
  const kind = layoutKind(st);
  if (kind === "contents") return childItems(el, st, pctx, C, pctx.kind !== "block", C.reg(el));
  switch (tag) {
    case "img": return imageDiv(el, st, pctx, C);
    case "input": return inputDiv(el, st, pctx, C);
    case "textarea": return fieldDiv(el, st, pctx, C);
    case "select": return selectDiv(el, st, pctx, C);
    case "hr": return ruleDiv(el, st, pctx, C);
    case "scene": return sceneDiv(el, st, pctx, C);
    case "br": return [];
    default:
  }
  const flexish = kind === "flex" || kind === "grid";
  if (textOnly(el, flexish, C)) return textElement(el, st, pctx, C, flexish);
  return containerElement(el, st, pctx, C, kind);
}

function textOnly(el, flexish, C) {
  if (!flexish && loneTapChild(el, C)) return false;
  for (const n of el.childNodes) {
    if (n.nodeType !== 1 || !drawn(n, C)) continue;
    if (flexish || !isPhrasing(n, C)) return false;
  }
  return true;
}

function markerOf(el, st) {
  const tag = lname(el);
  if (tag === "summary") {
    if (st.p["list-style-type"] === "none") return "";
    const par = el.parentElement;
    return par && has(par, "open") ? "▾ " : "▸ ";
  }
  if (tag === "li" && st.p["list-style-type"] && st.p["list-style-type"] !== "none") {
    const par = el.parentElement;
    if (par && lname(par) === "ol") {
      let n = 0;
      for (const s of par.children) { if (lname(s) === "li") n++; if (s === el) break; }
      return n + ". ";
    }
    return "• ";
  }
  return "";
}

function textElement(el, st, pctx, C, flexish) {
  const run = buildRun(el.childNodes, st, C, el, markerOf(el, st));
  const b = outerBox(el, st, pctx, C, "text");
  if (run.text === "" && !b.visible) return [];
  const id = C.reg(el);
  const div = Object.assign({ type: "text", id, text: lit(run.text) }, textProps(st), b.fields);
  if (run.ranges.length) div.ranges = run.ranges.map((r) => Object.assign({}, r));
  const p = st.p;
  if (flexish) {
    const ai = crossAlign(p["align-items"]), jc = p["justify-content"] || p["justify-items"];
    if (ai) div.text_alignment_vertical = ai === "start" ? "top" : ai === "end" ? "bottom" : ai;
    if (!div.text_alignment_horizontal) {
      const j = crossAlign(jc);
      if (j === "center") div.text_alignment_horizontal = "center";
      else if (j === "end") div.text_alignment_horizontal = "right";
    }
  } else if (lname(el) === "button" || (lname(el) === "input")) div.text_alignment_vertical = "center";
  return [interact(div, el, C, "text")];
}

function anonText(run, st, cctx, _C, id) {
  const div = Object.assign({ type: "text", id, text: lit(run.text), width: cctx.kind === "row" ? { type: "wrap_content" } : { type: "match_parent" }, height: { type: "wrap_content" } }, textProps(st));
  if (run.ranges.length) div.ranges = run.ranges.map((r) => Object.assign({}, r));
  return div;
}

// The views of an element's children: runs of text and inline elements become text, the rest convert.
function childItems(el, st, cctx, C, flexish, parentId) {
  const out = [];
  let run = [];
  let k = 0;
  const lone = flexish ? null : loneTapChild(el, C);
  const flush = () => {
    if (!run.length) return;
    const r = buildRun(run, st, C, null, "");
    run = [];
    if (r.text !== "") out.push(anonText(r, st, cctx, C, parentId + "_t" + k++));
  };
  for (const n of el.childNodes) {
    if (n.nodeType === 3) { run.push(n); continue; }
    if (n.nodeType !== 1 || !drawn(n, C)) continue;
    if (!flexish && isPhrasing(n, C) && n !== lone) { run.push(n); continue; }
    flush();
    try { for (const d of convert(n, cctx, C)) out.push(d); } catch (e) { C.rep("compile error: " + (e && e.message), desc(n)); }
  }
  flush();
  return out;
}

function gridColumns(st, gap, avail, el, C) {
  const v = (st.p["grid-template-columns"] || "").trim().toLowerCase();
  if (!v || v === "none") return 1;
  const lctx = { fs: st.fs, basis: avail, width: C.width };
  const rep = /^repeat\(\s*(auto-fit|auto-fill|\d+)\s*,\s*([\s\S]+)\)$/.exec(v);
  const equal = (t) => /^(1fr|minmax\([^,]+,\s*1fr\))$/.test(t.trim());
  if (rep) {
    const tracks = splitWs(rep[2].trim());
    if (rep[1] === "auto-fit" || rep[1] === "auto-fill") {
      const t = tracks[0] || "";
      const mm = /^minmax\(([\s\S]+)\)$/.exec(t);
      const min = length(mm ? splitTop(mm[1], ",")[0].trim() : t, lctx);
      if (min === null || min <= 0) { C.rep("grid-template-columns: " + v, desc(el)); return 1; }
      return Math.max(1, Math.floor((avail + gap) / (min + gap)));
    }
    if (!tracks.every(equal)) C.rep("grid-template-columns with tracks of unequal size", desc(el));
    return Math.max(1, parseInt(rep[1], 10) * tracks.length);
  }
  const tracks = splitWs(v);
  if (!tracks.every(equal)) C.rep("grid-template-columns with tracks of unequal size", desc(el));
  return Math.max(1, tracks.length);
}

function spanOf(_el, st, cols) {
  const v = (st.p["grid-column"] || "").trim();
  if (!v) return 1;
  const m = /^span\s+(\d+)$/.exec(v);
  if (m) return Math.min(cols, parseInt(m[1], 10));
  const r = /^(-?\d+)\s*\/\s*(-?\d+|span\s+\d+)$/.exec(v);
  if (r) {
    if (r[2] === "-1") return Math.max(1, cols - (parseInt(r[1], 10) - 1));
    const sp = /^span\s+(\d+)$/.exec(r[2]);
    if (sp) return Math.min(cols, parseInt(sp[1], 10));
    return Math.max(1, Math.min(cols, parseInt(r[2], 10) - parseInt(r[1], 10)));
  }
  return 1;
}

function containerElement(el, st, pctx, C, kind) {
  const p = st.p;
  const b = outerBox(el, st, pctx, C, "container");
  const id = C.reg(el);
  const fs = st.fs;
  const lctx = { fs, basis: b.contentW, width: C.width };
  const gapOf = (name) => { const v = p[name]; if (v === undefined || v === "normal") return 0; const n = length(v, lctx); return n === null ? 0 : Math.max(0, n); };
  const rowGap = gapOf("row-gap"), colGap = gapOf("column-gap");
  const div = Object.assign({ type: "container", id }, b.fields);
  let items;
  let childCtx;
  let reverse = false;

  if (kind === "flex") {
    const dir = (p["flex-direction"] || "row").toLowerCase();
    const row = dir === "row" || dir === "row-reverse";
    reverse = /reverse$/.test(dir);
    childCtx = { kind: row ? "row" : "col", avail: b.contentW, ai: p["align-items"], ji: p["justify-items"], ta: p["text-align"] };
    div.orientation = row ? "horizontal" : "vertical";
    const wrap = (p["flex-wrap"] || "nowrap") !== "nowrap";
    if (wrap && row) {
      div.layout_mode = "wrap";
      if (rowGap) div.line_spacing = round(rowGap);
    }
    const spacing = row ? colGap : rowGap;
    if (spacing) div.item_spacing = round(spacing);
    const jc = (p["justify-content"] || "").toLowerCase();
    const main = { center: "center", "flex-end": row ? "right" : "bottom", end: row ? "right" : "bottom", right: "right", "space-between": "space-between", "space-around": "space-around", "space-evenly": "space-evenly" }[jc];
    if (main && !(reverse && (jc === "flex-end" || jc === "end"))) div[row ? "content_alignment_horizontal" : "content_alignment_vertical"] = main;
    else if (reverse && (jc === "flex-end" || jc === "end")) div[row ? "content_alignment_horizontal" : "content_alignment_vertical"] = row ? "left" : "top";
    else if (reverse && !jc) div[row ? "content_alignment_horizontal" : "content_alignment_vertical"] = row ? "right" : "bottom";
    items = childItems(el, st, childCtx, C, true, id);
  } else if (kind === "grid") {
    const cols = gridColumns(st, colGap, b.contentW, el, C);
    if (cols <= 1) {
      childCtx = { kind: "col", g: true, avail: b.contentW, ai: p["justify-items"], ji: p["justify-items"], ta: p["text-align"] };
      div.orientation = "vertical";
      if (rowGap) div.item_spacing = round(rowGap);
      items = childItems(el, st, childCtx, C, true, id);
    } else {
      const cell = Math.max(0, (b.contentW - colGap * (cols - 1)) / cols);
      childCtx = { kind: "grid", avail: cell, ai: p["align-items"], ji: p["justify-items"], ta: p["text-align"] };
      div.type = "grid";
      div.column_count = cols;
      items = childItems(el, st, childCtx, C, true, id);
      for (const n of el.childNodes) {
        if (n.nodeType !== 1 || !drawn(n, C)) continue;
        const d = items.find((x) => x.id === idOf(n));
        const sp = d ? spanOf(n, C.style(n), cols) : 1;
        if (sp > 1) d.column_span = sp;
      }
      // the gaps are margins on the cells: DivKit's grid has no spacing of its own
      let cursor = 0;
      const spans = items.map((d) => { const s = Math.min(cols, d.column_span || 1); const at = cursor % cols; if (at + s > cols) cursor += cols - at; const pos = cursor; cursor += s; return { pos, s }; });
      const rows = Math.ceil(cursor / cols);
      items.forEach((d, i) => {
        const at = spans[i].pos % cols, row = Math.floor(spans[i].pos / cols);
        const mg = Object.assign({}, d.margins || {});
        if (colGap && at + spans[i].s < cols) mg.right = (mg.right || 0) + round(colGap);
        if (rowGap && row < rows - 1) mg.bottom = (mg.bottom || 0) + round(rowGap);
        if (Object.keys(mg).length) d.margins = mg;
      });
    }
  } else {
    childCtx = { kind: "block", avail: b.contentW, ta: p["text-align"] };
    div.orientation = "vertical";
    items = childItems(el, st, childCtx, C, false, id);
    collapseMargins(items);
  }

  // ::before and ::after content is a text item before and after the rest
  const before = pseudoText(el, "before", C), after = pseudoText(el, "after", C);
  if (before) items.unshift(anonText({ text: before, ranges: [] }, st, childCtx, C, id + "_b"));
  if (after) items.push(anonText({ text: after, ranges: [] }, st, childCtx, C, id + "_a"));

  if (kind === "flex") items = autoMarginSpacers(el, items, childCtx.kind === "row", C, id);
  if (reverse) items.reverse();
  if (!items.length && !b.visible) return [];
  div.items = items;
  return [interact(div, el, C, "container")];
}

// Sibling margins in a block flow collapse to the larger of the two.
function collapseMargins(items) {
  for (let i = 1; i < items.length; i++) {
    const a = items[i - 1].margins, b = items[i].margins;
    if (a && b && a.bottom > 0 && b.top > 0) {
      const t = Math.max(0, b.top - a.bottom);
      if (t) b.top = t; else delete b.top;
      if (!Object.keys(b).length) delete items[i].margins;
    }
  }
}

// `margin-left: auto` in a flex row (or `margin-top: auto` in a column) takes the free space: a
// weighted empty view stands for it.
function autoMarginSpacers(el, items, row, C, parentId) {
  const out = [];
  const byId = new Map();
  for (const n of el.childNodes) if (n.nodeType === 1) byId.set(idOf(n), n);
  const spacer = (key) => ({ type: "container", id: parentId + "_s" + key, width: row ? { type: "match_parent", weight: 1 } : { type: "wrap_content" }, height: row ? { type: "wrap_content" } : { type: "match_parent", weight: 1 }, items: [] });
  let k = 0;
  for (const d of items) {
    const n = byId.get(d.id);
    if (n) {
      const p = C.style(n).p;
      const start = row ? p["margin-left"] : p["margin-top"], end = row ? p["margin-right"] : p["margin-bottom"];
      if (start === "auto") out.push(spacer(k++));
      out.push(d);
      if (end === "auto") out.push(spacer(k++));
    } else out.push(d);
  }
  return out;
}

// ---------------------------------------------------------------- replaced elements and controls

function imageDiv(el, st, pctx, C) {
  const src = attr(el, "src");
  if (!src) return [];
  const aw = parseFloat(attr(el, "width")), ah = parseFloat(attr(el, "height"));
  const hint = {};
  if (!isNaN(aw) && aw > 0) hint.w = aw;
  if (!isNaN(ah) && ah > 0) hint.h = ah;
  const b = outerBox(el, st, pctx, C, "image", hint);
  const fit = (st.p["object-fit"] || "").toLowerCase();
  const div = Object.assign({ type: "image", id: C.reg(el), image_url: resolveUrl(src, C.base), scale: fit === "cover" ? "fill" : fit === "fill" ? "stretch" : fit === "none" ? "no_scale" : "fit" }, b.fields);
  const alt = attr(el, "alt");
  const acc = interact(div, el, C, "image");
  if (alt && !acc.accessibility.description) acc.accessibility = Object.assign({}, acc.accessibility, { description: lit(alt) });
  return [acc];
}

// A v3 scene (the hatch contract's scene, model, anim, camera, audio) is one custom div, "pronto-scene":
// Kotlin's SceneView draws it. bound.js has already refused a scene the contract refuses, so this only
// types what is there, with the contract's defaults (the Unity host's Scene.Of).
const sceneNum = (el, name, dflt) => { const v = attr(el, name); const n = v === null || v.trim() === "" ? NaN : Number(v); return isFinite(n) ? n : dflt; };
const sceneVec = (el, names, dflt) => names.map((n, i) => sceneNum(el, n, dflt[i]));
const sceneKey = (el) => attr(el, "data-hatch-key") || idOf(el);
const sceneOn = (el, name) => has(el, name) && attr(el, name) !== "false";
function sceneProps(el) {
  const props = { background: attr(el, "background") || "", camera: { x: 0, y: 5, z: -8, lookX: 0, lookY: 0, lookZ: 0, fov: 45 }, models: [], anims: [], audios: [] };
  let cam = false;
  for (const c of el.children) {
    const tag = lname(c), key = sceneKey(c);
    if (tag === "model") {
      const [x, y, z] = sceneVec(c, ["x", "y", "z"], [0, 0, 0]), [rx, ry, rz] = sceneVec(c, ["rx", "ry", "rz"], [0, 0, 0]), [sx, sy, sz] = sceneVec(c, ["sx", "sy", "sz"], [1, 1, 1]);
      props.models.push({ key, shape: attr(c, "shape") || "", prefab: attr(c, "prefab") || "", color: attr(c, "color") || "", x, y, z, rx, ry, rz, sx, sy, sz });
    } else if (tag === "anim") {
      const [dx, dy, dz] = sceneVec(c, ["dx", "dy", "dz"], [0, 0, 0]);
      props.anims.push({ key, target: attr(c, "target") || "", clip: attr(c, "clip") || "", duration: sceneNum(c, "duration", 0.5), dx, dy, dz, spin: sceneNum(c, "spin", 0), loop: sceneOn(c, "loop") });
    } else if (tag === "camera" && !cam) {
      cam = true;
      const [x, y, z] = ["x", "y", "z"].some((n) => has(c, n)) ? sceneVec(c, ["x", "y", "z"], [0, 0, 0]) : [0, 5, -8];
      const [lookX, lookY, lookZ] = sceneVec(c, ["look-x", "look-y", "look-z"], [0, 0, 0]);
      props.camera = { x, y, z, lookX, lookY, lookZ, fov: sceneNum(c, "fov", 45) };
    } else if (tag === "audio") {
      props.audios.push({ key, clip: attr(c, "clip") || "", volume: sceneNum(c, "volume", 1), loop: sceneOn(c, "loop") });
    }
  }
  return props;
}

function sceneDiv(el, st, pctx, C) {
  const b = outerBox(el, st, pctx, C, "scene", {});
  const f = b.fields;
  // No size from the CSS: the width of the page and a square.
  if (f.width.type === "wrap_content") f.width = { type: "match_parent" };
  if (f.height.type === "wrap_content" && !f.aspect) f.aspect = { ratio: 1 };
  return [Object.assign({ type: "custom", id: C.reg(el), custom_type: "pronto-scene", custom_props: sceneProps(el) }, f)];
}

function ruleDiv(el, st, pctx, C) {
  const b = outerBox(el, st, pctx, C, "container");
  const top = st.p["border-top-width"];
  const thick = Math.max(1, round(parseFloat(top) > 0 ? parseFloat(top) : b.fields.height && b.fields.height.value ? b.fields.height.value : 1));
  const bg = b.fields.background && b.fields.background[0] && b.fields.background[0].color;
  const color = bg || parseColor(st.p["border-top-color"] || "currentcolor", colorOf(st), st.scope.dark) || colorOf(st);
  const div = { type: "separator", id: C.reg(el), delimiter_style: { color, orientation: "horizontal" }, width: b.fields.width, height: { type: "fixed", value: thick } };
  if (b.fields.margins) div.margins = b.fields.margins;
  return [div];
}

function fieldBase(el, st, pctx, C, _type, hint) {
  const b = outerBox(el, st, pctx, C, "control", hint);
  const id = C.reg(el);
  const tp = textProps(st);
  delete tp.max_lines;
  const div = Object.assign({ id }, tp, b.fields);
  const ph = attr(el, "placeholder");
  if (ph) {
    div.hint_text = lit(ph);
    const pr = C.styler.pseudo(el, "placeholder");
    const hc = pr && pr.color ? parseColor(pr.color, colorOf(st), st.scope.dark) : null;
    div.hint_color = hc || "#80" + colorOf(st).slice(3);
  }
  return { div, id, b };
}

function inputDiv(el, st, pctx, C) {
  const type = (attr(el, "type") || "text").toLowerCase();
  if (type === "submit" || type === "button" || type === "reset") {
    const label = attr(el, "value") || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : "");
    const b = outerBox(el, st, pctx, C, "text");
    const div = Object.assign({ type: "text", id: C.reg(el), text: lit(label), text_alignment_vertical: "center" }, textProps(st), b.fields);
    if (!div.text_alignment_horizontal) div.text_alignment_horizontal = "center";
    return [interact(div, el, C, "text")];
  }
  if (type === "checkbox" || type === "radio") return checkDiv(el, st, pctx, C, type);
  if (type === "file" || type === "color" || type === "range" || type === "image") { C.rep("input type=" + type, desc(el)); return []; }
  if (/^(date|time|datetime-local|month|week)$/.test(type)) C.rep("input type=" + type + " (drawn as a text field)", desc(el));
  const mode = (attr(el, "inputmode") || "").toLowerCase();
  let keyboard = "single_line_text";
  if (type === "email" || mode === "email") keyboard = "email";
  else if (type === "url" || mode === "url") keyboard = "uri";
  else if (type === "tel" || mode === "tel") keyboard = "phone";
  else if (type === "number" || mode === "numeric" || mode === "decimal") keyboard = "number";
  else if (type === "password") keyboard = "password";
  return [textField(el, st, pctx, C, keyboard, type)];
}

function fieldDiv(el, st, pctx, C) {
  return [textField(el, st, pctx, C, "multi_line_text", "textarea")];
}

function textField(el, st, pctx, C, keyboard, type) {
  const multi = type === "textarea";
  let hint;
  if (multi) {
    const rows = parseInt(attr(el, "rows"), 10) || 2;
    const lh = lineHeight(st) || st.fs * 1.2;
    hint = { minH: rows * lh };
  }
  const { div, id, b } = fieldBase(el, st, pctx, C, "input", null);
  div.type = "input";
  div.text_variable = "v_" + id;
  div.keyboard_type = keyboard;
  C.vars.push({ type: "string", name: "v_" + id, value: String(el.value === undefined || el.value === null ? "" : el.value) });
  if (multi) {
    const h = div.height && div.height.type === "wrap_content" ? div.height : null;
    const pads = b.pads.top + b.pads.bottom;
    if (h) h.min_size = { value: round(hint.minH + pads) };
  }
  const ml = parseInt(attr(el, "maxlength"), 10);
  if (ml > 0) div.max_length = ml;
  if (has(el, "disabled")) div.is_enabled = false;
  const cap = (attr(el, "autocapitalize") || "").toLowerCase();
  if (cap === "off" || cap === "none") div.autocapitalization = "none";
  else if (cap === "words") div.autocapitalization = "words";
  else if (cap === "sentences") div.autocapitalization = "sentences";
  else if (cap === "characters") div.autocapitalization = "all_characters";
  else if (type === "email" || type === "url" || type === "password") div.autocapitalization = "none";
  const ac = (attr(el, "autocomplete") || "").toLowerCase();
  if (!div.autocapitalization && /(^|\s)(name|given-name|family-name)$/.test(ac)) div.autocapitalization = "words";
  const name = labelText(el, C) || attr(el, "placeholder") || "";
  div.accessibility = { description: lit(name), type: "edit_text", mode: "default" };
  if (!name) delete div.accessibility.description;
  if (attr(el, "aria-hidden") === "true") div.accessibility.mode = "exclude";
  return div;
}

function selectDiv(el, st, pctx, C) {
  const options = [];
  const collect = (list) => {
    for (const n of list) {
      if (n.nodeType !== 1) continue;
      const tag = lname(n);
      if (tag === "option") {
        const text = (n.textContent || "").replace(/\s+/g, " ").trim();
        options.push({ value: has(n, "value") ? attr(n, "value") : text, text: lit(attr(n, "label") || text) });
      } else if (tag === "optgroup") collect(n.childNodes);
    }
  };
  collect(el.childNodes);
  if (!options.length) { C.rep("select without options", desc(el)); return []; }
  const { div, id } = fieldBase(el, st, pctx, C, "select", null);
  div.type = "select";
  div.value_variable = "v_" + id;
  div.options = options;
  C.vars.push({ type: "string", name: "v_" + id, value: String(el.value === undefined || el.value === null ? options[0].value : el.value) });
  const name = labelText(el, C);
  div.accessibility = { type: "select", mode: "default" };
  if (name) div.accessibility.description = lit(name);
  if (has(el, "disabled")) div.is_enabled = false;
  return [div];
}

function checkDiv(el, st, pctx, C, type) {
  const radio = type === "radio";
  const checked = el.checked !== undefined ? !!el.checked : has(el, "checked");
  const b = outerBox(el, st, pctx, C, "image", { w: 20, h: 20 });
  const accent = (st.p["accent-color"] && st.p["accent-color"] !== "auto" && parseColor(st.p["accent-color"], colorOf(st), st.scope.dark)) || "#FF1A73E8";
  const id = C.reg(el);
  const div = Object.assign({}, b.fields);
  div.type = "container";
  div.id = id;
  div.width = { type: "fixed", value: 20 };
  div.height = { type: "fixed", value: 20 };
  div.border = { corner_radius: radio ? 10 : 4, stroke: { color: accent, width: 2 } };
  div.content_alignment_horizontal = "center";
  div.content_alignment_vertical = "center";
  div.orientation = "vertical";
  if (checked && !radio) {
    div.background = [{ type: "solid", color: accent }];
    div.items = [{ type: "text", text: "✓", font_size: 14, text_color: "#FFFFFFFF", font_weight: "bold" }];
  } else if (checked) {
    div.items = [{ type: "container", width: { type: "fixed", value: 10 }, height: { type: "fixed", value: 10 }, border: { corner_radius: 5 }, background: [{ type: "solid", color: accent }], items: [] }];
  } else div.items = [];
  const name = labelText(el, C);
  return [interact(div, el, C, "container", { type, checked, description: name })];
}

// ---------------------------------------------------------------- the entry

/**
 * Compiles a document (HTML elements, computed against the sheets) to a DivKit card.
 * opts: {sheets: string[], width: dp, scheme?: "light" | "dark"}.
 */
export function compile(document, opts) {
  const width = opts.width || 411;
  const scheme = opts.scheme === "dark" ? "dark" : "light";
  const env = { width, scheme };
  const rules = parse(opts.sheets || [], env);
  const styler = createStyler(rules, env);
  const C = newState(document, { width, scheme }, styler, rules);
  const html = document.documentElement, body = document.body;
  const root = { type: "container", orientation: "vertical", width: { type: "match_parent" }, height: { type: "match_parent" }, items: [] };
  if (html && body) {
    const hs = C.style(html), bs = C.style(body);
    const hasHtmlBg = backgroundOf(html, hs, C).length > 0;
    const canvas = hasHtmlBg ? backgroundOf(html, hs, C) : backgroundOf(body, bs, C);
    root.background = canvas.length ? canvas : [{ type: "solid", color: hs.scope.dark ? "#FF121212" : "#FFFFFFFF" }];
    if (!hasHtmlBg) C.noBg = body;
    // the html element's own margin and padding surround the body
    const hp = hs.p, hl = { fs: hs.fs, basis: width, width };
    const side = (s) => Math.max(0, (length(hp["margin-" + s] || "0", hl) || 0) + (length(hp["padding-" + s] || "0", hl) || 0));
    const pads = { top: side("top"), right: side("right"), bottom: side("bottom"), left: side("left") };
    const pd = {};
    for (const k of Object.keys(pads)) if (pads[k]) pd[k] = round(pads[k]);
    if (Object.keys(pd).length) root.paddings = pd;
    const avail = Math.max(0, width - pads.left - pads.right);
    let items = [];
    try { items = convert(body, { kind: "block", avail, ta: undefined }, C); } catch (e) { C.rep("compile error: " + (e && e.message), "body"); }
    for (const d of items) d.width = { type: "match_parent" };
    root.items = items;
    checkProps(html, hs, C, null);
  }
  live = C.seen;
  const unsupported = [];
  const dedupe = new Set();
  for (const r of rules.reports.list.concat(C.reports)) {
    const k = r.what + "\u0001" + r.selector;
    if (!dedupe.has(k)) { dedupe.add(k); unsupported.push({ what: r.what, selector: r.selector }); }
  }
  return {
    card: { log_id: "screen", variables: C.vars, states: [{ state_id: 0, div: root }] },
    unsupported,
  };
}
