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

const META = ["by", "timeout", "why", "fresh"];
export const KINDS = ["open", "see", "hidden", "attached", "count", "text", "value", "attr", "click", "fill", "select", "press", "submit", "keep", "pause", "shot", "closeDialogs"];

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

class Phone {
  messages: Record<string, any> = {};
  constructor(readonly id: string, readonly base: string) {}

  /** The elements a selector finds, each with whether it is shown (not hidden and drawn) and, if so, its box. */
  async find(selector: string, boxes = true): Promise<(Probed & { box?: Box })[] | undefined> {
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
    await sh(`am start -S -n ${this.id}/.MainActivity --es base ${quote(this.base)} --es path ${quote(path)} --es actor ${quote(actor)}`);
    await until(`${actor}'s terminal at ${path}`, 30, async () => {
      const ready = await this.find("html[data-terminal-ready]", false);
      return [ready && ready.length > 0 ? ready : null, ready ? "the terminal has not booted" : "the driver does not answer"];
    });
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
    await this.hideKeyboard();
    await this.tap(await this.shownOf(selectors, seconds, `click ${selectors.join(" | ")}`));
  }

  async fillIn(selector: string, value: string, seconds: number) {
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
  await adb("logcat", "-c");
  await sh(`pm clear ${phone.id}`);
  let i = 0;
  try {
    for (; i < sc.steps.length; i++) {
      const raw = sc.steps[i];
      const { timeout, kind, arg } = normalize(raw);
      const actor = actorOf(raw, sc.actors, current);
      const sub = (s: string) => substitute(s, vars);
      if (kind === "open") {
        const path = sub(arg as string);
        opened[actor] = path;
        current = actor;
        await phone.start(path, actor);
        continue;
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
        case "pause": await sleep(Number(arg) * 1000 * slow()); break;
        case "shot": {
          await Deno.mkdir(dir, { recursive: true });
          await Deno.writeFile(`${dir}/${name}-${sub(arg)}.png`, await runBytes(adbPath(), ["exec-out", "screencap", "-p"]));
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
          const a = typeof arg === "object" ? { ...arg, of: undefined, is: typeof arg.is === "string" ? sub(arg.is) : arg.is, has: typeof arg.has === "string" ? sub(arg.has) : arg.has } : arg;
          await until(`${kind} ${sel}`, timeout, async () => {
            const els = await phone.find(sel, kind === "see" || kind === "hidden");
            if (!els) return [null, "the driver does not answer"];
            const why = holds(kind, a, els, phone.messages);
            return [why === null ? true : null, why ?? ""];
          });
        }
      }
    }
  } catch (e) {
    const why = (sc.steps[i] as Step | undefined)?.why;
    const detail = `${e instanceof Error ? e.message : e} [step ${i + 1} of ${sc.steps.length}${why ? `, why: ${why}` : ""}]`;
    await Deno.mkdir(dir, { recursive: true });
    const shot = `${dir}/${name}-fail.png`;
    await Deno.writeFile(shot, await runBytes(adbPath(), ["exec-out", "screencap", "-p"], false)).catch(() => {});
    const log = (await run(adbPath(), ["logcat", "-d", "-s", "pronto:*"], { check: false })).trim().split("\n").slice(-60).join("\n");
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
