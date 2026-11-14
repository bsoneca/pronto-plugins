// The online acceptance's runner: the scenarios of tests/scenarios/*.cue (their schema says what
// each step does), run against the app at APP_URL, else the first argument. Scenarios run side by
// side, at most `parallel` at once (`deployedParallel` against a deployed app), each to its end
// whatever the others answer; a scenario stops at its first failing step. SHOTS, when set, keeps a
// screenshot of each `shot` step and of every page when a step fails; SLOW, when set, slows every
// page as a preview's are (tests/slow.ts). Run by the integrate verb (program.cue, check "online")
// and verify@gcp.
//
// Every pronto app's copy is the same (pronto-plugins' harness). What is the app's own is its:
//   - tests/scenarios/*.cue: its scenarios, and the facts the runner reads beside them (schema.cue
//     names each with its default: the screen and locale its actors read the app on, its messages,
//     how a page is waited for, the sources the selection judges by bytes, the stack's database, the
//     tester's sign-in, and the app's own step kinds, `#Gestures`);
//   - tests/scenarios/app.ts, when it has one: what its own step kinds do, and the few moments the
//     app adds to (a browser's first script, a page's load, a sign-up, a payment, a failure's
//     report). Its default export is a `Hooks`; it imports nothing of this file but its types.
import { select, sha } from "./scenarios/select.ts";
import { devices, request, type APIRequestContext, type BrowserContext, type CDPSession, type Locator, type Page } from "npm:playwright@1.61.1";
import { launch as launchBrowser } from "./browser.ts";
import { gate, slow, slowCpu, slowDown } from "./slow.ts";
import { early } from "./scenarios/early.ts";

const URL_ = Deno.env.get("APP_URL") ?? Deno.args[0];
if (!URL_) throw new Error("APP_URL or an argument names the app");
const SHOTS = Deno.env.get("SHOTS");
if (SHOTS) await Deno.mkdir(SHOTS, { recursive: true });
const here = (p: string) => new URL(p, import.meta.url);
const appName = decodeURIComponent(here("..").pathname.replace(/\/$/, "").split("/").at(-1)!);

// The scenarios, as CUE exports them.
export type Step = Record<string, any> & { by?: string; timeout?: number; why?: string };
type ActorDef = { name: string; device?: string; locale?: string } & Record<string, any>;
type Scenario = { id: string; slow?: true; accepts: string[]; actors: Record<string, ActorDef>; steps: Step[]; flags?: string[]; production?: true; standin?: true };
type Screen = { viewport?: { width: number; height: number }; device?: string };
type Spec = {
  parallel: number;
  deployedParallel: number;
  flakes: { app?: string; priority: string; file: string[]; retry: boolean };
  screen: Screen;
  screens?: Record<string, Screen>;
  locale: string;
  messages: string;
  loaded: { screen?: string; adopted: boolean };
  select: { client: string[]; derived: string[]; inert: string[]; live: string[] };
  database?: string;
  signIn?: { open: string[]; passkey: string };
  scenarios: Record<string, Scenario>;
};
const dir = here("./scenarios/").pathname;
const files = [...Deno.readDirSync(dir)].filter((f) => f.name.endsWith(".cue")).map((f) => dir + f.name).sort();
const exported = await new Deno.Command(Deno.env.get("CUE") ?? "cue", { args: ["export", ...files, "--out", "json"], stdout: "piped", stderr: "piped" }).output();
if (!exported.success) throw new Error("the scenarios do not export: " + new TextDecoder().decode(exported.stderr));
const spec = JSON.parse(new TextDecoder().decode(exported.stdout)) as Spec;

// The app's own: its step kinds and the moments it adds to (tests/scenarios/app.ts), when it has any.
export type Hooks = {
  // An actor's browser, before its first page: init scripts the app's pages read (a stand-in for a
  // phone's contact picker, a setting of the page's own).
  context?: (ctx: BrowserContext, def: ActorDef) => Promise<void>;
  // A tab just opened, its listeners set: what the app keeps of it for a failure's report.
  tab?: (run: Run, a: Actor) => void;
  // A page loaded (open, reload, revisit, a payment's return): instead of the runner's own wait.
  loaded?: (run: Run, p: Page) => Promise<void>;
  // After the terminal's passkey sign-up made an account (`signUp`): instead of a load's wait.
  signedUp?: (run: Run, a: Actor) => Promise<unknown>;
  // Back from a checkout (`pay`), once loaded.
  paid?: (run: Run, a: Actor) => Promise<unknown>;
  // The app's own step kinds (schema.cue's `#Gestures`), by kind.
  steps?: Record<string, (run: Run, st: Step, a: Actor) => Promise<unknown>>;
  // What a failure says of an actor's page besides the runner's own lines.
  report?: (run: Run, a: Actor) => Promise<string[]>;
};
const hooksFile = here("./scenarios/app.ts");
const hooks: Hooks = (await Deno.stat(hooksFile).catch(() => null)) ? (await import(hooksFile.href)).default : {};

// Production is never a place for a scenario that is not marked `production` (the schema holds those to
// one actor at most, who reads anonymously with GET requests, and writes and buys nothing): where
// FLAGS_TESTER is set, or APP_URL is flags_spec.cue's flagsLive.url, every scenario run must be one. Read
// from the file, not exported, since CUE takes the app's whole package half a minute to load. An app with
// no flags_spec.cue, or one whose flags are released nowhere (no `flagsLive`, prontoweeper's), has no such address.
const flagsSpec = await Deno.readTextFile(here("../flags_spec.cue")).catch(() => null);
const liveUrl = flagsSpec?.match(/^flagsLive: url: "(https:\/\/[^"]+)"/m)?.[1];
if (flagsSpec !== null && /^flagsLive:/m.test(flagsSpec) && !liveUrl) throw new Error("flags_spec.cue names no flagsLive.url");
const TESTER = Deno.env.get("FLAGS_TESTER");
const onProduction = !!TESTER || (!!liveUrl && new URL(URL_).hostname === new URL(liveUrl).hostname);
// Deployed: a dotted host that is not this machine's (a stack's door is localhost or a bare name).
const deployed = (h: string) => h.includes(".") && !/^(127\.0\.0\.1|\[::1\])$|(^|\.)localhost$/.test(h);
// The texts a `msg` names, when the app has the file (an app whose texts are its spec's has none).
const messages = JSON.parse(await Deno.readTextFile(here("../" + spec.messages)).catch(() => "{}")) as Record<string, string>;

// The tester's sign-ins, one at a time across the scenarios this run holds side by side, and the passkey
// counter the last one imported (the signIn step).
let testerCount = 0;
// The counter's clock, in tenths of a second: a run's sign-ins (two counts each, each taking more than 0.2 s)
// never pass it, so the next run, however soon, starts above the last count the server saw. Seconds did
// not hold: fifteen sign-ins used thirty counts in ten seconds, and a run started within the half minute
// after was refused. It starts above every count the seconds clock gave (1.79e9 by 2026-11-09) and stays
// under a counter's 2^32 until 2034.
const testerClock = () => 1_800_000_000 + Math.floor((Date.now() - Date.UTC(2026, 10, 10)) / 100);
let testerQueue: Promise<void> = Promise.resolve();
const testerTurn = (): Promise<() => void> => {
  let release!: () => void;
  const mine = new Promise<void>((r) => { release = r; });
  const turn = testerQueue.then(() => release);
  testerQueue = testerQueue.then(() => mine);
  return turn;
};

const launch = () => launchBrowser({
  ...(Deno.env.get("CHANNEL") ? { channel: Deno.env.get("CHANNEL") } : {}),
  // Muted: a run never plays a sound on the machine it runs on.
  args: ["--ignore-certificate-errors", "--mute-audio", "--use-gl=angle", "--enable-unsafe-swiftshader"],
});
// One browser for every scenario. A wedge can take it down with it (the rehearsal of 2026-11-08
// 14:26 BRT, PRONTO-32): the scenario run again for its wedge then found it closed and failed at its
// first step. So an actor's context is opened in a browser that is still there, launched anew if not.
let browser = await launch();
let relaunching: Promise<unknown> | null = null;
async function liveBrowser() {
  while (!browser.isConnected()) {
    relaunching ??= launch().then((b) => { browser = b; }).finally(() => { relaunching = null; });
    await relaunching;
  }
  return browser;
}
const anon: APIRequestContext = await request.newContext({ ignoreHTTPSErrors: true });
const pageErrors: string[] = [];

