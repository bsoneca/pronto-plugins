// The vendored postgres.js needs Node's Buffer, process, setImmediate and clearImmediate. The broker's image (metal.nu's
// pinned Deno, run without --unstable-node-globals) must have them: a child Deno started with no such flag loads the
// driver and makes it talk to a stub, so a Deno that did not provide them fails here, not at the broker's first query.
Deno.test("the vendored postgres driver runs on a Deno started without --unstable-node-globals", async () => {
  const probe = new URL("./postgres_probe.ts", import.meta.url).pathname;
  const out = await new Deno.Command(Deno.execPath(), { args: ["run", "--no-config", "--allow-net", "--allow-env", "--allow-read", probe], stderr: "piped" }).output();
  const err = new TextDecoder().decode(out.stderr);
  if (!out.success) throw new Error(`the probe failed: ${err}`);
  const got = JSON.parse(new TextDecoder().decode(out.stdout).trim().split("\n").at(-1)!);
  if (JSON.stringify(got.globals) !== JSON.stringify(["function", "object", "function", "function"])) throw new Error(`Node globals missing: ${JSON.stringify(got.globals)}`);
  if (!/^PostgresError: stub says no$/.test(got.rejected)) throw new Error(`the driver did not reach the stub's error: ${got.rejected}`);
});
