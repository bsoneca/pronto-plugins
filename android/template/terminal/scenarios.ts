// deno-lint-ignore-file no-explicit-any -- a step's argument is the scenario's free-form CUE data
// integrate@android's runner: an app's CUE scenarios (tests/scenarios/schema.cue) run on an
// emulator through the system's own touches. Tests are data; this is the runner, as
// tests/scenarios.ts is the web's. The page is the real DOM in the phone, so a scenario's
// selectors are the web's: the debug build's driver (Driver.kt, 127.0.0.1:8765 through adb forward)
// answers {"probe": selector} with the DOM's elements and {"bounds": id} with the drawn view's
// rectangle, and every action here is `adb shell input` on those pixels.
//
//   deno run -A --no-lock android/terminal/scenarios.ts <applicationId> <apk> <base> <scenario.cue>...
//
// <base> is the stack's address, or `stack` to bring one up on a slot (tests/slot.ts launch) and
// take it down after. Environment: SLOW (a factor on every wait, default 1), SHOTS (where a
// failure's screenshot goes, default android/app/build/shots), ADB (the adb to use).
//
// A page of another origin (a checkout, a provider) is the system browser's on a phone. The runner
// starts the app with `browser standin`, so the app keeps such an address for the driver ({"trips"})
// instead of opening a browser, and plays that browser itself, as the Unity host's StandInBrowser
// does: the scenario's next steps act on that page, and when it comes back to the app's origin the
// link is handed to the app as the OS would (`am start -a VIEW -d`).

import { parseHTML } from "npm:linkedom@0.18.4";
import { localRoots } from "./trust.ts";

// `flag` and `unless` say where a step runs (skips); they are not what it does.
const META = ["by", "timeout", "why", "fresh", "flag", "unless"];
export const KINDS = ["open", "see", "hidden", "attached", "count", "text", "value", "attr", "click", "fill", "select", "press", "submit", "keep", "pause", "shot", "closeDialogs", "signUp", "pay", "address", "response", "undisclosed", "fills"];

export type Probed = { id: string | null; text: string; value?: string; attrs: Record<string, string>; hidden: boolean; shown?: boolean };
export type Step = Record<string, unknown>;
export type Box = { x: number; y: number; w: number; h: number };

/** A scenario's failure: it names what did not hold. */
export class Fail extends Error {}

/** `{name}` of the kept values, `{uuid}` fresh each time; a name nobody kept fails, never passes as text. */
export function substitute(text: string, vars: Record<string, string>): string {
  return text.replace(/\{([A-Za-z_][\w.]*)\}/g, (_m, name: string) => {
    if (name === "uuid") return crypto.randomUUID();
    if (name in vars) return vars[name];
    throw new Fail(`nothing kept as {${name}}`);
  });
}

/** A step as the runner reads it: who, how long, why, and its one action or expectation. */
export function normalize(step: Step): { by?: string; timeout: number; why: string; kind: string; arg: any } {
  const kinds = Object.keys(step).filter((k) => !META.includes(k));
  if (kinds.length !== 1) throw new Fail(`a step has one action or expectation, this has ${kinds.length}: ${kinds.join(", ")}`);
  const kind = kinds[0];
  if (!KINDS.includes(kind)) throw new Fail(`unknown step kind "${kind}": the phone's runner does not know it`);
  return { by: step.by as string | undefined, timeout: (step.timeout as number | undefined) ?? 15, why: (step.why as string | undefined) ?? "", kind, arg: step[kind] };
}

/** Whose phone a step acts on: its `by`, else the one actor there is, else the one acting now, else "me". */
export function actorOf(step: Step, actors: Record<string, unknown> | undefined, current?: string): string {
  const names = Object.keys(actors ?? {});
  return (step.by as string | undefined) ?? (names.length === 1 ? names[0] : current ?? names[0] ?? "me");
}

