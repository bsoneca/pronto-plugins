// The keys service's entry point (README.md, "The keys service"): Postgres under the handlers.
import { configFrom, type Db, keys, migrate, type Query } from "./keys.ts";

type Sql = {
  unsafe(text: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  begin<T>(fn: (tx: Sql) => Promise<T>): Promise<T>;
};

const run = (s: Sql): Query => async (text, params = []) => [...await s.unsafe(text, params)];

export const dbOver = (sql: Sql): Db => ({ query: run(sql), tx: (fn) => sql.begin((t) => fn(run(t))) });

if (import.meta.main) {
  const env = (name: string) => Deno.env.get(name);
  const cfg = configFrom(env);
  const url = env("DATABASE_URL");
  if (!url) throw new Error("DATABASE_URL is required");
  const timeout = Number(env("AUTH_STATEMENT_TIMEOUT_MS") || 0);
  if (!(timeout >= 0)) throw new Error(`AUTH_STATEMENT_TIMEOUT_MS is ${timeout}, not milliseconds`);
  const { default: postgres } = await import("../broker/vendor/postgres.js");
  const sql = postgres(url, {
    max: 5,
    idle_timeout: 30,
    connect_timeout: 10,
    onnotice: () => {},
    ...(timeout > 0 ? { connection: { statement_timeout: timeout } } : {}),
  }) as unknown as Sql;
  const db = dbOver(sql);
  await migrate(db, cfg);
  const local = ["local", "host"].includes(env("SAYT_PLATFORM") ?? "");
  Deno.serve({ hostname: local ? "127.0.0.1" : "0.0.0.0", port: Number(env("KEYS_PORT") || env("PORT") || 8702) }, keys(cfg, db));
}
