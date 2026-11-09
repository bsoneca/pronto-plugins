---
name: pronto-migrations
description: "Carry a pronto app's live database forward when its entities change: install pronto-migrations, take the snapshot at the release the database runs, and make the migration (pgroll SQL) from the change to the emitted schema, its columns paired by their proto field number, declaring a carry or a backfill when make names one. Use when a change retires a column, makes one required or optional, changes a default, adds or removes a unique or a reference, or removes a value from an enum or a machine's states, or when the app's lint says the model moved since the snapshot; not for an addition, which the replay of the emitted schema makes by itself."
---

# pronto-migrations

A plugin beside pronto, not part of it ([migrations/README.md](../../migrations/README.md)). The
model is what pronto's generate writes (`schema/entities.proto`, `.pronto/check-inputs.json`,
`010_machines.sql`). The migrations are the changes from `migrations/snapshot.json` to that model.
Each is written as one pgroll operation into `code.state.migrations`. Run every command from the
app's folder.

## Once per app

```sh
<pronto-plugins>/bin/pronto-migrations .
deno run --no-config -A migrations/migrate.ts init --from <ref>
```

`--from` names the git ref the live database runs: the app's last release tag. Plain `init` is for an
app with no live database. Commit everything the installer and init wrote: `migrations/` (the driver,
its rules, `.gitattributes`, the snapshot and the sum), `migrations_plugin.cue`, `migrations_spec.cue`
and `migrations_ledger.cue`. `check` needs deno; `plan` and `make` also need `cue` on the PATH.

## Each change to an entity

1. Change the CUE and run `./saytw generate`. A column is never renamed or retyped: add a field under
   a new ordinal and retire the old one (`retired: true`). The plugin refuses anything else.
2. `deno run --no-config -A migrations/migrate.ts plan` shows each change, its verdict
   (refused, ledger, replay or advisory) and the SQL.
3. `deno run --no-config -A migrations/migrate.ts make <name>`, `<name>` saying what the migration
   does (`retire_ref`). When it says `needs`, declare what it names in `migrations_spec.cue`, then
   run it again:
   - `carry.<Entity>.<column>`: rows holding a value the column no longer admits. Use `values`
     (old → new) or `set` (SQL of the old row per column). Add `triggers` for any other machine's
     column that `set` moves.
   - `backfill.<Entity>.<column>`: the value the NULL rows of a column made required take, when it
     has no default, or only one read from the session, such as `auth_uid()`.
4. Commit what make wrote: `migrations/<YYYYMMDD>_<NNNN>_<name>.json` (the day, its count that day,
   what it does, e.g. `20261109_0001_retire_ref`; the machine's calendar day), the snapshot, the sum and the
   ledger.
   Delete the declaration once its migration is written.

A change that only adds (an entity, an optional or defaulted column, an enum value, an index) writes
no migration: make moves the snapshot, and the replay adds it.

## When make refuses

- **`… was dropped by <migration>, which every fresh database still runs after building it: fold …`**:
  an index, check or machine's trigger that an earlier migration dropped is built again by the replay. Once every database has run that migration, run
  `deno run --no-config -A migrations/migrate.ts fold <that migration>`, then make again.
- **A merge conflict** on `snapshot.json` and `migrations.sum`: take main's side of both and of
  `migrations_ledger.cue`, delete your branch's migration, restore its carry or backfill in
  `migrations_spec.cue`, and run make again.

## What not to do

- Do not edit a migration, the snapshot or the sum by hand. The lint refuses it, and so does make.
  Make another migration instead.
- Do not write the carry as SQL in a replayed file. That SQL runs on every release; a migration runs
  once, and pgroll records it.
- Do not add a required column with no default to a table that has rows. The replay fails before any
  migration runs. Add it optional, then make it required with a backfill.
- Do not fold a migration that some database has not yet run.
