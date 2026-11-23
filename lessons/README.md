# pronto-lessons

Guided lessons for any app (PRONTO-1454; design in pronto's `docs/designs/PRONTO-1454.md`). L1 is the course
schema and the step engine; L2 (below) is the database half and the emitter; L3 ("Installing") is the installer.

## Shape (`schema.cue`, package `lessons`)

`#Course{id, flag, locales, hint.price, parts}`, `#Part{id, teacher, army, side, player: 0|1, reward, bonus,
complaints (>= 8), chapters}`, `#Chapter{id, moves, shown, claim, intro, outro, steps}`. A move is an opaque string
token; `steps` is keyed by ply (`"2": {say, wrong}`). Every line is a `#Line`, closed over the course's `locales`: a
missing or extra translation fails `cue vet`. `example.cue` is a small valid course.

## Adapter contract (`app/lessons.js`)

The app supplies five functions over an opaque board:

- `start()` the board before any ply
- `legal(board, gesture)` may this gesture be tried
- `token(gesture)` the move's token, compared as a string
- `apply(board, token)` the board after the token (never mutates)
- `render(board)` draw it

## Loop

`createLesson({course, part, chapter, adapter, server})`: the first `shown` plies play by themselves, then the other
side's scripted replies until it is the player's turn. `play(gesture)` judges by token equality with the expected
token: right advances and plays the reply; wrong counts (`wrongs`, `step_wrongs`), returns the teacher's line and keeps
the board before the move (take-back). `pick` gives the line: the ply's own `wrong` lines in order, then
`pool[perm[(wrongs-1) mod N]]`, `perm` a Fisher-Yates shuffle seeded by FNV-1a of `course/chapter` per cycle, with the
boundary fixed so no line repeats before all N were said or twice in a row (algorithm in the code's comments).
`reconcile(serverState)`: when the server's step differs, its step and counters win.

## Cases

`tests/unit/lessons.cue` (suite `lessons`), on a toy adapter (`tests/unit/lessons_toy.js`):

    deno test --allow-read --allow-env --allow-run --allow-net --allow-write tests/unit.ts -- lessons
    cue vet -c ./lessons && cue fmt --check ./lessons

## L2: the database (PRONTO-1455)

Files (`lessons/app/`, copied into an app by L3, `__PACKAGE__` the app's): `lessons_spec.cue` (the app's `lessons: courses:`
and the migration's name, written once), `lessons_plugin.cue` (the `LessonProgress` entity, the plugin's migration, the
emitter's outputs), `lessons.sql` (the functions, a raw migration replayed at every release), `lessons.nu`
(`lessons write --sql <file> --js <file> [--messages messages]`). `schema.cue` sits in the app's package beside them.

- **Progress** is `public.lesson_progress`, one row `<account>/<course>/<chapter>`; a session reads its own and writes none
  (trigger `lesson_progress_read_only`: only the role that owns the table, the one the functions run as, may write it; no session role, no service role). The migration also makes the ledger `lessons.paid(owner, entry)`, one row an
  entry, in a schema no session reaches.
- **Functions** (`app_user` only, never `anon`; SECURITY DEFINER, `search_path` pinned; the account is `auth_uid()`, never an
  argument), each returning json `{course, chapter, part, step, wrongs, step_wrongs, pool_said, hinted, done, over}`:
  `lesson_start(course, chapter)`, `lesson_move(course, chapter, step, token)`, `lesson_hint(course, chapter, step)` (adds
  `token`). A move at a step other than the row's, or after the end, changes nothing and returns the row.
- **Refusals**, in this order: a guest (no account, or a `guest` claim that is anything but `false`) `42501 lessons: a guest has no lessons`; unknown course or chapter,
  a name over 64 characters `22023 lessons: no such chapter`; the course's flag off for the account `42501 lessons:
  unavailable`; the plan's price NULL or negative `42501 lessons: not for this plan`; `lesson_start` of a locked chapter
  (the one before in its part, or for a part's first, every chapter of the part before, not done) `23514 lessons: locked`;
  `lesson_move`/`lesson_hint` on a chapter never started `23514 lessons: not started`; a negative step or a token over 64
  characters `22023` (a step past the script, as after a shortened spec, returns the row unchanged). Finishing a part's
  chapters locks the account's rows of the part first, so the bonus is paid exactly once when two finishes race. Everything is read before anything is charged; the charge is last, in the call's transaction.
- **Entries**, once each through the ledger (a row goes in first, the hook is called only when it did): `lesson/<course>/<chapter>/open`
  (the tier's price, at a chapter's first start), `lesson/<course>/<chapter>/<step>` (a hint, the course's `hint.price`; bought
  for good, a replay included), `lesson/<course>/<chapter>/done` (the part's `reward`), `lesson/<course>/<part>/bonus` (the
  part's `bonus`, when its last chapter is done). An amount of 0 is recorded and calls nothing.
- **The app's hooks**, schema `lessons_app` (revoked from PUBLIC, never granted to a session): `price(who uuid) returns int`
  (NULL or negative: this tier may not open lessons), `pay(who uuid, entry text, amount int) returns void` (raises when the
  account is short; the raise rolls the whole call back), `reward(who uuid, entry text, amount int) returns int`. The plugin's
  migration creates stubs that raise `0A000 lessons: the app defines lessons_app.<name>` only where no hook exists, so the
  app's own are never replaced, whichever migration runs first. The app's hook migration is `DROP FUNCTION IF EXISTS` then
  `CREATE FUNCTION`, then `REVOKE ALL ... FROM PUBLIC` again (a CREATE gives PUBLIC its EXECUTE back), for each of the three.
- **Emitter**: `lessons write` writes `lessons.spec()` (a raw migration: tokens, plies, flag, prices, rewards; no words), the
  page's `courses` (every line a message key `lesson_<course>_ch_<chapter>_intro|_outro|_<ply>_say|_<ply>_wrong_<i>`,
  `lesson_<course>_part_<part>_complaint_<i>`) and those keys' lines in each `messages/<locale>.json`: every `lesson_<course>_*`
  entry dropped and written again as the file's last, the rest untouched. A course id that begins another's (`toy`,
  `toy_saga`) shares the dropping. Tokens may not contain `$spec$` or exceed 64 characters; course and chapter ids at most 60; rewards, bonuses and the hint price at most
  2147483647 (the hooks' `int`); no two message keys may be the same (`a` with a chapter `b_ch_c` and `a_ch_b` with `c` say one key: refused);
  a locale is `^[a-z]{2}(-[A-Z]{2})?$`. A catalogue must be laid out as JSON.stringify(_, null, 2) does (an empty `{}` is fine); any other
  layout is an error, never a second copy of an entry. `tests/unit/lessons_db.js`'s `rewrite` is a copy in JS of `lessons.nu`'s `catalogue`
  (nu is not what the unit cases run): change both together.
- **The migration's name** `_lessonsMigration: "lessons_01"` in `lessons_spec.cue` is a default; the installer stamps the app's own (L3).

Cases: `tests/unit/lessons.cue` (suite `lessons`), the database on PGlite (`tests/unit/lessons_db.js`) over
`tests/unit/fixtures/lessons_course.cue`.

## L3: Installing, and how an app opts in (PRONTO-1456)

```sh
<this repo>/bin/pronto-lessons <app-dir> [<module-path>] [--migration <name>]   # lessons/lessons.js unless named
./saytw generate && ./saytw lint
```

The app must already hold pronto-flags (`flags_plugin.cue`, from `bin/pronto-flags <app-dir>`): a course names a flag and the
database refuses a chapter whose flag is off for the account, so the installer refuses an app without it, naming
`bin/pronto-flags`, and writes nothing (every refusal comes before the first write). A re-run changes nothing. The module path
is a `.js`, `.mjs` or `.ts` inside the app and never another file the installer writes; a file already there that is not
pronto-lessons' (no header) is never overwritten.

| Path in the app | |
| --- | --- |
| `lessons/lessons.js`, or the path named | the page's step engine (`createLesson`), with a header naming the pronto-plugins commit it was generated from (`generated from bsoneca/pronto-plugins@<12 characters>`); regenerated |
| `lessons_spec.js` beside it | the page's courses; a stub `export const courses = {}` at install (written once), then generate's |
| `lessons_plugin.cue`, `lessons_schema.cue` | the `LessonProgress` entity, the plugin's pgroll migration, the emitter's outputs and the raw migrations' list; `schema.cue` as the app's, package renamed; regenerated |
| `pronto/lessons.cue`, `lessons/lessons.nu` | the generate step: `lessons write` writes `lessons/lessons_spec.sql`, `lessons_spec.js` and the lines in `messages/<locale>.json` |
| `lessons/lessons.sql` | the functions (L2's `lessons.sql`); regenerated; both SQL files start with `SET lock_timeout = '5s'; SET statement_timeout = '30s';`, which pronto's `lint sql` requires of every replayed file |
| `lessons/lessons_spec.sql` | `lessons.spec()`, written by generate from the courses; written once at install for no courses (the same text the emitter makes of `courses: {}`), so the first `./saytw generate` finds the raw migration pronto's step reads before the lessons step has run |
| `lessons_spec.cue` | written once, then the app's: `lessons: courses: {}`, `_lessonsMigration` and `_lessonsRawNames` |

Nothing goes into `services/database/migrations/`: that folder is pronto generate's output. The two SQL files are **raw
migrations the app declares**, `code: state: rawMigrations: [{name: <spec>, src: "lessons/lessons_spec.sql"}, {name: <fns>, src:
"lessons/lessons.sql"}]`, which the release replays and the Dockerfiles copy. `lessons_plugin.cue` sets that field itself when no
other CUE of the app does; two lists of one field cannot be unified, so an app that already lists its own `rawMigrations` adds
`_lessonsRawMigrations` to that list (`list.Concat([[...its own], _lessonsRawMigrations])`), and the installer says so until it does.

**The names** are stamped once into `lessons_spec.cue` and reused verbatim by every re-run, whatever the app adds later: the raw
ones `<n>_lessons_spec.sql` and `<n+1>_lessons.sql`, n one more than the highest `name: "NNN_x.sql"` the app's CUE lists (pronto's
`950_fixture.sql` aside), at that width (100 and 101 when it lists none). At three digits the numbers stay **below 800**, since pronto's
schema reserves every raw name starting with `8` (but `802_signals.sql`): the 8xx and 950 names are ignored, and the next two numbers
above the highest name below 800 are taken, or, when fewer than two remain there, the two highest free numbers below 800 (Bonk Chess,
whose highest is 799, gets 793 and 796); fewer than two free numbers is refused, naming them in `lessons_spec.cue` by hand; the pgroll migration `<m>_lessons`, m one more than the
highest of the app's own pgroll names (`_xMigration: "NN_x"`, `migrations: "NN_x"`) at that width, a sequence of its own. When the
app names no pgroll migration, `--migration <name>` gives it; a number that would need more digits than the width is refused.

### How an app opts in

1. Has pronto-flags, then adds the plugin with `bin/pronto-lessons <app-dir>` (and lists the raw migrations if it has its own list).
2. Supplies the content: its courses in `lessons_spec.cue` (`lessons: courses: <id>: {...}`, held to `#Course`, each naming its flag), and
   `./saytw generate`.
3. Writes the board adapter for its page, `{start, legal, token, apply, render}` (the contract above), and calls
   `createLesson({course, part, chapter, adapter, server})` with `courses` from `lessons_spec.js`.
4. Defines the three SQL hooks in a raw migration of its own, named after the plugin's two, in schema `lessons_app`:
   `price(who uuid) returns int`, `pay(who uuid, entry text, amount int) returns void`, `reward(who uuid, entry text, amount
   int) returns int`; each `DROP FUNCTION IF EXISTS` then `CREATE FUNCTION`, then `REVOKE ALL ... FROM PUBLIC` again (a CREATE gives
   PUBLIC its EXECUTE back).
5. Flips the course's flag with pronto-flags when it is to go live; the plugin changes nothing a player sees before.

Cases: `tests/unit/lessons.cue` (installer cases run `lessons/install.ts` on a temporary app, `tests/unit/lessons_install.js`).
