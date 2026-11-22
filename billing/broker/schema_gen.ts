// Writes schema.sql, the broker's tables as an add-only, idempotent script (store.ts's SCHEMA), or with
// --check fails when it is not what SCHEMA says: deno run --allow-read --allow-write billing/broker/schema_gen.ts [--check]
import { SCHEMA } from "./store.ts";

const HEADER = `-- The billing broker's tables (broker/store.ts's SCHEMA): add-only and idempotent, so it may be applied
-- again on any database that has them. The broker makes no tables itself and checks at start that these
-- exist. Nothing here drops or rewrites anything. Generated: deno run -A billing/broker/schema_gen.ts\n`;
export const schemaSql = (): string => `${HEADER}${SCHEMA.map((s) => `${s};`).join("\n")}\n`;

if (import.meta.main) {
  const to = new URL("./schema.sql", import.meta.url);
  if (Deno.args.includes("--check")) {
    if ((await Deno.readTextFile(to)) !== schemaSql()) {
      console.error("billing/broker/schema.sql is not what store.ts says: run schema_gen.ts");
      Deno.exit(1);
    }
  } else await Deno.writeTextFile(to, schemaSql());
}
