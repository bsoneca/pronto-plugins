package drill

// The drill's one flag: on, it breaks the checkout. Off by default everywhere; a flip is the
// "bad release" the probe is there to catch, and `pronto-flags rollback` the way back.
flags: {
	drill_break_checkout: {
		note:    "Makes /checkout answer 500: the fault the flag rollback drill injects and rolls back."
		default: false
	}
}

// The flags' live store is a local directory, not a bucket: flagd reads <dir>/flags.json and
// the versions of it stay in <dir>/versions/.
flagsLive: {dir: ".flags-live"}
