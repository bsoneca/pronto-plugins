import { assertEquals } from "jsr:@std/assert@1";
import { rulesTs } from "./rules_gen.ts";

Deno.test("rules.ts is what rules.cue says", async () => {
  assertEquals(await Deno.readTextFile(new URL("./rules.ts", import.meta.url)), await rulesTs());
});
