// A small valid course, vetted with the schema: two parts of toy tokens, three locales.
package lessons

example: #Course & {
	id:   "toy_saga"
	flag: "toy_saga"
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
			en:      "Not that, try again (\(n))."
			"pt-BR": "Assim nao, tente de novo (\(n))."
			es:      "Eso no, intentalo otra vez (\(n))."
		}]
		chapters: [{
			id: "one"
			moves: ["a1", "b1", "a2", "b2", "a3"]
			shown: 0
			claim: "a3 ends it"
			intro: {en: "Begin with a1.", "pt-BR": "Comece com a1.", es: "Empieza con a1."}
			outro: {en: "Well done.", "pt-BR": "Muito bem.", es: "Muy bien."}
			steps: "2": {
				say: {en: "Now a2.", "pt-BR": "Agora a2.", es: "Ahora a2."}
				wrong: [{en: "Look at a2.", "pt-BR": "Olhe a2.", es: "Mira a2."}]
			}
		}]
	}, {
		id:      "second"
		teacher: "king"
		army:    "elves"
		side:    "b"
		player:  1
		reward:  15
		bonus:   30
		complaints: [for n in [1, 2, 3, 4, 5, 6, 7, 8, 9] {
			en:      "No (\(n))."
			"pt-BR": "Nao (\(n))."
			es:      "No (\(n))."
		}]
		chapters: [{
			id: "two"
			moves: ["a1", "b1", "a2", "b2"]
			shown: 1
			claim: "b2 ends it"
			intro: {en: "Defend.", "pt-BR": "Defenda.", es: "Defiende."}
			outro: {en: "Safe.", "pt-BR": "A salvo.", es: "A salvo."}
			steps: {}
		}]
	}]
}
