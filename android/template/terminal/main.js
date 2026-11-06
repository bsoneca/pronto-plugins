// The Android terminal: omnishell's interpreter, unchanged, over the host's
// browser (browser.js), its page drawn natively (display.js).
import "./browser.js";
import { createShell } from "omnishell/interpreter/shell.js";
import { startDisplay } from "./display.js";

const fail = (e) => console.error("terminal failed", e);
globalThis.addEventListener("unhandledrejection", (e) => fail(e.reason));
createShell({ config: "./shell.json", mount: document.getElementById("app"), liveUpdates: false, preload: false }).catch(fail);
startDisplay();
