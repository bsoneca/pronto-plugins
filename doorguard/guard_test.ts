import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { BEGIN, BLOCK, END, GUARD, guarded, has, MARKER, route } from "./guard.ts";

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

// PRONTO-916: Caddy's `handle /crud/*` and strip_prefix ignore case, so the guard must too.
const OLD = "  @daprapi path_regexp daprapi ^/(crud|img|blobs|electric)/v1\\.0(-alpha1)?(/|$)";
const oldBlock = [BEGIN, `  ${MARKER}`, OLD, "  handle @daprapi {", "    respond 404", "  }", END];
const withOld = (extra: string[] = []) => caddy.replace("  handle /favicon.ico {", [...oldBlock, ...extra, "  handle /favicon.ico {"].join("\n"));

// The pattern as Go's regexp reads it: `(?i)` is the case-insensitive flag, here a JS one.
const pattern = () => {
  const m = GUARD.match(/path_regexp daprapi \(\?i\)(.+)$/);
  assert(m, "the guard's pattern starts with (?i)");
  return new RegExp(m[1], "i");
};

Deno.test("the guard's pattern matches every spelling of a Dapr API path, whatever its case", () => {
  const re = pattern();
  for (const path of ["/crud/v1.0/metadata", "/CRUD/v1.0/metadata", "/Crud/v1.0/metadata", "/IMG/v1.0/metadata", "/Img/v1.0-alpha1/x", "/img/v1.0-alpha1/x", "/BLOBS/v1.0", "/Electric/v1.0-alpha1/", "/electric/v1.0/"]) {
    assert(re.test(path), path);
  }
  for (const path of ["/crud/v1.0x", "/crud/x", "/imgs/v1.0/metadata", "/CRUD/v2.0/metadata", "/crud/x/v1.0/metadata", "/favicon.ico"]) {
    assert(!re.test(path), path);
  }
  assert(BLOCK.includes(GUARD));
});

Deno.test("a guard that is case-sensitive is not the guard: has() refuses it", () => {
  assert(!has(withOld()));
  assert(has(guarded(withOld())));
});

Deno.test("an existing marked block with the old line is replaced, once, and the result is stable", () => {
  const out = guarded(withOld());
  assert(out.includes(GUARD) && !out.includes(OLD), out);
  assertEquals(out.split("\n").filter((l) => l === BEGIN).length, 1);
  assertEquals(out, guarded(caddy), "the same as a Caddyfile that never had the old guard");
  assertEquals(guarded(out), out);
});

Deno.test("an old block that has the marker but not the begin and end lines is replaced too", () => {
  const bare = caddy.replace("  handle /favicon.ico {", [`  ${MARKER}`, OLD, "  handle @daprapi {", "    respond 404", "  }", "  handle /favicon.ico {"].join("\n"));
  const out = guarded(bare);
  assert(out.includes(GUARD) && !out.includes(OLD), out);
  assertEquals(out.split("\n").filter((l) => l.trim() === MARKER).length, 1, "one guard, not two");
  assertEquals(guarded(out), out);
});

Deno.test("route updates a Caddyfile that carries the old line, and leaves the rest as it was", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.mkdir(`${dir}/docker`);
    await Deno.writeTextFile(`${dir}/docker/Caddyfile`, withOld());
    await route(dir);
    const once = await Deno.readTextFile(`${dir}/docker/Caddyfile`);
    assertEquals(once, guarded(caddy));
    await route(dir);
    assertEquals(await Deno.readTextFile(`${dir}/docker/Caddyfile`), once);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
