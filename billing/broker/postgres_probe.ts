// Run by vendor_test.ts in a child Deno WITHOUT --unstable-node-globals, as the broker's image runs: loads the vendored
// postgres.js and talks to a stub server that answers with a Postgres ErrorResponse, so the driver's Buffer, process and
// setImmediate paths run for real. Prints the typeof of the four Node globals it relies on, then the rejection it got.
const server = Deno.listen({ hostname: "127.0.0.1", port: 0 });
const port = (server.addr as Deno.NetAddr).port;
(async () => {
  for await (const conn of server) {
    await conn.read(new Uint8Array(1024));
    const fields = [..."S", ..."FATAL", 0, ..."C", ..."28000", 0, ..."M", ..."stub says no", 0, 0].map((x) => typeof x === "string" ? x.charCodeAt(0) : x);
    const body = new Uint8Array(fields);
    const out = new Uint8Array(5 + body.length);
    out[0] = 69;
    new DataView(out.buffer).setInt32(1, body.length + 4);
    out.set(body, 5);
    await conn.write(out);
    conn.close();
  }
})();
const { default: postgres } = await import("./vendor/postgres.js");
const sql = postgres(`postgres://u:p@127.0.0.1:${port}/d`, { max: 1, connect_timeout: 5, idle_timeout: 1, onnotice: () => {} });
let rejected = "none";
try {
  await sql.unsafe("select 1");
} catch (e) {
  rejected = `${(e as Error).name}: ${(e as Error).message}`;
}
await sql.end({ timeout: 1 }).catch(() => {});
server.close();
// By name on globalThis: the point is whether the runtime provides them, not that this file imports them.
const names = ["Buffer", "process", "setImmediate", "clearImmediate"];
console.log(JSON.stringify({ globals: names.map((n) => typeof (globalThis as Record<string, unknown>)[n]), rejected }));
