# pronto-lessons

Guided lessons for any app (PRONTO-1454; design in pronto's `docs/designs/PRONTO-1454.md`). L1 is the course
schema and the step engine; L2 (below) is the database half and the emitter; the installer comes in L3.

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
- **The migration's name** `_lessonsMigration: "lessons_01"` in `lessons_spec.cue` is a default; L3's installer stamps the app's own, after its latest.

Cases: `tests/unit/lessons.cue` (suite `lessons`), the database on PGlite (`tests/unit/lessons_db.js`) over
`tests/unit/fixtures/lessons_course.cue`.
