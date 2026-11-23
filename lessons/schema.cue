// pronto-lessons: guided lessons for any app (PRONTO-1454, design docs/designs/PRONTO-1454.md in pronto).
// A course is parts, a part is chapters, a chapter is a script of opaque move tokens the app's board adapter
// understands (lessons/README.md). Every line a player reads is a #Line: closed over the course's locales, so a
// missing or an extra translation fails `cue vet`.
package lessons

import (
	"list"
	"strconv"
)

#Course: {
	id:   =~"^[a-z][a-z0-9_]*$"
	flag: =~"^[a-z][a-z0-9_]*$"
	// The languages every line carries, exactly.
	locales: [=~"^[a-z]{2}(-[A-Z]{2})?$", ...=~"^[a-z]{2}(-[A-Z]{2})?$"]
	hint: price: int & >=0
	parts: [#Part, ...#Part]

	// One line of speech: one non-empty text per locale of the course, no more and no fewer.
	#Line: {for l in locales {(l): string & !=""}}

	// A chapter id is unique within the course, whichever part holds it.
	_uniqueChapters: [for p in parts for c in p.chapters {c.id}] & list.UniqueItems()

	#Part: {
		id:      =~"^[a-z][a-z0-9_]*$"
		teacher: string
		army:    string
		side:    string
		// Which plies the player moves: 0 the even plies (0, 2, ...), 1 the odd ones.
		player: 0 | 1
		reward: int & >=0
		bonus:  int & >=0
		// The teacher's complaints for a wrong move: a pool no line of which repeats until all were said.
		complaints: [#Line, #Line, #Line, #Line, #Line, #Line, #Line, #Line, ...#Line]
		chapters: [#Chapter, ...#Chapter]

		// No two complaints say the same in any locale: a repeated text is a repeated line.
		_distinctComplaints: {for l in locales {(l): [for c in complaints {c[l]}] & list.UniqueItems()}}

		#Chapter: {
			id: =~"^[a-z][a-z0-9_]*$"
			// Opaque tokens, one per ply; only the app's adapter reads them.
			moves: [string, ...string]
			// How many leading plies play by themselves; the player has a ply at or after it.
			shown: int & >=0 & <len(moves)
			_hasPlayerPly: true & (len([for p in list.Range(shown, len(moves), 1) if p mod 2 == player {p}]) > 0)
			// What the end of the script must be, in the app's words (opaque here).
			claim: string
			intro: #Line
			outro: #Line
			// By ply (index into moves, no leading zero): `say` after the player's right move, `wrong` lines for a
			// wrong one, used in order. A key is a ply the player moves, from `shown` on.
			steps: [=~"^(0|[1-9][0-9]*)$"]: {
				say?: #Line
				wrong?: [...#Line]
			}
			_stepKeys: {for k, _ in steps {
				(k): true & (strconv.Atoi(k) >= shown) & (strconv.Atoi(k) < len(moves)) & (strconv.Atoi(k) mod 2 == player)
			}}
		}
	}

}
