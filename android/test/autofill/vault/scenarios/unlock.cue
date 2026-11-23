package scenarios

// The biometric unlock (PRONTO-144) on an emulator whose fingerprint is enrolled
// (android/test/autofill/emulator.sh): the vault's one prompt opens the terminal on a touch, and a
// dismissed prompt leaves it shut. The prompt's outcome is the app's own log line (MainActivity.kt).
scenarios: {
	"one prompt opens the vault": {
		steps: [
			{open: "/", unlock: true, why: "the prompt shows, the sensor is touched once, the terminal boots"},
			{log: "PRONTO UNLOCK opened"},
			{log: {absent: "PRONTO UNLOCK canceled"}},
		]
	}

	"a canceled prompt keeps the vault shut": {
		steps: [
			{open: "/", unlock: "cancel", why: "the prompt is dismissed, not answered"},
			{log: "PRONTO UNLOCK canceled"},
			{log: {absent: "PRONTO UNLOCK opened"}, why: "the terminal never started: no key was opened"},
		]
	}
}
