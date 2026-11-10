# migrations

An app's database carried forward by migrations made from the changes to its emitted schema, on
unmodified pronto. The proto gives each column its identity (its field number, name, type and
retirement), so a column keeps its name and its type for as long as the app lives. pronto's own facts
and emitted schema beside it (`.pronto/check-inputs.json`, `005_create_tables.sql`,
`010_machines.sql`) say what the column holds, and the migrations' SQL comes from those. What changes
is what a column holds: it is retired, made required or optional, its default moves, a value leaves
its enum or its machine, a reference or a unique goes, and a column added takes another's data. Each such change goes into a migration in pgroll's
grammar, which pronto already runs (`code.state.migrations`). A change that no migration can make
safe is refused before anything is written.

## Why

pronto's generate writes the schema an app wants, not the steps from the one a database holds:
- `005_create_tables.sql` says `CREATE TABLE IF NOT EXISTS` and `ADD COLUMN IF NOT EXISTS`, with
  each column's constraints inline;
- a check is restated `NOT VALID`;
- `010_machines.sql` restates each machine's states and its trigger.

pronto's targets replay these files on every release:
- gcp replays `005` to `008`, `010`, `016` and the app's own `replays`;
- k8s replays `005` to `008` and `016`.

An addition reaches a live database that way. Nothing else does, because `ADD COLUMN IF NOT EXISTS`
skips a column that exists, along with everything written inline on it:

| The model says | A live database keeps |
| --- | --- |
| a column retired (`retired: true`) | its `NOT NULL`, unique, reference and machine, so an insert that no longer writes it fails |
| a column made required | the column nullable, with its NULL rows |
| a column made optional, or its default changed | the old `NOT NULL`, or the old default |
| a value gone from an enum or a machine's states | the rows holding it, outside a check that is `NOT VALID` |
| a check, unique, reference, index or machine removed | the constraint, index or trigger |
| a unique or a reference added to a column | nothing |
| a required column with no default, added | nothing: the replay's `ADD COLUMN ... NOT NULL` fails on a table with rows |