// A flag (flags_spec.cue) as the door answers it, asked once and held: a step marked with one runs
// only where that flag is on. A door whose flags do not answer is a failure, never a reason to skip.
// As the tester when there is one (FLAGS_TESTER): a flip's canary turns a flag on for the tester alone.
const flags = new Map<string, Promise<boolean>>();
// The door names flagd's account from the verified session alone (a Bearer token, its /auth/door), never from a
// targetingKey in the body: the tester is asked for with the tester's own token, and not kept, since a page
// signed out and signed in reads two values.
async function ofrepAsk(name: string, token?: string): Promise<boolean> {
  const res = await anon.fetch(new URL(`/ofrep/v1/evaluate/flags/${name}`, URL_).href, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, data: JSON.stringify({ context: {} }), failOnStatusCode: false });
  const value = res.ok() ? (await res.json()).value : null;
  if (typeof value !== "boolean") throw new Error(`the flags did not answer at ${URL_}/ofrep/: ${name} is ${JSON.stringify(value)}`);
  return value;
}
function flagOn(name: string): Promise<boolean> {
  let asked = flags.get(name);
  if (!asked) { asked = ofrepAsk(name); flags.set(name, asked); }
  return asked;
}

export type Actor = { key: string; name: string; def: ActorDef; ctx: BrowserContext; page: Page; cdp: CDPSession; auth: string; consoles: string[]; trail: string[]; asked: string[]; hot: boolean; releases: Map<string, () => void>; data: Record<string, any> };
export const sleep = (s: number) => new Promise((r) => setTimeout(r, s * 1000));
export const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
// Every value of `want` is in `got` (an array's every element, when `want` is a one-element array).
function holds(got: any, want: any): boolean {
  if (Array.isArray(want)) {
    if (!Array.isArray(got)) return false;
    if (want.length === 1) return got.length > 0 && got.every((g) => holds(g, want[0]));
    return want.length === got.length && want.every((w, i) => holds(got[i], w));
  }
  if (want && typeof want === "object") return !!got && typeof got === "object" && Object.entries(want).every(([k, v]) => holds(got[k], v));
  return got === want;
}
// The expectations: a step that only reads what a page shows.
const expectations = ["see", "hidden", "attached", "never", "asked", "count", "text", "value", "attr", "attrs", "address", "image", "layout", "inView"];
// The gestures a person makes on a page the shell has taken over (`loaded.adopted`): each waits for it first.
const gestures = ["click", "trigger", "drag", "check", "press", "fill", "select", "upload", "submit", "keep", "signUp", "signIn"];

export class Run {
  actors = new Map<string, Actor>();
  // `{host}`: the host the run reaches the app at (a stack at hand's own, where a listing names it).
  vars = new Map<string, string>([["host", new URL(URL_).hostname]]);
  // The flags whose steps this scenario skipped, named in its verdict.
  skipped = new Set<string>();
  // The flags on here whose `unless` steps (the app as it is with the flag off) this scenario skipped.
  onHere = new Set<string>();
  // {run}: one fresh id for the whole run, so its rows are told apart from another run's.
  id = crypto.randomUUID();
  // The app's address, and whether it is production: for the app's own steps.
  readonly url = URL_;
  readonly onProduction = onProduction;
  // Set when a slowed page stops answering for good: a fault of the browser's CPU throttling (see
  // tests/slow.ts), not of the app, which the runner runs the scenario again for.
  stuck = "";
  beat: ReturnType<typeof setInterval> | undefined;
  stalled: Promise<never>;
  // Slowed as the rehearsal slows it (SLOW named: every scenario), or, in the local gate, only a scenario marked `slow`.
  readonly slowed: boolean;
  constructor(readonly s: Scenario) {
    this.slowed = !!slow && (!gate || !!s.slow);
    const missed = new Map<string, number>();
    this.stalled = new Promise<never>((_, reject) => {
      // Only a slowed browser wedges: unthrottled, a page that does not answer is the app's to explain.
      if (!this.slowed) return;
      this.beat = setInterval(async () => {
        for (const a of this.actors.values()) {
          const up = await Promise.race([a.page.evaluate(() => true).catch(() => true), sleep(15).then(() => false)]);
          missed.set(a.key, up ? 0 : (missed.get(a.key) ?? 0) + 1);
          if ((missed.get(a.key) ?? 0) >= 4) { this.stuck = `${a.key}'s page has not answered for a minute`; clearInterval(this.beat); reject(new Error(this.stuck)); return; }
        }
      }, 15000);
    });
    this.stalled.catch(() => {});
  }
  // A step that failed on a slowed page may have lost its race to the watch above: a page that
  // wedged within the step's own timeout (a click's 30 s, a check's 60 s) fails the step before
  // the minute is up. Asked again for that minute, a page that never answers is the wedge, and the
  // scenario is run again; one that answers failed the step itself.
  async wedged(): Promise<string> {
    if (!this.slowed || this.stuck) return this.stuck;
    for (const a of this.actors.values()) {
      let up = false;
      for (let n = 0; n < 4 && !up; n++) up = await Promise.race([a.page.evaluate(() => true).catch(() => true), sleep(15).then(() => false)]);
      if (!up) return this.stuck = `${a.key}'s page has not answered for a minute`;
    }
    return "";
  }

