package scenarios

// The terminal's autofill fills another app's login form (PRONTO-148), on an emulator whose
// fingerprint is enrolled (android/test/autofill/emulator.sh). The vault is the fixture beside this
// file; the asker (android/test/autofill/asker) is a native app with a username and a password
// field. The test values are made up for this scenario.
scenarios: {
	"fills a native app's login": {
		steps: [
			{open: "/", unlock: true, why: "the vault opens behind one fingerprint"},
			{fill: {in: "form.add input[name=title]", value: "Asker"}},
			{fill: {in: "form.add input[name=username]", value: "ana"}},
			{fill: {in: "form.add input[name=secret]", value: "correct-horse-1"}},
			{click: "form.add select[name=kind]"},
			{native: {text: "App", tap: true}, why: "the select's options are drawn in a popup of their own, not in the page"},
			{value: {of: "form.add select[name=kind]", is: "app"}},
			{fill: {in: "form.add input[name=target]", value: "dev.pronto.autofill.asker"}},
			{click: "form.add button[type=submit]"},
			{text: {of: ".logins li .target", is: "dev.pronto.autofill.asker"}, why: "the login is kept"},
			{text: {of: ".logins li .signer", is: ""}, why: "no certificate is known until an app is filled"},
			{autofillService: "dev.pronto.vault/.FillService"},
			{launch: "dev.pronto.autofill.asker/.LoginActivity"},
			{native: {id: "dev.pronto.autofill.asker:id/username", tap: true}},
			{native: {text: "Unlock Vault", tap: true}, why: "the service answers with one locked entry"},
			{finger: true, why: "the entry opens the vault behind its prompt"},
			{native: {text: "Asker · ana", tap: true}, why: "the handler picked the login"},
			{native: {id: "dev.pronto.autofill.asker:id/echo", is: "ana:correct-horse-1"}, why: "both native fields hold the stored values"},
			{open: "/", unlock: true, why: "back in the vault, from its store"},
			{text: {of: ".logins li .signer", matches: "^[0-9a-f]{64}$"}, why: "the fill pinned the login to the asker's signing certificate"},
		]
	}
}
