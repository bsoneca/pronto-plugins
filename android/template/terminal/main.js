// The Android terminal: omnishell's interpreter, unchanged, over the host's
// browser (browser.js), its page drawn natively (display.js).
import "./browser.js";
import { createShell } from "omnishell/interpreter/shell.js";
import { startDisplay } from "./display.js";

const fail = (e) => console.error("terminal failed", e);
globalThis.addEventListener("unhandledrejection", (e) => fail(e.reason));
// The shell boots when the host calls __boot: after this script, once the host has registered the
// hatch modules, which QuickJS evaluates as they are added and which read the browser this script
// sets up (window, navigator), and before any screen imports one.
// Booted (the screen shown, the guest signed in): the mark a driver waits for, as the web's
// waits for its boot script to leave.
globalThis.__boot = () => {
  createShell({ config: "./shell.json", mount: document.getElementById("app"), liveUpdates: false, preload: false })
    .then(() => document.documentElement.setAttribute("data-terminal-ready", ""))
    .catch(fail);
};
startDisplay();
