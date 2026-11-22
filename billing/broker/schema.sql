-- The billing broker's tables (broker/store.ts's SCHEMA): add-only and idempotent, so it may be applied
-- again on any database that has them. The broker makes no tables itself and checks at start that these
-- exist. Nothing here drops or rewrites anything. Generated: deno run -A billing/broker/schema_gen.ts
SET lock_timeout = '5s';
SET statement_timeout = '60s';
CREATE TABLE IF NOT EXISTS billing_counter (name text PRIMARY KEY, value bigint NOT NULL);
CREATE TABLE IF NOT EXISTS billing_window (
    name text NOT NULL, key text NOT NULL, n integer NOT NULL, started timestamptz NOT NULL,
    PRIMARY KEY (name, key)
  );
-- squawk-ignore require-concurrent-index-creation
CREATE INDEX IF NOT EXISTS billing_window_started ON billing_window (started);
CREATE TABLE IF NOT EXISTS billing_seen (kind text NOT NULL, id text NOT NULL, expires timestamptz NOT NULL, PRIMARY KEY (kind, id));
-- squawk-ignore require-concurrent-index-creation
CREATE INDEX IF NOT EXISTS billing_seen_expires ON billing_seen (expires);
ALTER TABLE billing_seen ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT 'done';
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_seen_state' AND conrelid = 'billing_seen'::regclass) THEN
      ALTER TABLE billing_seen ADD CONSTRAINT billing_seen_state CHECK (state IN ('claimed', 'done'));
    END IF;
  END $$;