/** The argument `adb shell input text` takes for a text: the shell's quotes around it, spaces as %s. */
export function inputText(text: string): string {
  if (/[^\x20-\x7e]/.test(text)) throw new Fail(`input text cannot type ${JSON.stringify(text)}: only printable ASCII is typed on a phone`);
  return "'" + text.replace(/'/g, "'\\''").replace(/ /g, "%s") + "'";
}

/**
 * A page's `?seed=N` made its own to a scenario and actor. The shell mints every row id it creates
 * from that seed, so two pages of one seed mint the same ids; a stack outlives the scenario (one per
 * run), so the second scenario's insert met the first one's row of the same id, which the database
 * answered 201 without writing, and the page never showed its game. The seed stays deterministic
 * (the same salt gives the same seed) and a path without one is left as it is.
 */
export function seeded(path: string, salt: string): string {
  let h = 2166136261;
  for (const ch of salt) h = Math.imul(h ^ ch.codePointAt(0)!, 16777619) >>> 0;
  return path.replace(/([?&]seed=)(\d+)/, (_m, head: string, n: string) => head + (((Number(n) + h) >>> 0) % 4294967296));
}

/** A shell word, whatever it holds. */
export const quote = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";

const KEYS: Record<string, string> = { Enter: "KEYCODE_ENTER", Tab: "KEYCODE_TAB", Escape: "KEYCODE_BACK", Backspace: "KEYCODE_DEL", Delete: "KEYCODE_FORWARD_DEL", ArrowUp: "KEYCODE_DPAD_UP", ArrowDown: "KEYCODE_DPAD_DOWN", ArrowLeft: "KEYCODE_DPAD_LEFT", ArrowRight: "KEYCODE_DPAD_RIGHT", Home: "KEYCODE_MOVE_HOME", End: "KEYCODE_MOVE_END", Space: "KEYCODE_SPACE" };

/** The Android key event a web key name is; a single character is typed, not a key. */
export function keyOf(name: string): { keyevent: string } | { text: string } {
  if (KEYS[name]) return { keyevent: KEYS[name] };
  if (name.length === 1) return { text: name };
  throw new Fail(`press: no key "${name}" on a phone`);
}

/** Where a box is against the display: it needs scrolling up (its content is below), down, or none. */
export function scrollFor(box: Box, display: { w: number; h: number }): "up" | "down" | null {
  const mid = box.y + box.h / 2;
  if (mid > display.h - 40) return "up";
  if (mid < 40) return "down";
  return null;
}

/** The middle of a box, in pixels. */
export const centre = (b: Box) => ({ x: Math.round(b.x + b.w / 2), y: Math.round(b.y + b.h / 2) });

/** Whether an address the browser reached ends its trip: the app's own origin, but not the door's own pages (/auth/ routes, a stand-in's /fake/ checkout). */
/**
 * `fills`: whether a drawn box fills the screen, null when it does, else what it lacks. The page must have asked for
 * the whole screen (the display is `fullscreen`: the system bars hidden), and the box must span at least `1 - within`
 * of the screen along one axis (a field square on a long phone fills its width, and its height in landscape).
 */
export function fills(box: Box | null, display: { mode: string; screen: { w: number; h: number } }, within = 0.1): string | null {
  if (display.mode !== "fullscreen") return `the display is ${display.mode}, the system bars shown`;
  if (!box) return "it is not drawn";
  const w = box.w / display.screen.w, h = box.h / display.screen.h;
  if (Math.max(w, h) >= 1 - within) return null;
  return `it spans ${Math.round(w * 100)}% of the screen's width and ${Math.round(h * 100)}% of its height, under ${Math.round((1 - within) * 100)}%`;
}

export function backTo(url: string, base: string): boolean {
  const u = new URL(url), b = new URL(base);
  return u.origin === b.origin && !/^\/(auth|fake)\//.test(u.pathname);
}

/** Whether a step does not run: it names a flag that is off (`flag`) or one that is on (`unless`), as the door answered. */
export function skips(step: Step, flags: Record<string, boolean>): boolean {
  if (typeof step.unless === "string" && flags[step.unless]) return true;
  return typeof step.flag === "string" && !flags[step.flag];
}

export type Fetched = { n: number; url: string; method: string; status: number; body: string };

/**
 * Whether the request a `response` step awaits was made, and answered as expected: `seen` false while no
 * request to `arg.to` by `arg.method` is among those the page made; else `fail` is what differs, if anything.
 */
export function responseHolds(arg: { to: string; method: string; status: number; matches?: string }, made: Fetched[]): { seen: boolean; fail?: string } {
  const r = made.find((x) => x.url.includes(arg.to) && x.method === arg.method);
  if (!r) return { seen: false };
  if (r.status !== arg.status) return { seen: true, fail: `${arg.method} ${arg.to} answered ${r.status}, not ${arg.status}: ${r.body.slice(0, 200)}` };
  if (arg.matches && !new RegExp(arg.matches).test(r.body)) return { seen: true, fail: `${arg.method} ${arg.to} answered ${r.body.slice(0, 200)}, which does not match ${arg.matches}` };
  return { seen: true };
}

/** The request a form's submission makes (HTML's): a GET puts the fields in the query, a POST in an urlencoded body. */
export function submission(page: string, action: string | null, method: string | null, fields: [string, string][]): { url: string; method: string; body?: string } {
  const post = (method ?? "get").toLowerCase() === "post";
  const target = new URL(action || page, page);
  const data = new URLSearchParams(fields).toString();
  target.hash = "";
  if (!post) { target.search = data; return { url: target.href, method: "GET" }; }
  return { url: target.href, method: "POST", body: data };
}

const lookup = (messages: Record<string, any>, key: string) => key.split(".").reduce((m, k) => m?.[k], messages) ?? messages[key];

/**
 * Whether an expectation holds of the elements a selector found (each with `shown`, the driver's
 * and the display's word: not hidden and drawn). null when it does; else what is the case.
 */
export function holds(kind: string, arg: any, els: Probed[], messages: Record<string, any> = {}): string | null {
  const first = els[0];
  switch (kind) {
    case "see": return els.some((e) => e.shown) ? null : `${els.length} found, none shown`;
    case "hidden": return els.some((e) => e.shown) ? "shown" : null;
    case "attached": return els.length ? null : "none in the page";
    case "count": {
      if (arg.is !== undefined && els.length !== arg.is) return `${els.length} found, want ${arg.is}`;
      if (arg.atLeast !== undefined && els.length < arg.atLeast) return `${els.length} found, want at least ${arg.atLeast}`;
      return null;
    }
    case "text": {
      if (!first) return "none in the page";
      const want = arg.msg ? lookup(messages, arg.msg) : arg.is;
      if (arg.msg && want === undefined) throw new Fail(`no message ${arg.msg}`);
      if (want !== undefined && first.text !== want) return `text is ${JSON.stringify(first.text)}, want ${JSON.stringify(want)}`;
      if (arg.not !== undefined && first.text === arg.not) return `text is ${JSON.stringify(first.text)}, want anything else`;
      if (arg.has !== undefined && !first.text.includes(arg.has)) return `text is ${JSON.stringify(first.text)}, want it to have ${JSON.stringify(arg.has)}`;
      return null;
    }
    case "value": {
      if (!first) return "none in the page";
      return (first.value ?? "") === arg.is ? null : `value is ${JSON.stringify(first.value ?? "")}, want ${JSON.stringify(arg.is)}`;
    }
    case "attr": {
      if (!first) return "none in the page";
      const v = first.attrs[arg.name];
      if (arg.is !== undefined && v !== arg.is) return `${arg.name} is ${JSON.stringify(v)}, want ${JSON.stringify(arg.is)}`;
      if (arg.matches !== undefined && !new RegExp(arg.matches).test(v ?? "")) return `${arg.name} is ${JSON.stringify(v)}, want it to match ${arg.matches}`;
      if (arg.below !== undefined && !(Number(v) < arg.below)) return `${arg.name} is ${JSON.stringify(v)}, want below ${arg.below}`;
      return null;
    }
  }
  throw new Fail(`unknown expectation "${kind}"`);
}

// ------------------------------------------------------------------ the device

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const slow = () => Number(Deno.env.get("SLOW") ?? "1") || 1;
const adbPath = () => Deno.env.get("ADB") ?? (Deno.env.get("ANDROID_HOME") ? `${Deno.env.get("ANDROID_HOME")}/platform-tools/adb` : "adb");

async function runBytes(cmd: string, args: string[], check = true): Promise<Uint8Array> {
  const out = await new Deno.Command(cmd, { args, stdin: "null", stdout: "piped", stderr: "piped" }).output();
  if (check && !out.success) throw new Fail(`${cmd} ${args.join(" ")}: ${new TextDecoder().decode(out.stderr).trim() || new TextDecoder().decode(out.stdout).trim()}`);
  return out.stdout;
}
async function run(cmd: string, args: string[], opts: { check?: boolean } = {}): Promise<string> {
  return new TextDecoder().decode(await runBytes(cmd, args, opts.check !== false));
}
const adb = (...args: string[]) => run(adbPath(), args);
/** One command line for the device's shell. */
const sh = (line: string) => adb("shell", line);

/** The driver's one-line socket: a retry while the app is (re)starting and nothing answers yet. */
async function ask(q: object): Promise<any | null> {
  let conn: Deno.Conn;
  try { conn = await Deno.connect({ hostname: "127.0.0.1", port: 8765 }); } catch { return undefined; }
  try {
    await conn.write(new TextEncoder().encode(JSON.stringify(q) + "\n"));
    const buf = new Uint8Array(1 << 20);
    let got = "";
    for (;;) {
      const n = await conn.read(buf);
      if (n === null) break;
      got += new TextDecoder().decode(buf.subarray(0, n));
      if (got.includes("\n")) break;
    }
    return got.trim() === "" ? undefined : JSON.parse(got);
  } catch { return undefined; } finally { try { conn.close(); } catch { /* closed */ } }
}

async function until<T>(what: string, seconds: number, probe: () => Promise<[T | null | false, string]>): Promise<T> {
  const end = Date.now() + seconds * 1000 * slow();
  let last = "";
  for (;;) {
    const [got, why] = await probe();
    if (got) return got;
    last = why;
    if (Date.now() > end) throw new Fail(`${what}: ${last} (waited ${seconds * slow()} s)`);
    await sleep(250);
  }
}

let display: { w: number; h: number } | undefined;
async function displaySize() {
  if (display) return display;
  const out = await sh("wm size");
  const m = [...out.matchAll(/(\d+)x(\d+)/g)].pop();
  if (!m) throw new Fail(`wm size answered ${JSON.stringify(out)}`);
  return display = { w: Number(m[1]), h: Number(m[2]) };
}

// ------------------------------------------------------------------ the stand-in browser

/** The browser of a trip away from the app: a page fetched on this machine, its forms submitted and its links followed. */
class StandIn {
  url = "";
  private doc: any = null;
  private readonly jar = new Map<string, Map<string, string>>();
  constructor(private readonly base: string, private readonly client: Deno.HttpClient) {}

  /** Goes to an address, following redirects; the link back when it reaches the app, else null with the page shown. */
  async go(url: string, method = "GET", body?: string): Promise<string | null> {
    for (let hops = 0; hops < 20; hops++) {
      if (backTo(url, this.base)) return url;
      const host = new URL(url).host;
      const headers: Record<string, string> = {};
      const cookies = this.jar.get(host);
      if (cookies?.size) headers.cookie = [...cookies].map(([k, v]) => `${k}=${v}`).join("; ");
      if (body !== undefined) headers["content-type"] = "application/x-www-form-urlencoded";
      const r = await fetch(url, { method, body, headers, redirect: "manual", client: this.client });
      for (const set of r.headers.getSetCookie()) {
        const kv = set.split(";")[0], i = kv.indexOf("=");
        if (i > 0) { if (!this.jar.has(host)) this.jar.set(host, new Map()); this.jar.get(host)!.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim()); }
      }
      const to = r.headers.get("location");
      if (r.status >= 300 && r.status < 400 && to) {
        await r.body?.cancel();
        url = new URL(to, url).href;
        if (r.status !== 307 && r.status !== 308) { method = "GET"; body = undefined; }
        continue;
      }
      const html = await r.text();
      // A page that moves on by itself is followed, as a browser would.
      const refresh = html.match(/<meta[^>]+http-equiv=["']?refresh["']?[^>]*content=["']?\d+\s*;\s*url=([^"'>]+)/i);
      if (refresh) { url = new URL(refresh[1], url).href; method = "GET"; body = undefined; continue; }
      if (r.status >= 400) throw new Fail(`the browser got ${r.status} at ${url}`);
      this.url = url;
      this.doc = (parseHTML(html) as any).document;
      return null;
    }
    throw new Fail(`the browser went round in redirects from ${url}`);
  }

  find(selector: string): (Probed & { box?: Box })[] {
    return [...this.doc.querySelectorAll(selector)].map((el: any, i: number) => {
      const hidden = el.closest("[hidden]") !== null;
      return { id: `away-${i}`, text: el.textContent ?? "", value: el.localName === "textarea" ? el.textContent : el.getAttribute("value") ?? undefined, attrs: Object.fromEntries([...el.attributes].map((a: any) => [a.name, a.value])), hidden, shown: !hidden };
    });
  }

  fill(selector: string, value: string) {
    const el = this.doc.querySelector(selector);
    if (!el) throw new Fail(`fill ${selector}: nothing on the page at ${this.url}`);
    if (el.localName === "textarea") el.textContent = value; else el.setAttribute("value", value);
  }

  /** A click: a link is followed, a form's submit button submits it; the link back if that ends the trip. */
  click(selector: string): Promise<string | null> {
    const el = this.doc.querySelector(selector);
    if (!el) throw new Fail(`click ${selector}: nothing on the page at ${this.url}`);
    const link = el.closest("a[href]");
    if (link) return this.go(new URL(link.getAttribute("href"), this.url).href);
    const form = el.closest("form");
    const type = (el.getAttribute("type") ?? (el.localName === "button" ? "submit" : "")).toLowerCase();
    if (!form || type !== "submit") throw new Fail(`click ${selector}: the browser follows links and submits forms, and this is neither`);
    const fields: [string, string][] = [];
    for (const f of form.querySelectorAll("input[name], select[name], textarea[name]")) {
      if (f.hasAttribute("disabled")) continue;
      const kind = (f.getAttribute("type") ?? "text").toLowerCase();
      if (f.localName === "input" && ["submit", "button", "reset", "image", "file"].includes(kind)) continue;
      if ((kind === "checkbox" || kind === "radio") && !f.hasAttribute("checked")) continue;
      if (f.localName === "select") {
        const o = f.querySelector("option[selected]") ?? f.querySelector("option");
        if (o) fields.push([f.getAttribute("name"), o.getAttribute("value") ?? o.textContent]);
      } else fields.push([f.getAttribute("name"), f.localName === "textarea" ? f.textContent : f.getAttribute("value") ?? (kind === "checkbox" || kind === "radio" ? "on" : "")]);
    }
    if (el.getAttribute("name")) fields.push([el.getAttribute("name"), el.getAttribute("value") ?? ""]);
    const s = submission(this.url, el.getAttribute("formaction") ?? form.getAttribute("action"), el.getAttribute("formmethod") ?? form.getAttribute("method"), fields);
    return this.go(s.url, s.method, s.body);
  }
}

class Phone {
  messages: Record<string, any> = {};
  /** The scenario running: it salts the seed of every page it opens (seeded). */
  scenario = "";
  private page: StandIn | null = null;
  private client?: Deno.HttpClient;
  constructor(readonly id: string, readonly base: string) {}

  /** The page of a trip away from the app, if it left for one: the driver keeps the address it left for. */
  async away(): Promise<StandIn | null> {
    if (this.page) return this.page;
    const trips: string[] | undefined = await ask({ trips: true });
    if (!trips?.length) return null;
    this.client ??= Deno.createHttpClient({ caCerts: Object.values(await localRoots()) });
    const page = new StandIn(this.base, this.client);
    const back = await page.go(trips[trips.length - 1]);
    if (back) await this.deliver(back); else this.page = page;
    return this.page;
  }

  /** The link back from a trip, handed to the app as the OS hands it an App Link. */
  private async deliver(url: string) {
    this.page = null;
    await sh(`am start -W -a android.intent.action.VIEW -d ${quote(url)} -n ${this.id}/.MainActivity`);
  }

  /** The elements a selector finds, each with whether it is shown (not hidden and drawn) and, if so, its box. */
  async find(selector: string, boxes = true): Promise<(Probed & { box?: Box })[] | undefined> {
    const page = await this.away();
    if (page) return page.find(selector);
    const els: Probed[] | undefined = await ask({ probe: selector });
    if (!els) return undefined;
    const out: (Probed & { box?: Box })[] = els;
    if (boxes) {
      await Promise.all(out.map(async (e) => {
        const b = e.id && !e.hidden ? await ask({ bounds: e.id }) : null;
        if (b) e.box = b;
        e.shown = !e.hidden && !!b;
      }));
    } else for (const e of out) e.shown = false;
    return out;
  }

  async start(path: string, actor: string) {
    // The device's ports to this machine are tied to adb's connection, which a busy emulator drops
    // and remakes: they are made again before every start, so the app always reaches the stack.
    await adb("forward", "tcp:8765", "tcp:8765");
    const door = this.base.match(/^https:\/\/localhost:(\d+)/);
    if (door) await adb("reverse", `tcp:${door[1]}`, `tcp:${door[1]}`);
    this.page = null;
    await sh(`am start -S -n ${this.id}/.MainActivity --es base ${quote(this.base)} --es path ${quote(seeded(path, `${this.scenario}/${actor}`))} --es actor ${quote(actor)} --es browser standin`);
    await until(`${actor}'s terminal at ${path}`, 30, async () => {
      const ready = await this.find("html[data-terminal-ready]", false);
      return [ready && ready.length > 0 ? ready : null, ready ? "the terminal has not booted" : "the driver does not answer"];
    });
  }

  /** The address the page is at: the browser's, on a trip away from the app, else the app's own. */
  async where(): Promise<string | undefined> {
    const page = await this.away();
    return page ? page.url : await ask({ where: true });
  }

  /** The session the app holds ({token, id, guest}), or null before it has one. */
  session(): Promise<{ token: string; id: string; guest: boolean } | null | undefined> {
    return ask({ session: true });
  }

  /** A click the script makes on the DOM's element, whatever the screen shows. */
  async domClick(selector: string): Promise<boolean> {
    return (await ask({ click: selector })) === true;
  }

  /** The requests the page made from number `from` on, and how many it has made. */
  fetches(from: number): Promise<{ count: number; items: Fetched[] } | undefined> {
    return ask({ fetches: from });
  }

  private readonly flags = new Map<string, Promise<boolean>>();
  /** A flag as the door answers it (OFREP), asked once; a door that does not answer is a failure, never a reason to skip. */
  flagOn(name: string): Promise<boolean> {
    let asked = this.flags.get(name);
    if (!asked) {
      asked = (async () => {
        this.client ??= Deno.createHttpClient({ caCerts: Object.values(await localRoots()) });
        const res = await fetch(new URL(`/ofrep/v1/evaluate/flags/${name}`, this.base).href, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ context: {} }), client: this.client });
        const value = res.ok ? (await res.json()).value : null;
        if (typeof value !== "boolean") throw new Fail(`the flags did not answer at ${this.base}/ofrep/: ${name} is ${JSON.stringify(value)}`);
        return value;
      })();
      this.flags.set(name, asked);
    }
    return asked;
  }

  /** The keyboard put away by the app itself: a BACK key would reach the page whenever no keyboard was up. */
  async hideKeyboard() {
    await ask({ hideKeyboard: true });
  }

  /** The first of the selectors shown, scrolled onto the screen. */
  shownOf(selectors: string[], seconds: number, what: string) {
    return until(what, seconds, async () => {
      for (const s of selectors) {
        const els = await this.find(s);
        const el = els?.find((e) => e.shown);
        if (el) return [await this.scrolled(s, el), ""];
      }
      return [null, `nothing shown matches ${selectors.join(" | ")}`];
    });
  }

  private async scrolled(selector: string, el: Probed & { box?: Box }) {
    const size = await displaySize();
    for (let i = 0; i < 12; i++) {
      const way = scrollFor(el.box!, size);
      if (!way) return el;
      const x = Math.round(size.w / 2), a = Math.round(size.h * 0.7), b = Math.round(size.h * 0.3);
      await sh(`input swipe ${x} ${way === "up" ? a : b} ${x} ${way === "up" ? b : a} 300`);
      const now = (await this.find(selector))?.find((e) => e.id === el.id && e.shown);
      if (now) el = now;
    }
    throw new Fail(`${selector} cannot be scrolled onto the screen`);
  }

  /** A tap on what is drawn, once it is stable (Playwright's word): no redraw and the same box over
   * a short while, since a tap across a redraw lands on a view that is gone. */
  async tap(el: Probed & { box?: Box }) {
    let box = el.box!;
    await until("a stable screen", 15, async () => {
      const before = await ask({ frames: true });
      await new Promise((r) => setTimeout(r, 250 * slow()));
      const after = await ask({ frames: true });
      const now = el.id ? await ask({ bounds: el.id }) : box;
      const still = before !== undefined && before === after && now && now.x === box.x && now.y === box.y && now.w === box.w && now.h === box.h;
      if (now) box = now;
      return [still ? true : null, `the screen keeps redrawing (${before} then ${after} draws)`];
    });
    const { x, y } = centre(box);
    await sh(`input tap ${x} ${y}`);
  }

  async clickOf(selectors: string[], seconds: number) {
    if (await this.away()) {
      const sel = await until(`click ${selectors.join(" | ")}`, seconds, () => {
        const hit = selectors.find((s) => this.page!.find(s).some((e) => e.shown));
        return Promise.resolve([hit ?? null, `nothing on the page at ${this.page!.url} matches ${selectors.join(" | ")}`]);
      });
      const back = await this.page!.click(sel);
      if (back) await this.deliver(back);
      return;
    }
    await this.hideKeyboard();
    await this.tap(await this.shownOf(selectors, seconds, `click ${selectors.join(" | ")}`));
  }

  async fillIn(selector: string, value: string, seconds: number) {
    if (await this.away()) return this.page!.fill(selector, value);
    await this.hideKeyboard();
    const el = await this.shownOf([selector], seconds, `fill ${selector}`);
    await this.tap(el);
    const cur = (el.value ?? "").length;
    // The end of the text, then as many deletes as it holds: a select-all that every Android keeps.
    await sh("input keyevent KEYCODE_MOVE_END" + " KEYCODE_DEL".repeat(cur));
    if (value !== "") await sh(`input text ${inputText(value)}`);
    // The DOM got it: DivKit's variable took the typing through to the interpreter.
    await until(`fill ${selector}`, seconds, async () => {
      const now = (await this.find(selector, false))?.[0];
      return [now && (now.value ?? "") === value ? now : null, `the page has ${JSON.stringify(now?.value)}, typed ${JSON.stringify(value)}`];
    });
  }
}

