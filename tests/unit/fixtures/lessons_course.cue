// The course the lessons database cases run on (tests/unit/lessons_db.js): two parts of toy tokens, three locales,
// one token with a quote and a dollar sign in it. Copied with lessons/schema.cue and the plugin into a package.
package lessons

lessons: courses: toy: {
	flag: "toy"
	locales: ["en", "pt-BR", "es"]
	hint: price: 10
	parts: [{
		id:      "first"
		teacher: "sage"
		army:    "owls"
		side:    "a"
		player:  0
		reward:  15
		bonus:   30
		complaints: [for n in [1, 2, 3, 4, 5, 6, 7, 8] {
			en:      "Not that (\(n))."
			"pt-BR": "Assim nao (\(n))."
			es:      "Eso no (\(n))."
		}]
		chapters: [{
			id: "one"
			moves: ["a1", "b1", "a2", "b2", "a3"]
			shown: 0
			claim: "a3 ends it"
			intro: {en: "Begin.", "pt-BR": "Comece.", es: "Empieza."}
			outro: {en: "Well done.", "pt-BR": "Muito bem.", es: "Muy bien."}
			steps: "2": {
				say: {en: "Good, now the next.", "pt-BR": "Bom, agora a proxima.", es: "Bien, ahora la siguiente."}
				wrong: [{en: "Look again.", "pt-BR": "Olhe de novo.", es: "Mira otra vez."}]
			}
		}, {
			id: "one_b"
			moves: ["a1", "b1", "a2"]
			shown: 0
			claim: "a2 ends it"
			intro: {en: "Again.", "pt-BR": "De novo.", es: "Otra vez."}
			outro: {en: "Good.", "pt-BR": "Bom.", es: "Bien."}
			steps: {}
		}]
	}, {
		id:      "second"
		teacher: "king"
		army:    "elves"
		side:    "b"
		player:  1
		reward:  20
		bonus:   40
		complaints: [for n in [1, 2, 3, 4, 5, 6, 7, 8, 9] {
			en:      "No (\(n))."
			"pt-BR": "Nao (\(n))."
			es:      "No (\(n))."
		}]
		chapters: [{
			id: "two"
			moves: ["a1", "b'1$", "a2", "b2"]
			shown: 1
			claim: "b2 ends it"
			intro: {en: "Defend.", "pt-BR": "Defenda.", es: "Defiende."}
			outro: {en: "Safe.", "pt-BR": "A salvo.", es: "A salvo."}
			steps: {}
		}]
	}]
}
