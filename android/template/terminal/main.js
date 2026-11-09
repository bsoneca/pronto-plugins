// The Android terminal: omnishell's interpreter, unchanged, over the host's
// browser (browser.js), its page drawn natively (display.js).
import "./browser.js";
import { createShell } from "omnishell/interpreter/shell.js";
import { evaluateRole } from "omnishell/interpreter/jessie.js";
import { startDisplay } from "./display.js";

const fail = (e) => console.error("terminal failed", e);
globalThis.addEventListener("unhandledrejection", (e) => fail(e.reason));
// The shell boots when the host calls __boot: after this script, once the host has registered the
// hatch modules, which QuickJS evaluates as they are added and which read the browser this script
// sets up (window, navigator), and before any screen imports one.
// Booted (the screen shown, the guest signed in): the mark a driver waits for, as the web's
// waits for its boot script to leave.
// The shell once booted: what the autofill's bridges below wait on, as a headless engine is asked
// before its boot is done.
let booted;
const ready = new Promise((resolve) => { booted = resolve; });
globalThis.__boot = () => {
  createShell({ config: "./shell.json", mount: document.getElementById("app"), liveUpdates: false, preload: false })
    .then((shell) => {
      booted(shell);
      document.documentElement.setAttribute("data-terminal-ready", "");
    })
    .catch(fail);
};

// The autofill's ask (FillActivity.kt), the app's own handler and never a second implementation:
// the module shell.json's routes name, compiled as a screen compiles it (evaluateRole, with the
// endowments shell.json grants that path), over the tables it reads as a screen reads them, with
// the stated ones (the probe) in place of the store's. Answers the reply as JSON.
const handlerPath = (cfg, name) => {
  for (const route of cfg.routes ?? []) {
    const path = (route.files?.handlers ?? []).find((p) => p.split("/").pop() === `${name}.js`);
    if (path) return path;
  }
  throw new Error(`no Jessie module for handler "${name}"`);
};
globalThis.__ask = async (name, reads, stated, event) => {
  const shell = await ready;
  const cfg = await (await fetch("./shell.json")).json();
  const path = handlerPath(cfg, name);
  const source = await (await fetch(new URL(path, new URL("./", location.href)))).text();
  const reduce = await evaluateRole(source, "handler", (cfg.endowments ?? {})[path] ?? []);
  const given = JSON.parse(stated);
  const rows = Object.fromEntries(await Promise.all(reads.map(async (t) =>
    [t, given[t] ?? await shell.store.query(t, null, { current: true })])));
  return JSON.stringify(reduce({ items: [], rows }, JSON.parse(event)));
};
// A table's rows as the store holds them (the vault's logins, for a fill's datasets).
globalThis.__rows = async (table) => {
  const shell = await ready;
  return JSON.stringify(await shell.store.query(table, null, { current: true }));
};
// A fill's pins (Ask.pins): patches to one table, answered "" or the refusal's message.
globalThis.__patch = async (table, patches) => {
  const shell = await ready;
  let refusal = null;
  await shell.store.patch(table, JSON.parse(patches).map((p) => ({ key: p.id, changes: p.row })), (err) => {
    refusal = String(err?.message ?? err);
  });
  return refusal ?? "";
};
startDisplay();