// ------------------------------------------------------------------ the scenarios

type Scenario = { actors?: Record<string, { name: string }>; steps: Step[] };

async function runScenario(name: string, sc: Scenario, phone: Phone, dir: string): Promise<void> {
  const vars: Record<string, string> = {};
  const opened: Record<string, string> = {};
  let current: string | undefined;
  phone.scenario = name;
  await adb("logcat", "-c");
  await sh(`pm clear ${phone.id}`);
  const flagsOn = new Map<string, boolean>();
  let i = 0;
  const perform = async (raw: Step): Promise<void> => {
      const { timeout, kind, arg } = normalize(raw);
      const actor = actorOf(raw, sc.actors, current);
      const sub = (s: string) => substitute(s, vars);
      if (kind === "open") {
        const path = sub(arg as string);
        opened[actor] = path;
        current = actor;
        await phone.start(path, actor);
        return;
      }
      if (actor !== current) {
        if (!(actor in opened)) throw new Fail(`${actor} has no page open`);
        current = actor;
        await phone.start(opened[actor], actor);
      }
      switch (kind) {
        case "click": await phone.clickOf((Array.isArray(arg) ? arg : [arg]).map(sub), timeout); break;
        case "fill": await phone.fillIn(sub(arg.in), sub(arg.value), timeout); break;
        case "select": {
          const sel = sub(arg.in), value = sub(arg.value);
          await phone.clickOf([sel], timeout);
          await phone.clickOf([`${sel} option[value="${value}"]`, `option[value="${value}"]`], timeout);
          await until(`select ${sel}`, timeout, async () => {
            const now = (await phone.find(sel, false))?.[0];
            return [now && now.value === value ? now : null, `value is ${JSON.stringify(now?.value)}, want ${JSON.stringify(value)}`];
          });
          break;
        }
        case "submit": await phone.clickOf([`${sub(arg)} [type=submit]`, `${sub(arg)} button:not([type=button])`], timeout); break;
        case "press": {
          const key = keyOf(arg);
          await sh("keyevent" in key ? `input keyevent ${key.keyevent}` : `input text ${inputText(key.text)}`);
          break;
        }
        case "keep":
          for (const [v, how] of Object.entries<any>(arg)) {
            const el = await until(`keep ${v}`, timeout, async () => {
              const els = await phone.find(sub(how.of), false);
              return [els?.[0] ?? null, `nothing matches ${how.of}`];
            });
            vars[v] = how.attr ? el.attrs[how.attr] ?? "" : how.value ? el.value ?? "" : el.text;
          }
          break;
        case "undisclosed": {
          // Nothing the app keeps in its private directory (databases, preferences, files) holds the text:
          // the debug build's run-as reads it. code_cache is not the app's data: it holds the compiled bytecode of
          // the app's own scripts (TerminalEngine), whose source has words like "Anonymous" in it. The sealed
          // store must exist, or an empty directory would pass.
          const text = sub(arg as string);
          const dbs = await sh(`run-as ${phone.id} ls databases`);
          if (!dbs.split(/\s+/).includes("terminal-sealed.db")) throw new Fail(`no sealed store in ${phone.id}'s databases: ${dbs.trim()}`);
          const out = await new Deno.Command(adbPath(), { args: ["shell", `run-as ${phone.id} grep -rlaF --exclude-dir=code_cache -- ${quote(text)} .`], stdin: "null", stdout: "piped", stderr: "piped" }).output();
          const found = new TextDecoder().decode(out.stdout).trim();
          if (out.code === 0 && found) throw new Fail(`${JSON.stringify(text)} is in the app's private files in plain text: ${found.split("\n").join(", ")}`);
          if (out.code !== 1) throw new Fail(`run-as grep exited ${out.code}: ${new TextDecoder().decode(out.stderr).trim() || found}`);
          break;
        }
        case "fills": {
          // The page asked for the whole screen and the element spans it (fills): the driver's display and bounds.
          const sel = sub(arg.of);
          await until(`fills ${sel}`, timeout, async () => {
            const display = await ask({ display: true });
            if (!display) return [null, "the driver does not answer"];
            const el = (await phone.find(sel, false))?.find((e) => e.id && !e.hidden);
            const box = el ? await ask({ bounds: el.id }) : null;
            const lack = fills(box, display, arg.within ?? 0.1);
            return [lack === null ? true : null, el ? lack! : `nothing matches ${sel}`];
          });
          break;
        }
        case "pause": await sleep(Number(arg) * 1000 * slow()); break;
        case "shot": {
          await Deno.mkdir(dir, { recursive: true });
          await Deno.writeFile(`${dir}/${name}-${sub(arg)}.png`, await runBytes(adbPath(), ["exec-out", "screencap", "-p"]));
          break;
        }
        case "signUp": {
          // The terminal's passkey register, which the app shows nobody (decision-signup): a test's own
          // way to a new account. Clicked on the DOM even where CSS hides it, then an account's session
          // (not a guest's) is awaited.
          await until("the register control", timeout, async () => [(await phone.find("body > nav .shell-register", false))?.length ? true : null, "none in the page"]);
          if (!await phone.domClick("body > nav .shell-register")) throw new Fail("signUp: nothing to click");
          await until("an account's session", Math.max(timeout, 60), async () => {
            const s = await phone.session();
            return [s && !s.guest ? true : null, s === undefined ? "the driver does not answer" : s === null ? "no session yet" : "the session is a guest's"];
          });
          break;
        }
        case "pay": {
          // The checkout the app left for (the stand-in's), paid at a press; the trip ends when it is back at the app's origin.
          await until("the checkout opens", timeout, async () => [await phone.away(), "the app has not left for a checkout"]);
          await phone.clickOf(["button[value=pay]"], timeout);
          await until("back at the app", timeout, async () => {
            const at = await phone.where();
            return [at && backTo(at, phone.base) ? true : null, `at ${at}`];
          });
          break;
        }
        case "address": {
          const re = new RegExp(sub(arg.matches));
          await until("the address", timeout, async () => {
            const at = await phone.where();
            return [at !== undefined && re.test(at) ? true : null, `at ${at}`];
          });
          break;
        }
        case "response": {
          // Started before the step that causes it: the requests made from now on are the ones read.
          const from = (await phone.fetches(1 << 30))?.count ?? 0;
          await perform({ by: raw.by, timeout: raw.timeout, ...arg.when });
          const to = sub(arg.to);
          await until(`${arg.method} ${to}`, timeout, async () => {
            const made = await phone.fetches(from);
            if (!made) return [null, "the driver does not answer"];
            const r = responseHolds({ ...arg, to }, made.items);
            if (r.fail) throw new Fail(r.fail);
            return [r.seen ? true : null, `no ${arg.method} ${to} made`];
          });
          break;
        }
        case "closeDialogs": {
          const open = await phone.find("dialog[open]", false);
          if (open?.length) {
            await sh("input keyevent KEYCODE_BACK");
            await until("closeDialogs", timeout, async () => [(await phone.find("dialog[open]", false))?.length === 0 || null, "a dialog is still open"]);
          }
          break;
        }
        default: {
          // An expectation: asked again until it holds. `see` and the others needing a drawing ask for the boxes.
          const sel = sub(arg.of ?? arg);
          const a = typeof arg === "object" ? { ...arg, of: undefined, is: typeof arg.is === "string" ? sub(arg.is) : arg.is, has: typeof arg.has === "string" ? sub(arg.has) : arg.has, not: typeof arg.not === "string" ? sub(arg.not) : arg.not } : arg;
          await until(`${kind} ${sel}`, timeout, async () => {
            const els = await phone.find(sel, kind === "see" || kind === "hidden");
            if (!els) return [null, "the driver does not answer"];
            const why = holds(kind, a, els, phone.messages);
            return [why === null ? true : null, why ?? ""];
          });
        }
      }
  };
  try {
    for (; i < sc.steps.length; i++) {
      const raw = sc.steps[i];
      for (const f of [raw.flag, raw.unless]) if (typeof f === "string") flagsOn.set(f, await phone.flagOn(f));
      if (skips(raw, Object.fromEntries(flagsOn))) continue;
      await perform(raw);
    }
  } catch (e) {
    const why = (sc.steps[i] as Step | undefined)?.why;
    const detail = `${e instanceof Error ? e.message : e} [step ${i + 1} of ${sc.steps.length}${why ? `, why: ${why}` : ""}]`;
    await Deno.mkdir(dir, { recursive: true });
    const shot = `${dir}/${name}-fail.png`;
    await Deno.writeFile(shot, await runBytes(adbPath(), ["exec-out", "screencap", "-p"], false)).catch(() => {});
    const log = (await run(adbPath(), ["logcat", "-d", "-s", "pronto:*"], { check: false })).trim().split("\n").filter((l) => !l.includes("unsupported on Android")).slice(-60).join("\n");
    console.error(`--- logcat pronto (tail)\n${log}\n--- screenshot ${shot}`);
    throw new Fail(detail);
  }
}

