import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { guarded, has, MARKER, route } from "./guard.ts";

const caddy = `(app) {
  encode zstd gzip
  # Chromium probes /favicon.ico.
  handle /favicon.ico {
    respond 204
  }
  handle /crud/* {
    handle /nested {
      respond 200
    }
  }
}
`;

Deno.test("the block goes before the first top-level handle and its comment", () => {
  const out = guarded(caddy).split("\n");
  const block = out.findIndex((l) => l.includes(MARKER));
  const first = out.findIndex((l) => /^\s*handle \//.test(l));
  assert(block > 0 && block < first, out.join("\n"));
  assert(out.indexOf("  # Chromium probes /favicon.ico.") > out.indexOf("  # doorguard:end"), "the handle's comment stays with it");
  assert(out.indexOf("  encode zstd gzip") < block);
  assert(has(guarded(caddy)) && !has(caddy));
});

Deno.test("it is idempotent", () => {
  assertEquals(guarded(guarded(caddy)), guarded(caddy));
});

Deno.test("a Caddyfile with no handle throws", () => {
  assertThrows(() => guarded("(app) {\n  encode gzip\n}\n"), Error, "no top-level `handle");
});

Deno.test("route writes the file once", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.mkdir(`${dir}/docker`);
    await Deno.writeTextFile(`${dir}/docker/Caddyfile`, caddy);
    await route(dir);
    const once = await Deno.readTextFile(`${dir}/docker/Caddyfile`);
    assertEquals(once, guarded(caddy));
    await route(dir);
    assertEquals(await Deno.readTextFile(`${dir}/docker/Caddyfile`), once);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