pronto's answer for a live database is a pgroll migration, written by hand
([schema-change-admission](https://github.com/bonisoft3/pronto/blob/main/docs/schema-change-admission.md#pgroll-migrations)).
Nothing tells an author that one is needed. Until one is written, the fix is hand SQL that each replay
runs again. This plugin finds the change and writes the migration.

## The design, after the ORMs that do this at scale

Every mature migration tool has the same parts. The column in bold is what this plugin chose, and
why.

| Part | Django | EF Core | Prisma Migrate | Atlas (Ent) | Alembic | Rails + strong_migrations | **here** |
| --- | --- | --- | --- | --- | --- | --- | --- |
| The model | `models.py` | the `DbContext` model | `schema.prisma` | HCL or SQL, Ent's schema | SQLAlchemy metadata | none: migrations by hand, `schema.rb` dumped | **the CUE entities, as pronto emits them: `schema/entities.proto` and its facts** |
| What the diff starts from | the state replayed from the migration files | `ModelSnapshot`, committed | a shadow database the migrations replay into | a dev database the migration directory replays into | the live database | none | **`migrations/snapshot.json`, committed: EF Core's way. No database is needed, and the pull request shows the model moving** |
| A column's identity | its name | its name | its name | its name | its name (a rename reads as a drop and an add) | none | **its proto field number: a rename is seen, never guessed** |
| The migration | Python operations | C# operations | SQL | SQL | Python operations | Ruby | **pgroll's JSON: one raw SQL operation, the changes in three phases (relax, move rows, tighten), each saying where and why** |
| Its name | `0001_<name>`, a count | `<timestamp>_<Name>` | `<timestamp>_<name>` | `<timestamp>_<name>.sql` | a random revision id | `<timestamp>_<name>.rb` | **`<YYYYMMDD>_<NNNN>_<name>`: the day, its count that day, and what it does. It sorts by when it was made, as pgroll's runner needs, and is readable without a clock to the second** |
| Integrity of what was written | none | none | a checksum per migration, in its table | `atlas.sum` | none | none | **`migrations/migrations.sum`, atlas.sum's idea: a file edited by hand fails the lint, and make refuses to run over it** |
| The ledger | `django_migrations` | `__EFMigrationsHistory` | `_prisma_migrations` | `atlas_schema_revisions` | `alembic_version` | `schema_migrations` | **pgroll's, which pronto's clusters already run** |
| Drift caught in CI | `makemigrations --check` | `migrations has-pending-model-changes` | `migrate diff --exit-code` | `migrate lint`, `migrate diff` | `alembic check` | none | **`migrate.ts check`, in the app's lint** |
| An unsafe change | asks about a rename; asks a one-off default for a NOT NULL column | none | warns of data loss | lint's analyzers (destructive changes, NOT NULL with no default) | none | refused, with the safe way to do it | **refused, with the way pronto admits it** |
| A data migration | `RunPython` | `migrationBuilder.Sql` | edit the SQL | edit the SQL | `op.execute` | inside the migration | **declared in CUE (`carry`, `backfill`), and checked: every value gone is carried, to a value still admitted** |
| Old migrations | squashed | removed by hand | squashed into a baseline | squashed into a baseline | none | removed by hand | **`fold`, once every database has run them: pronto's own discipline** |

Two choices differ from most of them.

- **The snapshot, not a database or a release tag.** It is committed beside the migrations, so
  `check` runs offline in well under a second. A reviewer sees the model move in the pull request. It
  does not depend on a release tag that only the machine that releases holds.
- **The proto number, not the name.** Django has to ask whether a column was renamed, and Alembic
  cannot tell. A proto field number is the column's identity, and pronto stamps it as the field's
  ordinal. So a changed name under a number already used is a rename by definition, and a number
  that became `reserved` is a retirement. buf already holds the wire to this. The plugin holds the
  database to it.

## How the proto drives it

`schema/entities.proto` says what a column **is**: its number, its name, its wire type, and its
retirement (`reserved N; reserved "name";`). It carries nothing about what the column holds: every
field is `optional`, with no default and no check.

Three other files that generate writes from the same CUE say that:
- `.pronto/check-inputs.json` (version 1) has, for each live **and retired** field:
  - its type, read through pronto's aliases (`text` is `string`), with a decimal's precision and
    scale;
  - `required`, the default, the enum or check, unique, the reference and generated;
  - and, for the entity, its table and indexes.
- `005_create_tables.sql` has each column as the replay writes it: its type as Postgres holds it
  (what an alias stands for, a domain, a decimal's own domain), and its default, including one
  pronto writes that its facts do not state, a machine's initial state. It has each index too, by
  the name pronto gives it. These are read, never restated, so a pronto that changes them is
  followed, not misread.
- `010_machines.sql` has a machine's states, and each machine's trigger must have its check there.

The model joins them by entity and field number. Where they disagree (a field with no column, a
default the facts state and `005` does not write, an index the facts name and `005` does not build),
the app was not generated. A facts version or a
`010` shape this plugin does not read is a pronto it does not know. Either way, that is an error,
not a guess.

Two models are compared by number. A retirement is a change like any other: the column moves from
what it held to what pronto still emits for it. A default pronto keeps for a retired column (an
`''`, say) stays. Each change is one of four kinds:

| Change | What it is | Why |
| --- | --- | --- |
| a name changed under a number; a type changed (precision and scale too, and an alias with another column type: `tsvector` for `string`, `timestamptz` for `timestamp`); a field gone without `reserved`; a reserved number used again; an entity removed or renamed; its table renamed; a generated column changed; a primary key retired | **refused** | a reader of the JSON reads by name, and an open page or a queued row cannot be migrated: a new field beside a retired one instead (pronto's admission rules), which a `backfill` copies into. An entity no longer used keeps its table: retire each of its fields but the primary key |
| a required column added to an existing table with no default, or with one a migration cannot compute (`auth_uid()`) | **refused** | the replay adds it to every row before any migration runs: give it a default, or add it optional and make it required in a later release (in one release, the replay adds the final `NOT NULL` first) |
| a name an earlier migration dropped, built again by the replay (an index, a check, a machine's trigger and check put back) | **refused** | every fresh database runs that migration after initdb built the name, and would lose it: `fold` the migration first, once every database has run it |
| a column made optional; its default changed or removed; a check, unique, reference, machine or index removed | **ledger**, relax | `DROP NOT NULL`, `SET DEFAULT` or `DROP DEFAULT`, `DROP CONSTRAINT`, `DROP TRIGGER`, `DROP INDEX` |
| a value gone from an enum or a machine | **ledger**, rows | the rows holding it carried, by the declared `carry`; without one, make names it |
| a column made required | **ledger**, rows then tighten | its NULL rows filled from `backfill`, else from its default, then `SET NOT NULL`; with neither, make names the `backfill` it needs |
| a column added, with a `backfill` declared | **ledger**, rows | after the replay adds it, every row the table held takes the `backfill` (another column, the field a rename retired): the data moves to the new field |
| a unique or a reference added | **ledger**, tighten | the constraint pronto's inline `UNIQUE` or `REFERENCES` makes (the reference `NOT VALID`) |
| an index changed | **ledger**, relax then tighten | the old index dropped, then built again |
| an entity or an optional or defaulted column added, with no `backfill`; an enum widened; an index or a machine added | **replay** | the emitted schema makes it; no migration |
| a check changed or added | **advisory** | the replay adds it `NOT VALID`, so rows written before are not checked. No carry can be named, since the values a check admitted before are not known |
| a column added with a default that reads another value each time (`now()`, `gen_random_uuid()`), and no `backfill` | **advisory** | the replay gives every row the table holds the value it reads as it runs: the deploy's time, or a value per row. Declare the `backfill` they should take |

Every kind of change is one entry of `KINDS` in [`plan.js`](plan.js): its verdict, why it is refused,
what to note, the names the replay builds for it, and the SQL it needs. A kind with no entry is an
error, never taken for the replay's.

A unique index added, by the replay or by a migration, is noted too: it is built over every row and
locks writes while it builds, and a duplicate fails it.

## Use

From a pronto app (a `program.cue`, generate run):

```sh
<this repo>/bin/pronto-migrations .
deno run --no-config -A migrations/migrate.ts init --from <ref>   # the release your live database runs; plain `init` for a new app
# change the app's CUE, then generate, then:
deno run --no-config -A migrations/migrate.ts plan                # what make would write
deno run --no-config -A migrations/migrate.ts make retire_ref     # migrations/20261109_0001_retire_ref.json
./saytw lint                                                      # runs migrate.ts check
deno run --no-config -A migrations/migrate.ts rebase main         # after merging main in, when both made a migration
deno run --no-config -A migrations/migrate.ts fold 20261109_0001_retire_ref   # once every database has run it
deno run --no-config -A migrations/migrate.ts upgrade             # after a plugin update changes the snapshot's format
```

| Path in the app | Owner |
| --- | --- |
| `migrations/migrate.ts`, `migrations/plan.js`, `migrations/.gitattributes` | regenerated: the driver, its rules, and LF line ends for what the sum covers |
| `migrations_plugin.cue` | regenerated: `#Migrations`, in the program's package |
| `migrations_ledger.cue` | regenerated: the migrations embedded into `code.state.migrations` |
| `migrations_spec.cue` | seeded, then the app's: the `carry` and `backfill` the next migration needs, and the lint's opt-in |
| `migrations/snapshot.json`, `migrations/migrations.sum`, `migrations/<YYYYMMDD>_<NNNN>_<name>.json` | the app's, written by `init`, `make`, `rebase`, `fold` and `upgrade` only |

All of them are committed: the regenerated files too, as an app commits every host's `*_plugin.cue`.
`check` needs only deno. `plan` and `make` also run `cue` (or the binary `CUE` names) to read the
declarations and the app's migration names from the program.

`migrations_ledger.cue` embeds every `.json` in `migrations/` but the snapshot into
`code.state.migrations`, by a glob, so it is never generated and a merge has nothing in it to settle.
`check` refuses a `.json` there whose name is no migration's. pronto types the migrations with
pgroll's grammar (mecha's `pgroll.#Migration`), so a field pgroll does not know fails the program's
`cue vet`. With no migration the ledger declares nothing, so the cluster gets no migrate step.

A migration's name has three parts: the day make writes it (the machine's calendar day), its count
among that day's migrations (a folded one included), and what it does. For example,
`20261109_0001_retire_ref`, then `20261109_0002_…`; the count starts again the next day.

pgroll's runner refuses a migration that sorts before one it ran, so the name must sort after every
migration the app has:
- if a later day is already used (a machine in a zone ahead), make takes that day, with the next
  count;
- a migration written by hand that sorts after every dated name is refused, so name hand migrations
  the same way.

**When two branches both made a migration**, `snapshot.json` and `migrations.sum` conflict at the
merge, and the branch's migration may sort before one main already released, which pgroll's runner
would refuse. After merging main in and running generate, run
`deno run --no-config -A migrations/migrate.ts rebase main`. It takes main's snapshot, sum and
migrations whole, removes the branch's own migrations, and runs make again under the branch's name,
so the branch's changes become one migration named after main's. If make then names a carry or
backfill (one the branch's migration had, and its declaration was deleted), declare it and run
`make <name>`.

### Declarations

`make` stops at a change that the model alone cannot settle, and names the declaration it needs:

```cue
// migrations_spec.cue
schemaMigrations: carry: Order: status: values: {draft: "open"}   // each value gone → one still admitted

// Or set the row's columns, as SQL of the old row, when the carry also fills another column. A
// machine's column that `set` moves needs its trigger off: its chart never saw these rows.
schemaMigrations: carry: Order: stage: {
	set: {step: "stage", stage: "CASE stage WHEN 'paid' THEN 'settled' ELSE 'new' END"}
	triggers: ["trg_order_step_machine"]
}

schemaMigrations: backfill: Order: note: "''"   // a column made required, with no default

// A column added beside the one a rename retired: the rows the table held copy it.
schemaMigrations: backfill: Order: remark: "note"
```

`make` checks them:
- every value gone has a carry, to a value still admitted;
- `values` and `set` don't both set the column;
- every other machine's column `set` moves has its trigger listed;
- every trigger listed is a machine's on that table.

A declaration serves the migration it was written for. `make` refuses one that no change since the
snapshot reads, as it would otherwise be read into a later change to the same column: remove each in
the change that wrote its migration.

## How it runs

pronto's migrate step replays the emitted schema, then runs the pgroll migrations its ledger lacks.

**One operation, three phases.** A migration is one raw SQL operation, because pgroll 0.16 refuses a
raw SQL operation beside others. pgroll runs it in one transaction, so the migration lands whole or
not at all. It opens with `SET CONSTRAINTS ALL IMMEDIATE`: an app's deferred constraint trigger would
otherwise leave events pending after rows move, and Postgres refuses to alter a table that has pending
events. Its changes run in three phases, whatever order the columns come in:
1. **Relax:** constraints, triggers and indexes dropped, `NOT NULL` lifted, defaults moved.
2. **Move rows:** backfills and carries. No row is moved against a rule the same migration drops.
3. **Tighten:** `SET NOT NULL`, uniques, references and indexes built.

**A carry, a backfill or a copy is a `DO` block.** It runs only where a row needs moving: one holding
a value gone, a `NULL` in a column made required, or a value of a column added that differs from its
copy (so a fresh database, and one copied already, run nothing). A copy runs once on a live database,
before the release serves, so every row it finds is one the table held; a machine's column is copied
with its trigger off, as a copy is no transition. A copy into a required column must give every
row a value (`coalesce(placed, 'epoch')`, say): one `NULL` fails the migration whole. Seed rows meet it
too. A carry turns off only the triggers that exist when it
runs. Postgres checks every check on a row it updates, even one `NOT VALID`, and the replay restates
every check `NOT VALID`. So a row written before a check was restated, on any of its columns, would
stop the move. The block lifts every check on the table around the update and puts each back as the
database held it, `NOT VALID`:
- a carry also lifts its own column's check, since a database that skipped releases already holds the
  newest check from the replay, and an earlier carry's destination (one a later migration carries on)
  is outside it;
- a backfill keeps its own column's check, since the value it fills is the model's, which that check
  admits.

**On a fresh database**, initdb builds the latest model, and then every migration runs in order:
- each relaxes what initdb already relaxed;
- each carries no row, because none holds a value gone;
- each tightens to the model of its time.

So a property that a later migration changes again ends as the latest model has it. One thing would
not: a name a migration dropped that the replay builds again. make refuses that until the migration
is folded.

initdb also loads the app's seed rows (and a preview's fixture rows) before the migrations run. Those
rows must satisfy every migration not yet folded:
- a value an old migration carries away, but which the model admits again, is carried again in them;
- a unique an old migration added, and a later model dropped, is built over them.

Folding old migrations keeps this short.

This is how the plugin keeps pronto's rule that the two paths, initdb and the ledger, do not claim the
same thing: initdb and the replay add, and a migration only alters what an earlier model left.

## Limits

- **The target must replay the emitted schema.** Additions are the replay's. A database carried only
  by its ledger would need the additions as migrations too, and pronto's emitter, not this plugin,
  writes a table's policies, grants and publication.
- **k8s does not replay `010_machines.sql`.** On k8s, a machine's new states and trigger reach only a
  fresh database. A carry to the new states fails against the old check, and the old chart may refuse
  a move out of a removed state. Closing that is k8s's job, as gcp does.
- **The window between the replay and the ledger is the migrate step's.** During it, a retired column
  is still `NOT NULL` while the replayed functions already stop writing it.
- **`check-inputs.json` and `005`'s clauses are pronto's own files.** Their shape is not a published
  contract. `model()` is the one place that reads them, and it refuses a version, a shape or a type
  clause it does not know. The way to make the proto the whole contract upstream is a custom option
  on each field, `[(pronto.column) = {required, default, check}]`; this plugin would then read
  nothing else.
- **Seed and fixture rows meet every migration not yet folded** (see "How it runs").
- **Drift that was already there when `init --from` ran is not seen.** For example, a column retired
  before then that a live database still holds `NOT NULL`. The snapshot starts from the model, not
  from the database.
- **Some things are left as they are:**
  - no constraint is validated: a check stays `NOT VALID` as the replay leaves it, and a reference is
    added `NOT VALID`;
  - no index is built `CONCURRENTLY`;
  - a name longer than Postgres's 63 bytes is not matched.

## The snapshot's format

The snapshot records the model this plugin reads, so a plugin that reads more (format 2 records the
default `005` writes for a machine's column) changes it. `check`, `plan` and `make` refuse a snapshot
of an older format, naming `upgrade`; one of a newer format is refused as a plugin too old. `upgrade`
reads the model at the commit that last wrote the snapshot (or `--from <ref>`, the commit it was
taken at), carries the old snapshot forward with what each later format records, and writes it only
if that is the model at the commit exactly. Then it sums it again.

## Tests

- [`tests.cue`](tests.cue): what the host writes, checked with `cue vet`.
- [`../tests/unit/migrations.cue`](../tests/unit/migrations.cue): the rules (the `migrations`
  suite). It covers:
  - the proto reader;
  - the model, and its refusal of an app not generated or a pronto it does not read;
  - every change and its SQL;
  - the phases;
  - the carries and their refusals;
  - the names a migration dropped;
  - the copy into a column added, the note on a volatile default, and a declaration no change reads;
  - a kind with no rule, and each op's names against what `droppedBy` reads;
  - the migration, its name and the strays, the sum with a fold, the snapshot's format and its
    upgrade.
- [`test.nu`](test.nu): the installer and the driver in a fresh example app:
  - `init`, then a lint that refuses a moved model;
  - a `make` that names the carry it needs, then writes one operation;
  - the program reading the migration;
  - a hand edit, refused;
  - an index rebuilt over a migration that dropped it, refused until `fold`, and the declaration
    left from the last migration, refused until removed;
  - a rename, refused;
  - two branches that each made a migration, merged: `rebase` remakes the side's after main's, and
    the ledger embeds both with nothing to settle;
  - a `.json` in `migrations/` that is no migration, refused;
  - `init --from` a git ref, taking the model the ref held.

```sh
./saytw --script tools.nu cue vet -c ./migrations
./saytw --script tools.nu cue vet -c -t package=check ./migrations/export
deno test --no-config --allow-read --allow-write --allow-env --allow-run --allow-net tests/unit.ts -- migrations
./saytw --script tools.nu nu migrations/test.nu
```

CI has neither Postgres nor pgroll, so the database runs below were done by hand.

## Measured (2026-11-09)

**pgroll 0.16.3 on Postgres 18.** The migration's runner, `pgroll start --complete` after an
`00_initdb` baseline, as mecha's migrate step calls it.

| Case | Result |
| --- | --- |
| two raw SQL operations in one migration | refused by pgroll: `operation "sql" cannot be executed with other operations` |
| the plugin's migration, three changes in one operation after `SET CONSTRAINTS ALL IMMEDIATE` (a column retired, its unique index dropped, a state carried), on a database with rows | applied and in the ledger: the rows carried, the column nullable, the index gone, an insert without the column accepted |
| a migration that backfills a column and then tightens its table, which has a deferred constraint trigger (checked by the review) | without `SET CONSTRAINTS ALL IMMEDIATE`, refused for pending trigger events and rolled back; with it, applied |
| the same migration on a database initdb built at the new model | applied, nothing changed |

**A production pronto app on the gcp target** (51 tables, 624 live columns, 9 retired). The plugin
was installed in a copy, and its snapshot was taken with `init --from` at the release its database
runs.

| Step | Result |
| --- | --- |
| `make`, against that release | 5 changes, all the replay's (two entities, three enums widened): no migration, which is right |
| the same, with a pending change that moves a machine column to new states (11 old values) | make names `carry.<Entity>.status` and writes nothing. With the carry declared, it writes one operation: the update, inside a `DO` block, with the trigger of the other machine column it fills turned off |
| `cue export . -e code.state.migrations` | the migration, typed by pgroll's grammar. A field pgroll does not know fails the program |
| the operation, on Postgres 18, against rows in all 11 old states | every row in a state of the new chart, the trigger on again, and a second run changing nothing. The machine still refuses a move its chart does not allow |
| `check`, then `make` | well under a second; about 3.5 s, most of it `cue export` of the program to read the declarations |