// ------------------------------------------------------------------ the stack

/** A stack on a slot of the machine's budget (tests/slot.ts launch), until `stop`. */
async function stack(): Promise<{ base: string; stop: () => Promise<void> }> {
  try { await Deno.stat("tests/slot.ts"); } catch { throw new Fail("base `stack` needs the app's tests/slot.ts: pass the base of a stack that is up (PRONTO_BASE)"); }
  const child = new Deno.Command(Deno.execPath(), { args: ["run", "-A", "tests/slot.ts", "launch"], env: { STACK_WEIGHT: Deno.env.get("STACK_WEIGHT") ?? "1" }, stdin: "null", stdout: "inherit", stderr: "piped" }).spawn();
  let seen: (url: string) => void = () => {};
  const url = new Promise<string>((r) => { seen = r; });
  (async () => {
    let tail = "";
    for await (const chunk of child.stderr) {
      const text = new TextDecoder().decode(chunk);
      Deno.stderr.writeSync(chunk);
      tail += text;
      const m = tail.match(/the stack coming up at (https?:\/\/[^\s,]+)/);
      if (m) seen(m[1]);
    }
  })();
  const stop = async () => {
    try { child.kill("SIGTERM"); } catch { /* gone */ }
    await Promise.race([child.status, sleep(120_000)]);
  };
  const base = await Promise.race([url, child.status.then(() => { throw new Fail("the stack went down before it was up"); })]);
  try {
    await until(`the stack at ${base}`, 600, async () => {
      const code = await run("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", base + "/"], { check: false });
      return [/^[1-4]\d\d$/.test(code.trim()) ? true : null, `answers ${code.trim()}`];
    });
  } catch (e) { await stop(); throw e; }
  return { base, stop };
}

