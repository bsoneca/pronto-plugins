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
