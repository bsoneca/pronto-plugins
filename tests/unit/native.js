// What the native suite's cases call (tests/unit/native.cue): the shared host contract (native/*.cue) read by
// `cue export`, the host battery run on the headless engine (native/deno_host.ts), the Android host held to the
// contract (its Kotlin bridges, its bundle's callbacks), and its generated files held to a golden of digests
// (android/golden/*.json, written when GOLDEN_UPDATE=1).
import { createHash } from "node:crypto";

const root = new URL("../../", import.meta.url).pathname;
const decode = (b) => new TextDecoder().decode(b);

function cue(args) {
  const o = new Deno.Command(Deno.env.get("CUE") ?? "cue", { args, cwd: root, stdout: "piped", stderr: "piped" }).outputSync();
  if (!o.success) throw new Error(`cue ${args.join(" ")}: ${decode(o.stderr)}`);
  return decode(o.stdout);
}

/** An expression of a package, exported: native.exportOf("./native", "bridges.__native_fetch.group"). */
export const exportOf = (pkg, expr, tags) => JSON.parse(cue(["export", pkg, ...(tags ?? []).flatMap((t) => ["-t", t]), "-e", expr, "--out", "json"]));

const read = (path) => Deno.readTextFileSync(root + path);
const sorted = (l) => [...l].sort();

/** The battery run on the headless engine: the cases that failed. */
export function battery() {
  const dir = Deno.makeTempDirSync();
  try {
    Deno.writeTextFileSync(`${dir}/battery.json`, JSON.stringify(exportOf("./native", "battery")));
    const o = new Deno.Command(Deno.execPath(), {
      args: ["run", "--no-config", "--allow-read", "--allow-env", `${root}native/deno_host.ts`, `${dir}/battery.json`],
      stdout: "piped", stderr: "piped",
    }).outputSync();
    if (!o.success) throw new Error(`the battery's host failed: ${decode(o.stderr)}`);
    const results = JSON.parse(decode(o.stdout));
    return { failed: results.filter((r) => !r.ok) };
  } finally {
    Deno.removeSync(dir, { recursive: true });
  }
}

/** The bridges the contract names against the ones Android's engine defines: what is missing from Android, and what it adds. */
export function androidBridges() {
  const contract = Object.keys(exportOf("./native", "bridges"));
  const have = [...read("android/template/terminal/app/src/main/kotlin/TerminalEngine.kt").matchAll(/qjs\.function\("(__native_\w+)"\)/g)].map((m) => m[1]);
  return { missing: sorted(contract.filter((n) => !have.includes(n))), extra: sorted(have.filter((n) => !contract.includes(n))) };
}

/** The callbacks the contract names against the ones Android's bundle defines. */
export function androidCallbacks() {
  const contract = Object.keys(exportOf("./native", "callbacks"));
  const text = ["browser.js", "display.js", "main.js"].map((f) => read(`android/template/terminal/${f}`)).join("\n");
  const have = [...text.matchAll(/\b(?:g|globalThis)\.(__(?:on[A-Z]\w*|goBack))\s*=/g)].map((m) => m[1]);
  return { missing: sorted(contract.filter((n) => !have.includes(n))), extra: sorted(have.filter((n) => !contract.includes(n))) };
}

const digest = (text) => createHash("sha256").update(text).digest("hex");

/** The files the Android host writes for an app, by tags, as path to SHA-256 of the text. */
function filesDigests(tags) {
  const files = exportOf("./android/export", "files", tags);
  return Object.fromEntries(Object.keys(files).sort().map((p) => [p, digest(files[p].text) + (files[p].seed ? " seed" : "") + (files[p].merge ? " merge" : "")]));
}

/** The paths whose generated text differs from the golden `android/golden/<name>.json` (all of them, new and gone, named). */
export function golden(name, tags) {
  const now = filesDigests(tags);
  const file = `${root}android/golden/${name}.json`;
  if (Deno.env.get("GOLDEN_UPDATE") === "1") {
    Deno.mkdirSync(`${root}android/golden`, { recursive: true });
    Deno.writeTextFileSync(file, JSON.stringify(now, null, 2) + "\n");
  }
  const want = JSON.parse(Deno.readTextFileSync(file));
  return sorted(new Set([...Object.keys(now), ...Object.keys(want)])).filter((p) => now[p] !== want[p]);
}
