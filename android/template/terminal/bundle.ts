// The terminal as one script: omnishell at the app's pin, its interpreter
// unchanged, with this directory's browser and display. Run by build@android
// from the app's root: deno run -A --no-lock android/terminal/bundle.ts <omnishell-dir>.
import { transform, stop } from "npm:esbuild@0.25.12";
import { localRoots } from "./trust.ts";

const [omnishell] = Deno.args;
if (!omnishell) throw new Error("bundle: name omnishell's directory");
const here = new URL(".", import.meta.url).pathname;
const dir = "android/app/build/generated/terminal";
await Deno.mkdir(`${dir}/messages`, { recursive: true });
const map = `${dir}/imports.json`;
const esm = `${dir}/terminal.esm.js`;
await Deno.writeTextFile(map, JSON.stringify({ imports: { "omnishell/": `file://${omnishell.replace(/\/*$/, "")}/` } }));
const { success } = await new Deno.Command(Deno.execPath(), {
  args: ["bundle", "--quiet", "--no-lock", "--platform", "browser", "--import-map", map, `${here}main.js`, "-o", esm],
  stdout: "inherit",
  stderr: "inherit",
}).output();
if (!success) throw new Error("bundle: deno bundle failed");
// One script, since quickjs-kt cannot compile a module once SES is loaded. A
// module's own address only ever names files the bundle already holds.
const { code } = await transform(await Deno.readTextFile(esm), {
  format: "iife",
  target: "es2023",
  charset: "utf8",
  define: { "import.meta.url": JSON.stringify("https://terminal.invalid/omnishell/interpreter/bundled.js") },
  logLevel: "warning",
});
await stop();
await Deno.writeTextFile(`${dir}/terminal.js`, code);
await Deno.remove(esm);
await Deno.remove(map);
// The hatches android/android.json binds (`hatches: {<name>: {binding}}`, the hatch contract's binding.json, the
// same file the Unity host runs): each is one module, this directory's bound.js over the app's pure module,
// written under bound/ at the address of the web's host-DOM module (shell.json hostDom.<name>.src), where
// TerminalEngine registers it in that module's place. The web's (three.js, a canvas) is never loaded.
const boundDir = `${dir}/bound`;
await Deno.remove(boundDir, { recursive: true }).catch(() => {});
const declared = JSON.parse(await Deno.readTextFile("android/android.json")).hatches ?? {};
const hostDom = JSON.parse(await Deno.readTextFile("shell/shell.json")).hostDom ?? {};
for (const [name, { binding }] of Object.entries(declared as Record<string, { binding: string }>)) {
  const src: string | undefined = hostDom[name]?.src;
  if (!src?.startsWith("shell/hatches/")) throw new Error(`bundle: hatch ${name} is bound in android/android.json but shell.json declares no host-DOM hatch ${name}`);
  const json = await Deno.readTextFile(binding);
  const { module } = JSON.parse(json);
  const out = `${boundDir}/${src.slice("shell/".length)}`;
  await Deno.mkdir(out.slice(0, out.lastIndexOf("/")), { recursive: true });
  const entry = await Deno.makeTempFile({ dir: ".", prefix: ".bound-", suffix: ".js" });
  try {
    await Deno.writeTextFile(entry, [
      `import * as hatch from ${JSON.stringify(`./${module}`)};`,
      `import { bound } from ${JSON.stringify(`${here}bound.js`)};`,
      `export default bound(${JSON.stringify(name)}, ${json.trim()}, hatch);`,
    ].join("\n"));
    const made = await new Deno.Command(Deno.execPath(), {
      args: ["bundle", "--quiet", "--no-lock", "--platform", "browser", entry, "-o", out],
      stdout: "inherit",
      stderr: "inherit",
    }).output();
    if (!made.success) throw new Error(`bundle: hatch ${name}'s module did not bundle`);
  } finally {
    await Deno.remove(entry);
  }
  console.log(`bound hatch ${name}: ${binding} at ${src}`);
}
// SES at omnishell's own pin, so the phone's cage is the page's.
await Deno.copyFile(`${omnishell}/interpreter/vendor/ses.umd.min.js`, `${dir}/ses.umd.min.js`);
// The catalogues the interpreter fetches beside the screens, under the same names.
try {
  for await (const f of Deno.readDir("messages")) if (f.name.endsWith(".json")) await Deno.copyFile(`messages/${f.name}`, `${dir}/messages/${f.name}`);
} catch (e) {
  if (!(e instanceof Deno.errors.NotFound)) throw e;
}
// A debug build trusts the machine's local stack: its door (Caddy) serves https://localhost
// under Caddy's local root, reached through adb reverse; mkcert's root too, where there is one.
// Never in a release build.
const res = "android/app/build/generated/debug-res";
await Deno.mkdir(`${res}/xml`, { recursive: true });
await Deno.mkdir(`${res}/raw`, { recursive: true });
const roots = await localRoots();
const trusted: string[] = [];
for (const name of ["local_caddy", "local_ca"]) {
  if (roots[name]) {
    await Deno.writeTextFile(`${res}/raw/${name}.pem`, roots[name]);
    trusted.push(name);
  } else {
    await Deno.remove(`${res}/raw/${name}.pem`).catch(() => {});
  }
}
await Deno.writeTextFile(`${res}/xml/local_stack.xml`, `<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />${trusted.map((n) => `\n            <certificates src="@raw/${n}" />`).join("")}
        </trust-anchors>
    </base-config>
</network-security-config>
`);
console.log(`bundled ${dir}/terminal.js: ${code.length} bytes`);
