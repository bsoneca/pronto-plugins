# pronto-lessons

Guided lessons for any app (PRONTO-1454; design in pronto's `docs/designs/PRONTO-1454.md`). This is L1: the course
schema and the step engine. SQL, the emitter and the installer come in L2 and L3.

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
