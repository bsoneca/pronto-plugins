// Writes rules.ts from rules.cue (`cue export`), or with --check fails when rules.ts is not what
// rules.cue says: deno run --allow-run --allow-read --allow-write billing/rules_gen.ts [--check]
const here = new URL(".", import.meta.url).pathname;
export async function rulesTs(): Promise<string> {
  const out = await new Deno.Command("cue", { args: ["export", `${here}rules.cue`, "-e", "rules", "--out", "json"], stderr: "inherit" }).output();
  if (!out.success) throw new Error("cue export rules.cue failed");
  const rules = JSON.stringify(JSON.parse(new TextDecoder().decode(out.stdout)), null, 2);
  return `// generated from billing/rules.cue by billing/rules_gen.ts — do not edit\n// What a tenant's billing document may say, and the words an entitlement may use.\nexport const RULES = ${rules} as const;\n`;
}
if (import.meta.main) {
  const text = await rulesTs();
  const path = `${here}rules.ts`;
  if (Deno.args.includes("--check")) {
    if ((await Deno.readTextFile(path).catch(() => "")) !== text) throw new Error("billing/rules.ts is not what billing/rules.cue says: run billing/rules_gen.ts");
  } else await Deno.writeTextFile(path, text);
}
