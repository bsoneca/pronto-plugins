// The journeys plugin as this app wires it: the program's own screens are what
// a moment must name, and observability/ is what the program exports.

import { assertEquals, assertStringIncludes, cue } from "./cue.ts";

// The program copied beside a case file: a package of its own, so a case never
// joins the app's package, with the files the program embeds.
const SCRATCH = "tests/scratch_journeys";

async function vetWith(caseCue: string): Promise<{ ok: boolean; out: string }> {
  await Deno.remove(SCRATCH, { recursive: true }).catch(() => {});
  await Deno.mkdir(`${SCRATCH}/messages`, { recursive: true });
  try {
    for await (const entry of Deno.readDir(".")) {
      if (entry.isFile && (entry.name.endsWith(".cue") || entry.name === "DESIGN.md" || entry.name === "bayt.json")) {
        await Deno.copyFile(entry.name, `${SCRATCH}/${entry.name}`);
      }
    }
    for await (const entry of Deno.readDir("messages")) await Deno.copyFile(`messages/${entry.name}`, `${SCRATCH}/messages/${entry.name}`);
    if (caseCue) await Deno.writeTextFile(`${SCRATCH}/zz_case.cue`, `package hello_journeys\n\n${caseCue}\n`);
    return await cue(["vet", "-c=false", `./${SCRATCH}`]);
  } finally {
    await Deno.remove(SCRATCH, { recursive: true });
  }
}

Deno.test("the program vets with its journeys bound to its own screens", async () => {
  const { ok, out } = await vetWith("");
  assertEquals(ok, true, out);
});

Deno.test("a journey moment the program's screens do not declare refuses at cue vet", async () => {
  const { ok, out } = await vetWith(`journeys: spec: bad: {owner: "o", moments: ["todo.nope"], slo: availability: 99}`);
  assertEquals(ok, false);
  assertStringIncludes(out, "journey bad moment todo.nope names no gesture nope on screen todo");
});

// Keys in a fixed order, so a file and the export compare as values.
const canonical = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canonical) : v && typeof v === "object"
    ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical((v as Record<string, unknown>)[k])]))
    : v;

Deno.test("observability/ holds exactly what the program's journeys export", async () => {
  const exported = await cue(["export", ".", "-e", "journeys.out", "--out", "json"]);
  assertEquals(exported.ok, true, exported.out);
  const out = JSON.parse(exported.out) as Record<string, unknown>;
  for (const [file, value] of Object.entries(out)) {
    const onDisk = file.endsWith(".yaml")
      ? JSON.parse((await cue(["export", `observability/${file}`, "--out", "json"])).out)
      : JSON.parse(await Deno.readTextFile(`observability/${file}`));
    assertEquals(canonical(onDisk), canonical(value), `observability/${file} is stale: run sayt generate`);
  }
});