// ------------------------------------------------------------------ main

async function main() {
  const [id, apk, baseArg, ...files] = Deno.args;
  if (!id || !apk || !baseArg) throw new Fail("usage: scenarios.ts <applicationId> <apk> <base-url|stack> <scenario.cue>...");
  if (!files.length) throw new Fail("no scenarios: name the app's scenario files in android/android.json {\"scenarios\": [...]}");
  const exported = await new Deno.Command("cue", { args: ["export", ...files, "-e", "scenarios", "--out", "json"], stdin: "null", stdout: "piped", stderr: "piped" }).output();
  if (!exported.success) throw new Fail(`cue export ${files.join(" ")}: ${new TextDecoder().decode(exported.stderr)}`);
  const scenarios: Record<string, Scenario> = JSON.parse(new TextDecoder().decode(exported.stdout));
  const names = Object.keys(scenarios);
  if (!names.length) throw new Fail(`${files.join(", ")} hold no scenarios`);

  const running = baseArg === "stack" ? await stack() : { base: baseArg, stop: async () => {} };
  const dir = Deno.env.get("SHOTS") ?? "android/app/build/shots";
  const results: string[] = [];
  let failed = 0;
  try {
    await adb("install", "-r", apk);
    await adb("forward", "tcp:8765", "tcp:8765");
    const door = running.base.match(/^https:\/\/localhost:(\d+)/);
    if (door) await adb("reverse", `tcp:${door[1]}`, `tcp:${door[1]}`);
    const phone = new Phone(id, running.base);
    phone.messages = await Deno.readTextFile("messages/en.json").then(JSON.parse).catch(() => ({}));
    for (const name of names) {
      const t = Date.now();
      try {
        await runScenario(name, scenarios[name], phone, dir);
        results.push(`pass  ${name}  ${((Date.now() - t) / 1000).toFixed(1)} s`);
      } catch (e) {
        failed++;
        results.push(`FAIL  ${name}  ${((Date.now() - t) / 1000).toFixed(1)} s  ${e instanceof Error ? e.message : e}`);
      }
    }
  } finally {
    await running.stop();
  }
  console.log(results.join("\n"));
  if (failed) throw new Fail(`${failed} of ${names.length} scenarios failed`);
}

if (import.meta.main) {
  try { await main(); } catch (e) {
    console.error(e instanceof Error ? e.message : e);
    Deno.exit(1);
  }
}
