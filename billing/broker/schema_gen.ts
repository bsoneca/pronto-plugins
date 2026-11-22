// Writes schema.sql, the broker's tables as an add-only, idempotent script (store.ts's SCHEMA), or with
// --check fails when it is not what SCHEMA says: deno run --allow-read --allow-write billing/broker/schema_gen.ts [--check]
import { SCHEMA } from "./store.ts";

const HEADER = `-- The billing broker's tables (broker/store.ts's SCHEMA): add-only and idempotent, so it may be applied
-- again on any database that has them. The broker makes no tables itself and checks at start that these
-- exist. Nothing here drops or rewrites anything. Generated: deno run -A billing/broker/schema_gen.ts\n`;
// As the app's other raw migrations start (the app's squawk lint requires both timeouts), and an index on these new,
// empty tables is made without CONCURRENTLY: IF NOT EXISTS makes a rerun a no-op.
const TIMEOUTS = "SET lock_timeout = '5s';\nSET statement_timeout = '60s';\n";
const statement = (s: string) => `${/^CREATE INDEX/.test(s) ? "-- squawk-ignore require-concurrent-index-creation\n" : ""}${s};`;
export const schemaSql = (): string => `${HEADER}${TIMEOUTS}${SCHEMA.map(statement).join("\n")}\n`;

if (import.meta.main) {
  const to = new URL("./schema.sql", import.meta.url);
  if (Deno.args.includes("--check")) {
    if ((await Deno.readTextFile(to)) !== schemaSql()) {
      console.error("billing/broker/schema.sql is not what store.ts says: run schema_gen.ts");
      Deno.exit(1);
    }
  } else await Deno.writeTextFile(to, schemaSql());
}
