// pronto-ads' cases (tests/unit/ads.cue): the page's adapter (ads/app/ads.js) on a fake frame, window and
// timers, the ad document's service (ads/app/server.ts) on the document the app's CUE makes of a
// publisher, the posture of that document's policy, and the generate step's Caddyfile splice (ads/app/ads.nu)
// on a stand-in door. Nothing here calls Google or any network: the frame is a fake that records what the
// page tells it, and time is a clock a case advances.
import { adapter } from '../../ads/app/ads.js';
import { handle } from '../../ads/app/server.ts';

export { frameUrl, mode } from '../../ads/app/ads.js';

const here = new URL('../../', import.meta.url).pathname;
const dec = new TextDecoder();
const SITE = 'https://bonkchess.com';
const FRAME = 'https://ads.bonkchess.com';
const PUBLISHER = 'pub-4071304447370172';

async function run(cmd, args, cwd) {
  const out = await new Deno.Command(cmd, { args, cwd, stdout: 'piped', stderr: 'piped' }).output();
  return { code: out.code, out: dec.decode(out.stdout), err: dec.decode(out.stderr) };
}

// --- What the app's CUE makes -----------------------------------------------------------------------------

const made = new Map();
/** An app the installer set up, naming `publisher`, `site` and `frame` (all three by default, none with
 * `{publisher: ""}`), and the whole of what its CUE exports: `adsense`, and `code` and `cluster` once
 * a publisher is named. */
export function exported({ publisher = PUBLISHER, site = SITE, frame = FRAME } = {}) {
  const key = JSON.stringify([publisher, site, frame]);
  if (!made.has(key)) made.set(key, build(publisher, site, frame));
  return made.get(key);
}
async function build(publisher, site, frame) {
  const dir = await Deno.makeTempDir({ prefix: 'pronto-ads-' });
  try {
    await Deno.writeTextFile(`${dir}/program.cue`, 'package shop\n');
    const install = await run(Deno.execPath(), ['run', '--no-config', '--allow-read', '--allow-write', '--allow-run=git', `${here}ads/install.ts`, dir], here);
    if (install.code) throw new Error(`the installer failed: ${install.err}`);
    const spec = await Deno.readTextFile(`${dir}/ads_spec.cue`);
    const named = publisher ? `adsense: publisher: "${publisher}"\nadsense: site: "${site}"\nadsense: frame: "${frame}"\n` : '';
    await Deno.writeTextFile(`${dir}/ads_spec.cue`, spec + named);
    const cue = await run(Deno.env.get('CUE') ?? 'cue', ['export', '.', '--out', 'json'], dir);
    if (cue.code) throw new Error(`cue export failed: ${cue.err}`);
    return JSON.parse(cue.out);
  } finally { await Deno.remove(dir, { recursive: true }); }
}

/** The ad document, its policy, and the origins the app named, as its CUE made them. */
export async function page() {
  const x = await exported();
  return { ...x.adsense.break, site: SITE, frame: FRAME };
}

/** What a spec without a publisher exports. */
export async function bare() {
  const x = await exported({ publisher: '' });
  return { adsense: x.adsense, resources: x.code?.capabilities?.resources ?? null, targets: x.cluster?.surface?.targets ?? null };
}

/** What a spec that names the publisher makes for the door and the cluster. */
export async function named() {
  const x = await exported();
  return { resources: x.code.capabilities.resources, targets: Object.keys(x.cluster.surface.targets), target: x.cluster.surface.targets.ads };
}

/** A spec that names a publisher but no origins is refused by its CUE. */
export async function refused(spec) {
  try { await exported(spec); return null; } catch (e) { return e.message.includes('adsense') ? 'refused' : e.message; }
}

// --- The adapter, on a fake page --------------------------------------------------------------------------