  async actor(key: string): Promise<Actor> {
    const known = this.actors.get(key);
    if (known) return known;
    const def = this.s.actors[key];
    if (!def) throw new Error(`no actor ${key}`);
    // The screen it reads the app on (its `device`, else the app's `screen`): a viewport, or a phone Playwright knows by name.
    const screen = def.device ? spec.screens?.[def.device] : spec.screen;
    if (!screen) throw new Error(`${key}'s device ${def.device} is none of the app's screens`);
    const shape = screen.device ? devices[screen.device] : { viewport: screen.viewport };
    if (!shape) throw new Error(`Playwright knows no device ${screen.device}`);
    const ctx = await (await liveBrowser()).newContext({ ignoreHTTPSErrors: true, ...shape, locale: def.locale ?? spec.locale });
    await hooks.context?.(ctx, def);
    const a: Actor = { key, name: def.name, def, ctx, page: null as unknown as Page, cdp: null as unknown as CDPSession, auth: "", consoles: [], trail: [], asked: [], hot: false, releases: new Map(), data: {} };
    await this.tab(a);
    this.actors.set(key, a);
    return a;
  }
  // The actor's tab: a page of its browser, watched, with its authenticator and its pace. A new one
  // (`revisit`) keeps what the browser keeps (its storage, its cookies) and nothing of the tab's own.
  async tab(a: Actor) {
    const key = a.key, page = await a.ctx.newPage();
    const cdp = await a.ctx.newCDPSession(page);
    a.page = page;
    a.cdp = cdp;
    // What this tab asked for (`never`): a new tab starts with nothing asked.
    a.asked = [];
    // Every address the page asked for, for a step that says one was never asked (`never`), and, of the app's,
    // for the diff selection (scenarios/select.ts): an electric shape by its table.
    page.on("request", (r) => { const u = new URL(r.url()); a.asked.push(u.pathname); if (u.origin === new URL(URL_).origin) sel.observe(this.s.id, r.method(), u.pathname + (u.pathname.startsWith("/electric/") && u.searchParams.get("table") ? `?table=${u.searchParams.get("table")}` : "")); });
    // The bytes of each static asset it loads, for the diff selection (scenarios/select.ts).
    page.on("response", async (r) => {
      const u = new URL(r.url());
      // Not a user's picture (/img/) nor a ranged answer (a 206: media, whose bytes the diff does not judge).
      if (r.request().method() !== "GET" || u.origin !== new URL(URL_).origin || u.pathname.startsWith("/img/") || r.status() === 206) return;
      // An answer that is not a 200, or a body that cannot be read, is recorded as that, so adding the
      // missing file later reruns the scenario that did without it.
      const body = r.status() === 200 ? await r.body().catch(() => null) : null;
      sel.observe(this.s.id, "GET", u.pathname, r.status() !== 200 ? `status ${r.status()}` : body ? sha(body) : "unreadable");
    });
    // What the page did, each line at its UTC time (the cloud's request logs are in UTC): its loads, its
    // requests to the app (not the assets) and how each ended, so a failure shows whether a write left the
    // page, was refused, or the page was replaced under it (PRONTO-59).
    const mark = (line: string) => { a.trail.push(`${key} ${new Date().toISOString().slice(11, 23)} ${line}`); if (a.trail.length > 80) a.trail.shift(); };
    const call = (s: string) => { const u = new URL(s); return /\/_immutable|\/omnishell\/|\.(css|js|html|json|woff2?|png|svg)$/.test(u.pathname) || /live=true/.test(u.search) ? null : u.pathname + u.search.slice(0, 80); };
    page.on("framenavigated", (f) => { if (f === page.mainFrame()) mark(`loaded ${new URL(f.url()).pathname}${new URL(f.url()).search.slice(0, 60)}`); });
    page.on("request", (r) => { const u = call(r.url()); if (u) mark(`asked ${r.method()} ${u}`); });
    page.on("response", (r) => { const u = call(r.url()); if (u) mark(`answered ${r.status()} ${r.request().method()} ${u}`); });
    page.on("requestfailed", (r) => { const u = call(r.url()); if (u) mark(`failed ${r.method()} ${u}: ${r.failure()?.errorText ?? "?"}`); });
    page.on("pageerror", (e) => pageErrors.push(`${this.s.id}/${key}: ${e.message}`));
    page.on("console", (m) => { a.consoles.push(`${key} ${m.type()}: ${m.text()}`); if (a.consoles.length > 60) a.consoles.shift(); });
    hooks.tab?.(this, a);
    await cdp.send("WebAuthn.enable");
    a.auth = (await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } })).authenticatorId;
    await slowDown(cdp, false, this.slowed);
  }
  // The session a page holds, and the account (or guest) it is.
  async session(a: Actor) {
    const token = await a.page.evaluate(() => { try { return JSON.parse(sessionStorage.getItem("pronto-token") || "null")?.token ?? null; } catch { return null; } });
    if (!token) throw new Error(`${a.key} has no session yet`);
    const claims = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return { token: token as string, id: claims.sub as string, guest: claims.guest === true };
  }
  async fill(text: string): Promise<string> {
    let out = "";
    let last = 0;
    for (const m of text.matchAll(/\{([a-z][a-z0-9_]*)(?:\.(id|token|name))?\}/g)) {
      out += text.slice(last, m.index);
      last = m.index! + m[0].length;
      const [, name, part] = m;
      if (part) {
        const a = await this.actor(name);
        out += part === "name" ? a.name : (await this.session(a))[part as "id" | "token"];
      } else if (name === "uuid") out += crypto.randomUUID();
      else if (name === "past") out += new Date(Date.now() - 60000).toISOString().replace("Z", "000Z");
      else if (name === "run") out += this.id;
      else if (this.vars.has(name)) out += this.vars.get(name);
      else throw new Error(`nothing kept as {${name}}`);
    }
    return out + text.slice(last);
  }
  async fillAll(v: any): Promise<any> {
    if (typeof v === "string") return this.fill(v);
    if (Array.isArray(v)) return Promise.all(v.map((x) => this.fillAll(x)));
    if (v && typeof v === "object") return Object.fromEntries(await Promise.all(Object.entries(v).map(async ([k, x]) => [k, await this.fillAll(x)])));
    return v;
  }
  // Asked again until it holds, or the step's time runs out with what it last saw. A check that throws
  // `Settled` (a state the app says will not come right) ends it at once.
  async until(what: string, seconds: number, check: () => Promise<[boolean, unknown]>) {
    const end = Date.now() + seconds * 1000;
    let seen: unknown;
    for (;;) {
      let ok = false;
      try { [ok, seen] = await check(); } catch (e) { if ((e as Error).name === "Settled") throw e; seen = (e as Error).message; }
      if (ok) return;
      if (Date.now() > end) throw new Error(`${what}: still ${JSON.stringify(seen)} after ${seconds}s`);
      await sleep(0.25);
    }
  }
  // A page loaded: the app's own wait where it has one (app.ts `loaded`), else the document's load, the
  // screen the terminal draws once it has drawn one (`loaded.screen`), the loader's script gone once the
  // terminal has booted, and, where pages are served first (`loaded.adopted`), the shell's taking it over.
  async loaded(p: Page) {
    if (hooks.loaded) return hooks.loaded(this, p);
    await p.waitForLoadState("load");
    if (spec.loaded.screen) await p.waitForSelector(spec.loaded.screen, { state: "attached", timeout: 120000 });
    if (await p.locator("script[data-pronto-boot]").count()) await p.waitForSelector("script[data-pronto-boot]", { state: "detached", timeout: 60000 }).catch(() => {});
    if (spec.loaded.adopted) await this.adopted(p, 120);
  }
  // No served screen left: until the shell takes a served screen over (omnishell drops its data-served
  // then), it is markup with no handlers, and a click on it is lost (a published game's first click, on a
  // page four times slower). Asked before every gesture too, not only after a load: an app may reload the
  // page itself (a passkey sign-up, shell.js), and a service worker serves that reload at once, so a `see`
  // holds on its served markup while the click after it is lost (Studio's rc of 2026-11-07). A navigation
  // under way is asked again.
  async adopted(p: Page, t: number) {
    const end = Date.now() + t * 1000;
    for (;;) {
      const done = await p.evaluate(() => !document.querySelector(".shell-screen[data-served]")).catch(() => false);
      if (done) return;
      if (Date.now() > end) throw new Error(`the page was still served after ${t}s`);
      await sleep(0.1);
    }
  }
  async shot(a: Actor, label: string) { if (SHOTS) await a.page.screenshot({ path: `${SHOTS}/${this.s.id}-${label}-${a.key}.png` }); }

  // The CPU slowing is on for the page a step drives and off for the others, which sit idle.
  async heat(a: Actor | null) {
    for (const o of this.actors.values()) {
      const want = o === a;
      if (o.hot !== want) { o.hot = want; await slowCpu(o.cdp, want, this.slowed).catch(() => {}); }
    }
  }

  async step(st: Step): Promise<unknown> {
    // A step for the app as it is with a flag off (`unless`): skipped where the flag is on, as the flag's own steps are where it is off.
    if (st.unless !== undefined && await flagOn(st.unless)) { this.onHere.add(st.unless); return; }
    if (TESTER && st.flag !== undefined && st.flag === Deno.env.get("FLAG")) {
      // A flip tests its flag (FLAG, by `pronto-flags push`) as the tester, for whom alone the canary turns it on:
      // asked with the tester's session once the actor has it (the steps before its sign-in run as they are), and
      // off for the tester is a failure, never a skip.
      const who = st.by ? await this.actor(st.by) : null;
      const s = who ? await this.session(who).catch(() => null) : null;
      if (s && !s.guest && !(await ofrepAsk(st.flag, s.token))) throw new Error(`${st.flag} is off for the tester ${TESTER}, which this run tests`);
    } else if (st.flag !== undefined && !(await flagOn(st.flag))) { this.skipped.add(st.flag); return; }
    // Asked only on production or only at hand (`on`), and only once a step has kept a value (`ifKept`).
    if (st.on && (st.on === "production") !== onProduction) return;
    if (st.ifKept && ["", "undefined", "null"].includes(this.vars.get(st.ifKept) ?? "")) return;
    const t = st.timeout ?? 30, ms = t * 1000;
    if ("http" in st) { await this.heat(null); return this.http(st, st.by ? await this.actor(st.by) : null, t); }
    // Several actors' steps at one instant: each is sent before any is answered.
    if ("together" in st) { await Promise.all(st.together.map((x: Step) => this.step(x))); return; }
    // Holds once one of its steps holds, all asked at once: which of two racing guests won.
    if ("any" in st) {
      try { await Promise.any(st.any.map((x: Step) => this.step(x))); } catch (e) {
        throw new Error(`none held: ${(e as AggregateError).errors.map((x) => (x as Error).message.split("\n")[0]).join(" | ")}`);
      }
      return;
    }
    const a = st.by ? await this.actor(st.by) : null;
    if (!a) throw new Error("a page step names its actor (by)");
    const p = a.page;
    const sel = async (s: string) => p.locator(await this.fill(s)).first();
    // What a person types into or taps: a screen is drawn (and its words shown) while the shell still holds it
    // `inert`, until it is ready (omnishell, shell.js releaseInitial), and a field inert takes no focus, so
    // Playwright's fill lands on nothing without failing. Wait, as a person does, for it to be live.
    const live = async (s: string) => { const l = await sel(s); await this.live(p, l, ms); return l; };
    await this.heat(a);
    // `fresh`: an expectation on what another actor changed, which a page reads on its next load: asked
    // for a few seconds, then the page is reloaded, until it holds or the step's time runs out.
    if (st.fresh) {
      const { fresh: _, ...once } = st;
      if (!expectations.some((k) => k in once)) throw new Error("fresh belongs to an expectation: " + JSON.stringify(once));
      const end = Date.now() + ms;
      for (;;) {
        try { return await this.step({ ...once, timeout: 3 }); } catch (e) {
          if (Date.now() > end) throw e;
          await p.reload();
          await this.loaded(p);
        }
      }
    }
    // `repeat`: the action again until the expectation holds (asked first, for a moment, each time), at
    // most `max` times or until the step's time runs out. An action that finds nothing to act on is
    // not a failure while the expectation may still come: the last move's answer may be on its way.
    if ("repeat" in st) {
      const end = Date.now() + ms;
      for (let n = 0; ; n++) {
        try { return await this.step({ by: st.by, ...st.until, timeout: 0.25 }); } catch (e) {
          if ((e as Error).name === "Settled" || n >= st.max || Date.now() > end) throw new Error(`after ${n} of at most ${st.max}: ${(e as Error).message.split("\n")[0]}`);
        }
        await this.step({ by: st.by, ...st.repeat, timeout: 5 }).catch(() => {});
      }
    }
    // A gesture on a page served first waits for the shell to take it over.
    if (spec.loaded.adopted && gestures.some((k) => k in st)) await this.adopted(p, t);
    // Actions.
    if ("open" in st) { const to = await this.fill(st.open); await p.goto(/^https?:/.test(to) ? to : new URL(to, URL_).href); return this.loaded(p); }
    if ("reload" in st) { await p.reload(); return this.loaded(p); }
    if ("revisit" in st) {
      // The tab closed, and the app opened again in a new one: the tab's sessionStorage goes with it.
      const to = await this.fill(st.revisit);
      await p.close();
      await this.tab(a);
      await a.page.goto(/^https?:/.test(to) ? to : new URL(to, URL_).href);
      return this.loaded(a.page);
    }
    if ("rush" in st) {
      // Not waiting for the page: the press is the first thing the player does, on whatever is drawn first.
      const to = await this.fill(st.rush.open);
      // The page's entry script waits, when asked (holdPage), until the press is made: it mounts the terminal,
      // which takes the document's menu over, and a fast boot did that before a click's round trips were
      // over (PRONTO-114: the document's menu was gone before the game's own script was even asked for).
      let made!: () => void;
      const pressMade = new Promise<void>((ok) => { made = ok; });
      if (st.rush.holdPage) {
        await p.route(new RegExp(st.rush.holdPage), async (route) => {
          await Promise.race([pressMade, new Promise((ok) => setTimeout(ok, ms))]);
          await route.continue().catch(() => {});
        });
      }
      let held = "";
      try {
        await p.goto(/^https?:/.test(to) ? to : new URL(to, URL_).href, { waitUntil: "commit" });
        if (st.rush.drawn) await (await sel(st.rush.drawn)).waitFor({ state: "attached", timeout: ms });
        await (await sel(st.rush.click)).click({ timeout: ms });
        held = await p.evaluate(() => (window as unknown as { __fp?: { pressed: string } }).__fp?.pressed ?? "");
      } finally { made(); }
      if (st.rush.heldBy && held !== st.rush.heldBy) {
        const page = await p.evaluate(() => ({ firstPaint: document.documentElement.getAttribute("data-first-paint"), fp: !!document.getElementById("fp"), fpHidden: document.getElementById("fp")?.hidden ?? null, boot: (document.getElementById("app") ?? document.body).dataset?.boot ?? null, at: Math.round(performance.now()) })).catch((e) => String(e));
        throw new Error(`the press was not held by the document's menu (held: "${held}", want "${st.rush.heldBy}"); the page then: ${JSON.stringify(page)}`);
      }
      return;
    }
    if ("click" in st) {
      if (typeof st.click === "string") return (await live(st.click)).click({ timeout: ms });
      const shown = async () => { for (const s of st.click) if (await (await sel(s)).isVisible()) return s; return null; };
      await this.until(`one of ${st.click.join(", ")} shown`, t, async () => [!!(await shown()), null]);
      return (await sel((await shown())!)).click({ timeout: ms });
    }
    // A mouse drag: pressed on the middle of `from`, moved in steps to the middle of `to`, let go.
    if ("drag" in st) {
      const box = async (s: string) => {
        const l = await sel(s);
        await l.waitFor({ state: "visible", timeout: ms });
        const b = await l.boundingBox();
        if (!b) throw new Error(`${s} has no box`);
        return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
      };
      const from = await box(st.drag.from), to = await box(st.drag.to);
      await p.mouse.move(from.x, from.y);
      await p.mouse.down();
      await p.mouse.move(to.x, to.y, { steps: 12 });
      return p.mouse.up();
    }
    if ("leave" in st) return p.evaluate(() => { dispatchEvent(new Event("pagehide")); });
    if ("trigger" in st) return (await sel(st.trigger)).evaluate((e: HTMLElement) => e.click());
    if ("check" in st) return (await sel(st.check)).check({ timeout: ms });
    if ("press" in st) return p.keyboard.press(st.press);
    if ("fill" in st) return (await live(st.fill.in)).fill(await this.fill(st.fill.value), { timeout: ms });
    if ("select" in st) return (await live(st.select.in)).selectOption(await this.fill(st.select.value), { timeout: ms });
    if ("upload" in st) return (await sel(st.upload.in)).setInputFiles(here("./fixtures/" + st.upload.file).pathname);
    if ("submit" in st) return (await sel(st.submit)).evaluate((f: HTMLFormElement) => f.requestSubmit());
    // An error thrown before the error reporter has asked for its flag is never reported: the throw
    // waits for the reporter to say it has settled (the hatch marks <html data-errors>).
    if ("throw" in st) { const message = await this.fill(st.throw); await p.waitForSelector("html[data-errors]", { state: "attached", timeout: 60_000 }); return p.evaluate((m) => { setTimeout(() => { throw new Error(m); }, 0); }, message); }
    if ("closeDialogs" in st) return p.evaluate(() => document.querySelectorAll("dialog[open]").forEach((d) => (d as HTMLDialogElement).close()));
    if ("pay" in st) {
      // The app's checkout (tests/checkout.ts: the stand-in's pay button, or Stripe's sandbox card form).
      const { checkoutOpens, pay } = await import(here("./checkout.ts").href);
      await checkoutOpens(p, ms);
      await pay(p);
      // Back at the app from the checkout, loaded as an `open` is. The stand-in's checkout is on the app's
      // origin too, so its path is no return.
      await p.waitForURL((u) => u.origin === new URL(URL_).origin && !/\/fake\/stripe\/pay\//.test(u.pathname), { timeout: ms });
      await this.loaded(p);
      return hooks.paid?.(this, a);
    }
    if ("database" in st) {
      // SQL run as the stack's owner, at hand only: what `pronto-armies push --local` does to a stack, done by a scenario
      // while its page is open (a row the page learns of through its shape). The slot's DATABASE_PG_PORT and the
      // owner's login are the stack's own (.bayt/process-compose.yaml); the database is POSTGRES_DB, else the app's (`database`).
      const host = new URL(URL_).hostname;
      if (onProduction || !["localhost", "127.0.0.1"].includes(host)) throw new Error(`a database step runs at hand, not against ${URL_}`);
      const port = Deno.env.get("DATABASE_PG_PORT");
      if (!port) throw new Error("a database step needs DATABASE_PG_PORT, which a slot's commands have");
      const db = Deno.env.get("POSTGRES_DB") ?? spec.database;
      if (!db) throw new Error("a database step needs the app's `database` (tests/scenarios/*.cue) or POSTGRES_DB");
      // The stack's own postgres binaries (.mise.host.toml) when none is named: a shim on PATH may have no version set here.
      let psql = Deno.env.get("PSQL") ?? "psql";
      if (!Deno.env.get("PSQL")) {
        const w = await new Deno.Command("mise", { args: ["where", "github:theseus-rs/postgresql-binaries"], stdout: "piped", stderr: "null" }).output().catch(() => null);
        const found = w?.success ? new TextDecoder().decode(w.stdout).trim() : "";
        if (found) psql = found + "/bin/psql";
      }
      const r = await new Deno.Command(psql, {
        args: ["-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", await this.fill(st.database)],
        env: { PGHOST: "127.0.0.1", PGPORT: port, PGUSER: "postgres", PGPASSWORD: Deno.env.get("POSTGRES_PASSWORD") ?? "postgres", PGDATABASE: db },
        stdout: "piped", stderr: "piped",
      }).output();
      if (!r.success) throw new Error(`database step failed: ${new TextDecoder().decode(r.stderr).trim()}`);
      return;
    }
    if ("pause" in st) return sleep(st.pause);
    if ("shot" in st) return this.shot(a, st.shot);
    if ("keep" in st) {
      for (const [name, k] of Object.entries(st.keep as Record<string, any>)) {
        const l = await sel(k.of);
        await l.waitFor({ state: "attached", timeout: ms });
        const v = k.value ? await l.inputValue() : k.text ? await l.textContent() : await l.getAttribute(k.attr);
        if (v == null) throw new Error(`nothing to keep as ${name} from ${k.of}`);
        this.vars.set(name, v);
      }
      return;
    }
    // Expectations.
    if ("see" in st) return (await sel(st.see)).waitFor({ state: "visible", timeout: ms });
    if ("hidden" in st) return (await sel(st.hidden)).waitFor({ state: "hidden", timeout: ms });
    if ("attached" in st) return (await sel(st.attached)).waitFor({ state: "attached", timeout: ms });
    if ("asked" in st) return this.until(`an address holding ${st.asked}`, t, () => Promise.resolve([a.asked.some((u) => u.includes(st.asked)), a.asked.length]));
    if ("never" in st) { const hit = a.asked.find((u) => u.includes(st.never)); if (hit) throw new Error(`the page asked for ${hit}`); return; }
    if ("count" in st) {
      const l = p.locator(await this.fill(st.count.of));
      return this.until(`count of ${st.count.of}`, t, async () => { const n = await l.count(); return [st.count.is !== undefined ? n === st.count.is : n >= st.count.atLeast, n]; });
    }
    if ("text" in st) {
      const want = st.text.msg ? messages[st.text.msg] : st.text.is !== undefined ? await this.fill(st.text.is) : null;
      if (st.text.msg && want === undefined) throw new Error(`no message ${st.text.msg} in ${spec.messages}`);
      const has = st.text.has !== undefined ? await this.fill(st.text.has) : null;
      const l = await sel(st.text.of);
      return this.until(`text of ${st.text.of}`, t, async () => { const v = await l.textContent({ timeout: 1000 }); return [(want === null || v === want) && (has === null || !!v?.includes(has)), v]; });
    }
    if ("value" in st) {
      const want = await this.fill(st.value.is), l = await sel(st.value.of);
      return this.until(`value of ${st.value.of}`, t, async () => { const v = await l.inputValue({ timeout: 1000 }); return [v === want, v]; });
    }
    if ("attr" in st) {
      const { name, is, matches, below, failing, says } = st.attr, l = await sel(st.attr.of);
      const want = is !== undefined ? await this.fill(is) : null, re = matches !== undefined ? new RegExp(await this.fill(matches)) : null;
      return this.until(`${name} of ${st.attr.of}`, t, async () => {
        const v = await l.getAttribute(name, { timeout: 1000 });
        // The app reports a state that will not come right (a preview that is broken): the step fails at
        // once with what the app says of it, not after its time is spent.
        if (failing !== undefined && v === failing) throw Object.assign(new Error(`${name} of ${st.attr.of} is ${v}: ${says ? await l.getAttribute(says, { timeout: 1000 }) : ""}`), { name: "Settled" });
        return [v !== null && (want === null || v === want) && (!re || re.test(v)) && (below === undefined || Number(v) < below), v];
      });
    }
    if ("attrs" in st) {
      const l = p.locator(await this.fill(st.attrs.of)), are = await this.fillAll(st.attrs.are);
      return this.until(`${st.attrs.name} of each ${st.attrs.of}`, t, async () => { const v = await l.evaluateAll((es, n) => es.map((e) => e.getAttribute(n)), st.attrs.name); return [same(v, are), v]; });
    }
    if ("address" in st) {
      const re = new RegExp(await this.fill(st.address.matches));
      return this.until("the address", t, async () => [re.test(p.url()), p.url()]);
    }
    if ("image" in st) {
      const l = await sel(st.image.of);
      return this.until(`the image ${st.image.of}`, t, async () => {
        const v = await l.evaluate((i: HTMLImageElement) => i.complete && i.naturalWidth > 0 && i.checkVisibility() ? [i.naturalWidth, i.naturalHeight] : null);
        return [same(v, [st.image.width, st.image.height]), v];
      });
    }
    // The screen inside the phone's side gutter at every width named, and every control a fingertip
    // tall (giselle's measure, apps/giselle/tests/acceptance.ts): every box, text included, once the
    // page is at rest.
    if ("layout" in st) {
      const { of, gutter, tall, widths } = st.layout, size = p.viewportSize()!;
      for (const width of widths ?? [size.width]) {
        await p.setViewportSize({ width, height: size.height });
        await p.waitForFunction(async () => { await document.fonts.ready; return document.getAnimations().every((x) => x.playState !== "running"); }, undefined, { timeout: ms });
        const wrong = await (await sel(of)).evaluate((root, [g, h]) => {
          const w = document.documentElement.clientWidth, out: string[] = [];
          if (document.documentElement.scrollWidth > w) out.push(`the page scrolls sideways, ${document.documentElement.scrollWidth} wide in ${w}`);
          for (const el of root.querySelectorAll("*")) {
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            const name = () => `${el.localName}.${el.className} "${((el.textContent ?? "").trim() || el.getAttribute("name") || "").slice(0, 30)}"`;
            if (r.left < g || r.right > w - g) out.push(`${name()} at ${Math.round(r.left)}-${Math.round(r.right)} of ${w}`);
            if (el.matches("input:not([type=hidden]), select, textarea, button, a") && r.height < h) out.push(`${name()} is ${Math.round(r.height)}px tall`);
          }
          return out;
        }, [gutter, tall] as [number, number]);
        if (wrong.length) { await p.setViewportSize(size); throw new Error(`${of} at ${width}px: ${wrong.join("; ")}`); }
      }
      return p.setViewportSize(size);
    }
    // Whole inside the box of its nearest `within` ancestor, under no element named in `clear`, and the
    // element found at its middle: read in full, neither cut off by its panel nor covered (PRONTO-143).
    if ("inView" in st) {
      const { of, within, clear } = st.inView, l = await sel(of);
      await l.waitFor({ state: "visible", timeout: ms });
      return this.until(`${of} in full view`, t, async () => {
        const why = await l.evaluate((h: Element, [w, c]) => {
          const face = h.closest(w as string);
          if (!face) return `not inside ${w}`;
          const r = h.getBoundingClientRect(), f = face.getBoundingClientRect();
          if (r.top < f.top - 1 || r.bottom > f.bottom + 1 || r.left < f.left - 1 || r.right > f.right + 1) return `cut off by ${w} (${Math.round(r.top)}..${Math.round(r.bottom)} in ${Math.round(f.top)}..${Math.round(f.bottom)})`;
          for (const s of c as string[]) {
            const o = document.querySelector(s)?.getBoundingClientRect();
            if (o && o.left < r.right && o.right > r.left && o.top < r.bottom && o.bottom > r.top) return `under ${s}`;
          }
          const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return at === h || h.contains(at) ? "" : `covered by ${at?.className || at?.localName}`;
        }, [within, clear ?? []] as [string, string[]]);
        return [why === "", why];
      });
    }
    if ("response" in st) {
      const r = st.response, to = await this.fill(r.to);
      // Started before the step that causes the response: if that step fails, or a wedged page is
      // run again, nobody awaits this and its timeout must not crash the runner (scenarios/early.ts).
      // A step that is a gesture on the page (a click, a submit, a trigger) takes the answer by a route too,
      // which fetches it itself and hands the page a copy: the page's own success path may navigate right
      // after it reads the answer (location.assign), and Chrome then drops the body ("No resource with given
      // identifier") before a listener on the page's response could read it (PRONTO-422). The first of the
      // two to have it wins. A route holds the request until the runner answers it, and a beacon the page
      // sends as it leaves, throws or reloads (the tracker's, the first load's) does not survive being held:
      // those steps keep to the listener, whose predicate reads the body as the response arrives, and an answer
      // whose body is dropped is no answer, the old page's still in flight when a reload began (a slow
      // preview shows it, as a tracker's first pageview): the wait goes on for the new page's.
      let seen = { status: 0, body: "", sent: "" };
      let taken = false, dropped = "";
      let answered!: () => void, failed!: (e: Error) => void;
      const got = early(new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`no ${r.method} ${to} was answered within ${ms} ms${dropped ? ` (every answer's body was dropped: ${dropped})` : ""}`)), ms);
        answered = () => { clearTimeout(timer); resolve(); };
        failed = (e) => { clearTimeout(timer); reject(e); };
      }));
      const match = (u: URL) => u.href.includes(to);
      const routed = ["click", "submit", "trigger"].some((k) => k in (r.when ?? {}));
      if (routed) await p.route(match, async (route) => {
        if (route.request().method() !== r.method) return route.fallback();
        try {
          const res = await route.fetch();
          const answer = { status: res.status(), body: res.status() === 204 ? "" : await res.text(), sent: route.request().postData() ?? "" };
          await route.fulfill({ response: res, body: res.status() === 204 ? undefined : answer.body });
          if (!taken) { taken = true; seen = answer; answered(); }
        } catch (e) {
          await route.abort().catch(() => {});
          failed(new Error(`${r.method} ${to} could not be taken or handed to the page: ${(e as Error).message}`));
        }
      });
      p.waitForResponse(async (x) => {
        if (taken) return true;
        if (!x.url().includes(to) || x.request().method() !== r.method) return false;
        try {
          const answer = { status: x.status(), body: x.status() === 204 ? "" : await x.text(), sent: x.request().postData() ?? "" };
          if (!taken) { taken = true; seen = answer; answered(); }
        } catch (e) { dropped = (e as Error).message; return false; }
        return true;
      }, { timeout: ms }).catch(() => {});
      try {
        await this.step({ by: st.by, timeout: st.timeout, ...r.when });
        await got;
      } finally { if (routed) await p.unroute(match).catch(() => {}); }
      const { status, body } = seen;
      if (status !== r.status) throw new Error(`${r.method} ${to} answered ${status}, not ${r.status}: ${body.slice(0, 200)}`);
      if (r.matches && !new RegExp(r.matches).test(body)) throw new Error(`${r.method} ${to} answered ${body.slice(0, 200)}, which does not match ${r.matches}`);
      if (r.sent && !new RegExp(r.sent, "s").test(seen.sent)) throw new Error(`${r.method} ${to} was sent ${seen.sent.slice(0, 300)}, which does not match ${r.sent}`);
      return;
    }
    // The network.
    if ("hold" in st) {
      const { to, method, seconds } = st.hold;
      // With no seconds the request waits for the `release` step, not for a clock the steps before it can outrun
      // (a slow sign-up used up a 12 s hold before the check of the late answer ran).
      let gate: Promise<void> | undefined;
      if (seconds === undefined) { gate = new Promise<void>((open) => a.releases.set(to, open)); }
      await a.ctx.route(new RegExp(to), async (route) => {
        if (route.request().method() === method) await (gate ?? new Promise((r) => setTimeout(r, seconds * 1000)));
        await route.continue().catch(() => {});
      });
      return;
    }
    if ("release" in st) {
      const open = a.releases.get(st.release);
      if (!open) throw new Error(`nothing is held at ${st.release}`);
      open();
      return;
    }
    if ("block" in st) {
      // A request the page makes is refused, as a network that is down refuses it: for a step that would leave the page (a provider's
      // sign-in, whose real broker or Google a test must never reach) and is asked what it sent before it goes.
      await a.ctx.route(new RegExp(st.block), (route) => route.abort("blockedbyclient").catch(() => {}));
      return;
    }
    // Sign-in.
    if ("signUp" in st) {
      // The terminal's passkey register, which the app shows nobody (decision-signup): a test's own
      // way to a new account, as Google's would need a person at Google.
      const register = p.locator("body > nav .shell-register");
      await register.waitFor({ state: "attached", timeout: 60000 });
      await register.evaluate((e: HTMLElement) => e.click());
      await this.until("an account's session", 60, async () => { const s = await this.session(a); return [!s.guest, s.guest]; });
      return hooks.signedUp ? hooks.signedUp(this, a) : this.loaded(p);
    }
    if ("signIn" in st) {
      // The tester's passkey, which exists already: imported into this actor's virtual authenticator, and
      // pressed on the app's sign-in (`signIn`: what opens it, the first of them shown, and its passkey
      // button), as a player with a passkey signs in. Without a credential (at hand, where there is no
      // tester) the actor first makes an account the way signUp does and signs out, so the same clicks are
      // run against the passkey it holds.
      // The counter starts at the clock, not at the secret's: the secret is one passkey every run imports, and a
      // server that wants each assertion's counter above the last it saw refuses a run that starts where the
      // one before did (a 401 at /auth/login/verify, 2026-11-07).
      // Scenarios side by side sign in with that one passkey, each from its own authenticator: two that start
      // in the same second assert the same counter, and the server refuses the second (a 401 at
      // /auth/login/verify, PRONTO-122). So the tester signs in one scenario at a time, each importing a
      // counter above the last one this run gave, and holds the turn until its session is the account's.
      const how = spec.signIn;
      if (!how) throw new Error("a signIn step needs the app's `signIn` (tests/scenarios/*.cue)");
      const signIn = async () => {
        await this.step({ by: st.by, click: how.open });
        await this.step({ by: st.by, click: how.passkey });
        await this.until("the tester's session", 60, async () => { const s = await this.session(a).catch(() => null); return [!!s && !s.guest && (!TESTER || s.id === TESTER), s]; });
      };
      const cred = Deno.env.get("FLAGS_TESTER_CREDENTIAL");
      if (cred) {
        const c = JSON.parse(cred);
        const release = await testerTurn();
        try {
          testerCount = Math.max(c.signCount ?? 0, testerClock(), testerCount + 2);
          await a.cdp.send("WebAuthn.addCredential", { authenticatorId: a.auth, credential: { credentialId: c.credentialId, isResidentCredential: true, rpId: c.rpId, privateKey: c.privateKey, userHandle: c.userHandle, signCount: testerCount } });
          await signIn();
        } finally { release(); }
        return this.loaded(p);
      }
      if (onProduction) throw new Error("signIn on production needs FLAGS_TESTER_CREDENTIAL");
      await this.step({ by: st.by, signUp: true });
      await this.step({ by: st.by, trigger: "body > nav .shell-signout" });
      await sleep(3);
      await this.step({ by: st.by, see: how.open[0], timeout: 120 });
      await signIn();
      return this.loaded(p);
    }
    // Google through the local broker's stand-in (pronto-identity's hydra/fake.ts): the strip's button, the
    // broker's page, the stand-in's "Continue as <person>", and back with a session. A scenario that has one
    // needs the stand-in, and is skipped against a deployed app (below).
    if ("google" in st) {
      await p.click('.login-provider[data-provider="google"], .shell-provider[data-provider="google"]', { timeout: ms });
      const person = p.locator(`a.go[href*="/fake/google/approve"][href$="who=${st.google}"]`);
      const broker = p.locator('a.go[href*="/login/continue"]');
      return this.until(`a session as Google's ${st.google}`, 60, async () => {
        if (await person.isVisible()) await person.click();
        else if (await broker.isVisible()) await broker.click();
        const s = await this.session(a).catch(() => null);
        return [!!s && !s.guest, p.url()];
      });
    }
    if ("doorProbe" in st) {
      // signin_door's live check (PRONTO-268): the identity broker's door probe, as this actor's session. The broker
      // is where Google sign-in's start sends a browser (the auth service's 303, not followed); its probe asks the
      // app's signin_door with this session and, where it is on, exchanges a code no one was given through the
      // airlock's door: `credential` is Google's invalid_grant, the airlock having added the client's credential.
      // Read-only: no one signs in. At hand the broker (the stand-in front) has no door and answers 404.
      const { token } = await this.session(a);
      const start = await a.ctx.request.fetch(new URL("/auth/oidc/google/start?return=/", URL_).href, { maxRedirects: 0, failOnStatusCode: false });
      const to = start.headers()["location"];
      if (!to) throw new Error(`Google sign-in's start answered ${start.status()} with no broker to go to`);
      const broker = new URL(to, URL_).origin;
      const want = onProduction ? 200 : 404;
      const res = await anon.fetch(`${broker}/probe/door`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, data: JSON.stringify({ tenant: new URL(URL_).origin }), failOnStatusCode: false });
      const answer = await res.json().catch(() => null);
      if (res.status() !== want || (onProduction && answer?.door !== "credential")) throw new Error(`${broker}/probe/door answered ${res.status()} ${JSON.stringify(answer)}, not ${want}${onProduction ? " {door: credential}" : ""}`);
      return;
    }
    // The app's own (schema.cue's `#Gestures`, tests/scenarios/app.ts).
    for (const [kind, run] of Object.entries(hooks.steps ?? {})) if (kind in st) return run(this, st, a);
    throw new Error("a step of no known kind: " + JSON.stringify(st));
  }

  // Waits until the field has no `inert` ancestor, in its own frame and up through the frames that hold it
  // (a preview is a frame of the page): an observable state, with no retry and no longer timeout. The
  // selector is asked again each time, as a click asks it: a page may keep a leaving copy of what it
  // redraws (a card drawn from the stock, inert while it goes), and the live one is the one meant.
  async live(_p: Page, loc: Locator, ms: number): Promise<Locator> {
    const end = Date.now() + ms;
    for (let held = "";;) {
      held = await loc.first().evaluate((el) => {
        for (let e: Element | null = el as Element, w: Window = window; e;) {
          const i = e.closest("[inert]");
          if (i) return `${i.localName}${i.id ? "#" + i.id : ""}.${i.className} ${i.outerHTML.slice(0, 160)}`;
          try { e = w.frameElement; w = w.parent; } catch { return ""; }
        }
        return "";
      }, undefined, { timeout: Math.max(1, end - Date.now()) }).catch((e) => `not there: ${(e as Error).message.split("\n")[0]}`);
      if (held === "") return loc;
      if (Date.now() > end) throw new Error(`never live after ${ms / 1000}s, held by ${held}`);
      await sleep(0.1);
    }
  }
  async http(st: Step, a: Actor | null, t: number) {
    const h = st.http, path = await this.fill(h.path);
    sel.observe(this.s.id, h.method ?? "GET", String(h.path).split("?")[0]);
    const headers: Record<string, string> = await this.fillAll(h.headers ?? {});
    if (!h.anon) {
      if (!a) throw new Error("an http step with a session names its actor (by)");
      // A guest's session is minted as the page boots: waited for, as the page itself waits for it.
      let token = "";
      await this.until(`${a.key}'s session`, t, async () => { token = (await this.session(a)).token; return [true, null]; });
      headers.Authorization = `Bearer ${token}`;
    }
    const body = h.body === undefined ? undefined : await this.fillAll(h.body);
    if (body !== undefined && typeof body !== "string") headers["Content-Type"] ??= "application/json";
    const ctx = h.anon || !a ? anon : a.ctx.request;
    const ask = async (): Promise<[boolean, unknown]> => {
      const res = await ctx.fetch(new URL(path, URL_).href, { method: h.method, headers, data: typeof body === "string" ? body : body === undefined ? undefined : JSON.stringify(body), failOnStatusCode: false });
      const text = await res.text();
      let json: any = null;
      try { json = JSON.parse(text); } catch { /* not JSON */ }
      const e = h.expect, s = res.status();
      const ok = (e.status === undefined || s === e.status) && (!e.refused || s >= 400)
        && (e.length === undefined || (Array.isArray(json) && json.length === e.length))
        && (e.json === undefined || holds(json, await this.fillAll(e.json)))
        && (e.has === undefined || (await this.fillAll(e.has) as string[]).every((x) => text.includes(x)))
        && (e.lacks === undefined || (await this.fillAll(e.lacks) as string[]).every((x) => !text.includes(x)))
        && (e.header === undefined || Object.entries(await this.fillAll(e.header) as Record<string, string>).every(([k, v]) => res.headers()[k] === v));
      if (ok) for (const [name, at] of Object.entries((h.keep ?? {}) as Record<string, string>)) this.vars.set(name, String(at.split(".").reduce((o: any, k) => o?.[k], json)));
      return [ok, `${s} ${text.slice(0, e.has || e.lacks ? 1500 : 300)}`];
    };
    if (st.poll) return this.until(`${h.method} ${path}`, t, ask);
    const [ok, seen] = await ask();
    if (!ok) throw new Error(`${h.method} ${path} answered ${seen}`);
  }

  async run(): Promise<string | null> {
    const t0 = Date.now();
    // Each step's start and length, so a failure says where the time went.
    const took: string[] = [];
    for (const [i, st] of this.s.steps.entries()) {
      const at = Date.now();
      try {
        await Promise.race([this.step(st), this.stalled]);
        took.push(`  step ${i + 1} at ${((at - t0) / 1000).toFixed(1)}s (${new Date(at).toISOString().slice(11, 23)}) took ${((Date.now() - at) / 1000).toFixed(1)}s: ${JSON.stringify(st).slice(0, 120)}`);
      } catch (e) {
        clearInterval(this.beat);
        const { why, ...what } = st;
        const stuck = await this.wedged();
        const lines = [`✗ ${this.s.id} (${Math.round((Date.now() - t0) / 1000)}s) at step ${i + 1}${why ? ` (${why})` : ""}: ${JSON.stringify(what)}`, `  ${(e as Error).message.split("\n")[0]}`,
          // Why an action never happened, from Playwright's call log: what covered the element, or how it was
          // not yet clickable (a flake that said only "Timeout" hid its cause, PRONTO-122).
          ...[...new Set((e as Error).message.split("\n").filter((l) => /intercepts pointer events|not visible|not stable|not enabled|detached/.test(l)).map((l) => l.trim()))].slice(-3).map((l) => `  ${l}`),
          ...(this.slowed ? [`  ${stuck || "every page answered"}`] : []), ...took.slice(-12)];
        // A wedged page answers nothing (tests/slow.ts): asked for a picture or its row, it holds the
        // report, and the pass with it, for as long as Chrome keeps it (40 minutes on 2026-11-08,
        // PRONTO-32). It was asked for a minute already; the report says so and asks it nothing more.
        for (const a of this.actors.values()) {
          if (stuck) { lines.push(`  ${a.key}'s page: not asked, wedged`); continue; }
          if (SHOTS) await a.page.screenshot({ path: `${SHOTS}/failed-${this.s.id}-${a.key}.png` }).catch(() => {});
          // The dialogs open over its page, which take every click outside them.
          const open = await a.page.evaluate(() => [...document.querySelectorAll("dialog[open]")].map((d) => d.id || d.getAttribute("data-pronto-ad") || d.className || "dialog")).catch(() => "page gone");
          lines.push(`  ${a.key}'s open dialogs: ${JSON.stringify(open)}`);
          if (hooks.report) lines.push(...(await hooks.report(this, a).catch((x) => [`${a.key}'s report: ${(x as Error).message}`])).map((l) => `  ${l}`));
          lines.push(...a.trail.slice(-40).map((l) => "  " + l));
          lines.push(...a.consoles.slice(-15).map((l) => "  " + l));
        }
        await this.close(!!stuck);
        return lines.join("\n");
      }
    }
    clearInterval(this.beat);
    const off = (this.skipped.size ? `; steps behind ${[...this.skipped].sort().join(", ")} skipped, off here` : "") +
      (this.onHere.size ? `; steps for ${[...this.onHere].sort().join(", ")} off skipped, on here` : "");
    console.log(`✓ ${this.s.id} (${Math.round((Date.now() - t0) / 1000)}s): ${this.s.accepts.join(", ")}${off}`);
    await this.close();
    return null;
  }
  // A wedged scenario's contexts are closed without waiting on them: closing waits on its pages, and a
  // wedged page never answers. The browser disposes of them; the scenario is run again at once.
  async close(wedged = false) {
    for (const a of this.actors.values()) {
      const closing = a.ctx.close().catch(() => {});
      if (!wedged) await closing;
    }
  }
}