// A page's world: its window, document and location, the frame's window (which records what the page tells
// it, with the frame's shape at that moment), and a clock whose timers a case advances.
function world({ site = SITE, frame = FRAME, origin = site, search = '' } = {}) {
  let now = 0, seq = 0, ids = 0, box = null;
  const timers = new Map();
  const log = { posted: [], created: [] };
  const listeners = [];
  const frameWindow = { postMessage: (m, target) => log.posted.push({ m, target, expanded: box.style.cssText.includes('width:100%') }) };
  const add = (f, ms, every) => { const h = ++seq; timers.set(h, { at: now + ms, f, every }); return h; };
  const env = {
    site, frame,
    location: { origin, search },
    window: { addEventListener: (t, f) => { if (t === 'message') listeners.push(f); } },
    document: {
      createElement(tag) {
        log.created.push(tag);
        box = { tag, style: { cssText: '' }, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, contentWindow: frameWindow };
        return box;
      },
      body: { append() {} },
    },
    setTimeout: (f, ms) => add(f, ms),
    clearTimeout: (h) => { timers.delete(h); },
    newId: () => `b${++ids}`,
  };
  const tick = (seconds) => {
    const end = now + seconds * 1000;
    for (;;) {
      const next = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      const [h, t] = next;
      now = t.at;
      if (t.every) t.at += t.every; else timers.delete(h);
      t.f();
    }
    now = end;
  };
  const deliver = ({ origin: from = frame, source, data }) => {
    const src = source === 'other' ? {} : frameWindow;
    for (const f of listeners) f({ origin: from, source: src, data });
  };
  return { env, log, tick, deliver, add, timers: { setInterval: (f, ms) => add(f, ms, ms), clearInterval: (h) => { timers.delete(h); }, setTimeout: (f, ms) => add(f, ms), clearTimeout: (h) => { timers.delete(h); } }, box: () => box, listeners };
}

const flush = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };

/** One `rewarded()` on a fake page, and a script of what happens: `{frame: {...}}` a message from the ad
 * document's frame (type, v and the break's id filled in unless the fields name them), `{as: {origin?,
 * source?}}` beside it where the message comes from elsewhere, `{data}` a message's whole data, `{tick:
 * seconds}` time passing, `{mark}` a snapshot. What it says: the result (null while pending), the page's
 * messages to the frame (their ops, whether the frame covered the page when each went, whom each was
 * addressed to), what it created, the sound's brackets, and the snapshots. */
export async function play({ opts = {}, script = [], ...where } = {}) {
  const w = world(where);
  const { rewarded } = adapter(w.env);
  const audio = [];
  let result = null, error = null;
  rewarded({ ...opts, onStart: () => audio.push('start'), onEnd: () => audio.push('end') }).then((v) => { result = v; }, (e) => { error = e.message; });
  const marks = {};
  const state = () => ({ pending: result === null && error === null, ops: w.log.posted.map((p) => p.m.op) });
  for (const s of script) {
    if ('tick' in s) w.tick(s.tick);
    else if ('mark' in s) { await flush(); marks[s.mark] = state(); }
    else if ('data' in s) w.deliver({ ...(s.as ?? {}), data: s.data });
    else w.deliver({ ...(s.as ?? {}), data: { type: 'pronto-ads', v: 1, id: 'b1', ...s.frame } });
    await flush();
  }
  const box = w.box();
  return {
    result, error, ...state(), marks, audio,
    expandedAt: w.log.posted.map((p) => p.expanded),
    targets: [...new Set(w.log.posted.map((p) => p.target))],
    created: w.log.created,
    hidden: box ? box.style.cssText.includes('-9999px') : null,
  };
}

/** The results of one ad each, which ended as Google's `adBreakDone` said by `breakStatus`. */
export async function endedBy(statuses) {
  const out = [];
  for (const breakStatus of statuses) {
    out.push((await play({ script: [{ frame: { event: 'ready', id: null } }, { frame: { event: 'beforeReward' } }, { frame: { event: 'done', breakStatus } }] })).result);
  }
  return out;
}

/** A message that is none of the contract's, sent where the ad's `beforeReward` and `done` would be: what
 * the page did with it (nothing: still waiting, no `show`) and how the ad ended. The control, a defect of
 * `{}`, is accepted, so that the others are dropped for their defect and for no other. */
export async function dropped(defect = {}) {
  const bad = (event, extra) => ({ ...(defect.as ? { as: defect.as } : {}), ...(defect.data !== undefined ? { data: defect.data } : { frame: { event, ...extra, ...(defect.frame ?? {}) } }) });
  const r = await play({
    script: [
      { frame: { event: 'ready', id: null } },
      bad('beforeReward', {}),
      bad('done', { breakStatus: 'viewed' }),
      { mark: 'after' },
      { tick: 15 },
    ],
  });
  return { after: r.marks.after, final: r.result, ops: r.ops };
}

/** What `prepare()` makes on a page at `origin` with `search`, called twice. */
export function prepared({ origin = SITE, search = '', site = SITE, frame = FRAME } = {}) {
  const w = world({ site, frame, origin, search });
  const { prepare } = adapter(w.env);
  prepare();
  prepare();
  const box = w.box();
  return { created: w.log.created, listeners: w.listeners.length, src: box?.src ?? null, attrs: box?.attrs ?? null, title: box?.title ?? null, hidden: box ? box.style.cssText.includes('-9999px') : null };
}