// At most `parallel` scenarios at once, the longest first, so the short ones fill in beside it.
// ONLY names some of them, comma-separated. Where the app asks for it (schema.cue's `flakes.retry`), with
// RETRY_FAILED (the rehearsal's, tests/rehearse.ts), and always against a deployed app (the rc's verify, which has no rehearsal around it to retry): a
// scenario that fails runs again once, at once, beside those still running, and passes if that
// passes ("⚠ <id> flaked"); its retry overlaps the pass instead of following it. Its first failure
// is printed indented, so only a scenario that failed twice has a "✗ <id> (" line.
const only = Deno.env.get("ONLY")?.split(",");
const wanted = Object.values(spec.scenarios).filter((s) => !only || only.includes(s.id));
// A scenario that needs a stack's stand-in (`standin`: billing's for Stripe, a model's, or one that signs in
// with Google through the local broker's) runs where the stand-in is, not on a deployed app, whose broker is
// the real one: skipped there, not failed. A run that skips every scenario it was asked for has shown nothing.
const isDeployed = deployed(new URL(URL_).hostname);
const needsStandIn = (s: Scenario) => !!s.standin || JSON.stringify(s.steps).includes('"google":');
const skipped = isDeployed ? wanted.filter(needsStandIn) : [];
for (const s of skipped) console.log(`- ${s.id}: skipped (needs a stack's stand-in; a laptop's or CI's stack only)`);
const runnable = wanted.filter((s) => !skipped.includes(s));
const unsafe = runnable.filter((s) => !s.production).map((s) => s.id);
if (onProduction && unsafe.length) throw new Error(`${URL_} is production: only scenarios marked production run there, not ${unsafe.join(", ")} (set ONLY)`);
// In the local gate, the ones green on these very inputs are cached and not run (scenarios/select.ts), the
// diff judging the app's client sources by the bytes of the assets they build (`select`).
const sel = select(import.meta.url, URL_, runnable, spec.select.client, { derived: spec.select.derived, inert: spec.select.inert, live: spec.select.live });
await sel.verify(async (path) => {
  const res = await anon.fetch(new URL(path, URL_).href, { failOnStatusCode: false });
  return res.status() !== 200 ? `status ${res.status()}` : sha(await res.body());
});
const queue = [...sel.run].sort((x, y) => y.steps.length - x.steps.length);
if (wanted.length && !queue.length && !sel.cached.length) { console.log("scenarios: every one skipped, so nothing was shown"); Deno.exit(1); }
// SCENARIOS_QUEUE (the rehearsal's, tests/rehearse.ts): a folder this run shares with other runs of the same pass,
// each against its own stack. A scenario is run by the run that takes it first (an atomic mkdir of its id there);
// the others pass over it. So a lane whose own check ended helps a pass still going, and every scenario still runs
// once (PRONTO-37: the Premium lane sat idle ~500 s of the rehearsal's ~860 while lane 1 ran the pass alone).
const shared = Deno.env.get("SCENARIOS_QUEUE");
const take = (id: string) => { if (!shared) return true; try { Deno.mkdirSync(`${shared}/${id}`, { recursive: false }); return true; } catch { return false; } };
const ran: string[] = [];
const failed: string[] = [];
const retry = spec.flakes.retry && (!!Deno.env.get("RETRY_FAILED") || isDeployed);
const t0 = Date.now();
if (slow) console.log(`scenarios: ${gate ? "the scenarios marked slow" : "every scenario"}, every page with ${slow}`);
await Promise.all(Array.from({ length: Math.min(isDeployed ? spec.deployedParallel : spec.parallel, queue.length) }, async () => {
  for (let s = queue.shift(); s; s = queue.shift()) {
    if (!take(s.id)) continue;
    ran.push(s.id);
    let r = new Run(s), f = await r.run();
    // A wedged renderer is run again, twice at most, and said so.
    for (let again = 0; r.stuck && again < 2; again++) { console.log(`↻ ${s.id}: ${r.stuck} (a throttled renderer's wedge), run again`); r = new Run(s); f = await r.run(); }
    if (f && retry && !pageErrors.length) {
      console.log(`↻ ${s.id}: failed, run again once:\n${f.split("\n").map((l) => `  ${l}`).join("\n")}`);
      r = new Run(s);
      f = await r.run();
      if (!f) console.log(`⚠ ${s.id} flaked, passed on its one retry`);
    }
    if (f) { console.log(f); failed.push(s.id); }
  }
}));
// The flake report (schema.cue's `flakes`): each scenario that failed beside others, run again alone
// once the pass is over. One that passes alone flaked under load: it stays failed, and is said and filed.
const flaked: string[] = [];
if (!retry && !shared && !pageErrors.length && ran.length > 1) {
  for (const id of failed) {
    const r = new Run(spec.scenarios[id]);
    if (await r.run()) { console.log(`✗ ${id} fails alone too: not a flake`); continue; }
    flaked.push(id);
    console.log(`⚠ ${id} flaked under load: failed beside ${Math.min(spec.parallel, ran.length) - 1} others, passed run alone`);
    await fileFlake(id);
  }
}
sel.commit(ran.filter((id) => !failed.includes(id) && !pageErrors.length), failed);
await anon.dispose();
await browser.close();
console.log(`scenarios: ${(shared ? ran.length : runnable.length) - failed.length} passed (${sel.cached.length} cached${shared ? `, ${sel.run.length - ran.length} run by another lane` : ""}${skipped.length ? `, ${skipped.length} skipped` : ""}), ${failed.length} failed, in ${Math.round((Date.now() - t0) / 1000)}s`);
if (pageErrors.length) console.log(`page errors:\n${pageErrors.join("\n")}`);
if (flaked.length) console.log(`flakes under load: ${flaked.join(", ")}`);
if (failed.length || pageErrors.length) Deno.exit(1);

// Files a flake once a week per scenario (a marker under ~/.cache/pronto/flakes/<app>); FLAKES_FILE=0 files none.
async function fileFlake(id: string) {
  if (Deno.env.get("FLAKES_FILE") === "0") return console.log(`  not filed (FLAKES_FILE=0)`);
  const app = spec.flakes.app ?? appName;
  const marks = `${Deno.env.get("HOME")}/.cache/pronto/flakes/${app}`, mark = `${marks}/${id}`;
  const at = (await Deno.stat(mark).catch(() => null))?.mtime?.getTime() ?? 0;
  if (Date.now() - at < 7 * 86400_000) return console.log(`  already filed (${mark})`);
  const top = await new Deno.Command("git", { args: ["rev-parse", "--show-toplevel"], cwd: here(".").pathname, stdout: "piped", stderr: "null" }).output();
  const head = await new Deno.Command("git", { args: ["rev-parse", "--short", "HEAD"], cwd: here(".").pathname, stdout: "piped", stderr: "null" }).output();
  const repo = new TextDecoder().decode(top.stdout).trim(), commit = new TextDecoder().decode(head.stdout).trim();
  const run = Deno.env.get("GITHUB_RUN_ID") ? `${Deno.env.get("GITHUB_SERVER_URL")}/${Deno.env.get("GITHUB_REPOSITORY")}/actions/runs/${Deno.env.get("GITHUB_RUN_ID")}` : "a local run";
  const [cmd, ...args] = spec.flakes.file;
  // A filing that fails fails the run: a flake left unfiled, or filed without its marker (filed again next run), is never only logged.
  const out = await new Deno.Command(cmd === "deno" ? Deno.execPath() : cmd, {
    args: [...args, repo, "--app", app, "--bug", "true", "--priority", spec.flakes.priority,
      "--title", `Flake: ${id} fails under load, passes alone`,
      "--body", `Scenario ${id} failed in a pass of ${ran.length} beside others at ${commit} (${run}) and passed run alone right after, on the same head. A flake is a bug in the app or the harness, fixed at its cause (AGENTS.md); the runner's report is in that run's log.`],
    env: { CLOUDSDK_ACTIVE_CONFIG_NAME: Deno.env.get("CLOUDSDK_ACTIVE_CONFIG_NAME") ?? "pronto" },
    stdout: "piped", stderr: "piped",
  }).output();
  const said = new TextDecoder().decode(out.stdout).trim().split("\n").at(-1) ?? "";
  if (!out.success) throw new Error(`flake ${id} not filed: the board said ${new TextDecoder().decode(out.stderr).trim().split("\n").at(-1)}`);
  await Deno.mkdir(marks, { recursive: true });
  await Deno.writeTextFile(mark, said);
  console.log(`  filed: ${said}`);
}