// The stand-in's dialog, as a page's: elements that hold what the adapter sets.
function element(tag) {
  const e = {
    tag, dataset: {}, style: {}, children: [], hidden: false, textContent: '', attrs: {}, onclick: null, listeners: {},
    setAttribute(k, v) { e.attrs[k] = v; }, addEventListener(t, f) { e.listeners[t] = f; }, append(...k) { e.children.push(...k); },
    remove() { e.removed = true; }, close() { e.closed = true; }, showModal() { e.opened = true; }, focus() {},
  };
  return e;
}

/** The stand-in on a page that is not the app's own (or one named no ad document): a dialog that plays at a
 * press, and nothing made for Google. `clicks` lists what is pressed, each after `after` seconds. */
export async function standIn({ opts = {}, clicks = [], origin = 'http://localhost:8080', ...where } = {}) {
  const w = world({ origin, ...where });
  const was = { document: globalThis.document, setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval, setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  const dialogs = [];
  globalThis.document = { createElement: (tag) => { const e = element(tag); if (tag === 'dialog') dialogs.push(e); return e; }, body: { append() {} } };
  Object.assign(globalThis, w.timers);
  try {
    const { rewarded, prepare } = adapter(w.env);
    prepare();
    const audio = [];
    let result = null;
    rewarded({ ...opts, onStart: () => audio.push('start'), onEnd: () => audio.push('end') }).then((v) => { result = v; });
    const dialog = dialogs[0];
    const button = (name) => dialog.children.find((c) => c.dataset?.ad === name);
    const seen = { dialog: dialog.dataset.prontoAd, opened: dialog.opened === true };
    for (const c of clicks) {
      if (c.after) w.tick(c.after);
      if (c.press) button(c.press).onclick();
      await flush();
    }
    await flush();
    return { ...seen, result, audio, created: w.log.created, posted: w.log.posted.length, removed: dialog.removed === true };
  } finally { Object.assign(globalThis, was); }
}

/** The page's module names no Google, makes no script, and asks no Trusted Types policy. */
export async function shellIsClean() {
  const text = await Deno.readTextFile(`${here}ads/app/ads.js`);
  const code = text.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
  return {
    google: /googlesyndication|doubleclick|adtrafficquality|gstatic|googleapis|google\.com|adsbygoogle/i.test(code),
    script: /createElement\(\s*['"`]script/.test(code),
    trustedTypes: /trustedTypes|createPolicy/.test(code),
    evalLike: /\beval\(|new Function\(/.test(code),
  };
}

// --- The ad document's service, and its policy --------------------------------------------------------------

/** The service's answer to a request. */
export async function served({ path = '/break', method = 'GET' } = {}) {
  const res = handle(new Request(`https://ads.example${path}`, { method }), await page());
  return { status: res.status, headers: Object.fromEntries(res.headers), body: await res.text() };
}

const directives = (csp) => Object.fromEntries(csp.split('; ').map((d) => { const [name, ...sources] = d.split(' '); return [name, sources]; }));

async function sha256b64(text) {
  return btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))));
}

/** What a page of the ad service holds, measured on it and not read from the CUE that made it: the policy's
 * directives, whether the hash it names is the document's one inline script's, how many scripts there
 * are, and that no script source is a whole host. */
export async function posture({ document, csp, site }) {
  const d = directives(csp);
  const inline = [...document.matchAll(/<script>([^]*?)<\/script>/g)].map((m) => m[1]);
  const scripts = (document.match(/<script/g) ?? []).length;
  const hash = (d['script-src'] ?? []).find((s) => s.startsWith("'sha256-"));
  const rest = (d['script-src'] ?? []).filter((s) => s !== hash);
  return {
    names: Object.keys(d),
    defaultSrc: d['default-src'],
    scriptSources: (d['script-src'] ?? []).length,
    hashMatches: inline.length === 1 && hash === `'sha256-${await sha256b64(inline[0])}'`,
    scripts, inlineScripts: inline.length,
    scriptPathScoped: rest.length > 0 && rest.every((s) => /^https:\/\/[^/*]+\/[^/].*\/$/.test(s)),
    scriptUnsafe: /unsafe|strict-dynamic|blob:|data:|\*/.test((d['script-src'] ?? []).join(' ')),
    sandbox: 'sandbox' in d,
    trustedTypes: 'trusted-types' in d || 'require-trusted-types-for' in d,
    frameAncestors: d['frame-ancestors'],
    site,
    httpsOnly: ['frame-src', 'connect-src', 'img-src'].every((n) => d[n].every((s) => s === 'data:' || s.startsWith('https://'))),
  };
}

/** The script sources of `csp` that name a host the deny list names (the host itself or any name under
 * it), and those that name a whole host, with `extra` first added to its script-src. */
export function audit({ csp, deny, extra = null }) {
  const policy = extra ? csp.replace(/script-src ([^;]*)/, `script-src $1 ${extra}`) : csp;
  const sources = (directives(policy)['script-src'] ?? []).filter((s) => !s.startsWith("'"));
  const host = (s) => new URL(s.replace('*.', 'wild.')).hostname;
  return {
    denied: sources.filter((s) => deny.some((n) => host(s) === n || host(s).endsWith(`.${n}`))),
    wholeHost: sources.filter((s) => new URL(s.replace('*.', 'wild.')).pathname === '/'),
  };
}

/** The real policy, audited. */
export async function auditReal({ deny, extra = null }) {
  return audit({ csp: (await page()).csp, deny, extra });
}

// --- The generate step's Caddyfile splice -----------------------------------------------------------------

const CSP = `  header @terminal Content-Security-Policy "default-src 'self'; script-src 'self'; frame-src 'self'"`;
const caddyfiles = {
  plain: ['(app) {', '  @terminal not path /docs/*', CSP, '  @ladder path /docs/*', `  header @ladder Content-Security-Policy "default-src 'self'; frame-ancestors 'self'"`, '  vars origin {$ORIGIN}', "  # the door's own sign-in", '  handle /auth/* {', '    reverse_proxy auth:8080', '  }', '}'],
  twice: ['(app) {', '  @terminal not path /docs/*', CSP, CSP, '  handle /auth/* {', '  }', '}'],
  ancestors: ['(app) {', '  @terminal not path /docs/*', CSP.replace(/"$/, `; frame-ancestors 'none'"`), '  handle /auth/* {', '  }', '}'],
};
const text = (name) => `${caddyfiles[name].join('\n')}\n`;

/** A fixture Caddyfile, by name: plain (as pronto writes it), twice (its policy line twice), ancestors (a
 * policy that already names who may frame the door). */
export function caddyfile(name) { return text(name); }

/** The policy line of the plain fixture, with the splice's addition. */
export function framed() { return CSP.replace(/"$/, `; frame-ancestors 'self'"`); }

/** What the rule's step (ads.nu `route`) does to the Caddyfile and writes beside it, run in turn on one app:
 * each `{publisher, caddy}` runs it as the app would, `publisher` naming one or not and `caddy` first putting
 * a fixture in place. Each says the step's exit, what it complained of, the Caddyfile after, ads_site.js after,
 * and ads/break.json after, if any. */
export async function route(steps) {
  const dir = await Deno.makeTempDir({ prefix: 'pronto-ads-route-' });
  const out = [];
  try {
    await Deno.mkdir(`${dir}/docker`);
    await Deno.mkdir(`${dir}/web`);
    for (const s of steps) {
      if (s.caddy) await Deno.writeTextFile(`${dir}/docker/Caddyfile`, text(s.caddy));
      const x = await exported(s.publisher ? {} : { publisher: '' });
      await Deno.writeTextFile(`${dir}/adsense.json`, JSON.stringify(x.adsense));
      const script = `cd ${JSON.stringify(dir)}; use ${JSON.stringify(`${here}ads/app/ads.nu`)}; open --raw adsense.json | ads route "web"`;
      const r = await run(`${here}saytw`, ['--script', 'tools.nu', 'nu', '-c', script], here);
      const read = (p) => Deno.readTextFile(`${dir}/${p}`).catch(() => null);
      out.push({ exit: r.code, failed: r.code !== 0, complained: /no single|already has frame-ancestors|no `handle/.test(r.err), caddy: await read('docker/Caddyfile'), site: await read('web/ads_site.js'), brk: await read('ads/break.json') });
    }
    return out;
  } finally { await Deno.remove(dir, { recursive: true }); }
}

/** How a Caddyfile differs from the plain fixture: the lines it lost, and counts of what the splice adds. */
export function against(after) {
  const before = text('plain').split('\n');
  const lines = after.split('\n');
  return {
    removed: before.filter((l) => !lines.includes(l)),
    policyIsOriginalPlusFrameAncestors: lines.includes(framed()),
    frameAncestors: lines.filter((l) => l.includes("frame-ancestors 'self'") && l.includes('@terminal')).length,
    xFrameOptions: lines.filter((l) => l === '  header @terminal X-Frame-Options SAMEORIGIN').length,
    adsTxt: lines.some((l) => l.includes('handle /ads.txt')),
  };
}

/** What ads_site.js names, as a page's module would read it. */
export async function siteOf(source) {
  const url = `data:text/javascript;base64,${btoa(source)}`;
  const m = await import(url);
  return { site: m.site, frame: m.frame };
}
