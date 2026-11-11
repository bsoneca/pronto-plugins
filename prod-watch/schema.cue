// What prod-watch (README.md) reads of an app besides its release.cue: the app's opt-in, the
// windows of an instance's life and the noise every app shares. A noise rule is a design fact,
// written once here or in the app's prodWatch, never in the script; the cases
// (tests/unit/noise.cue) hold each to the lines it is for and to the lines it must leave alone.
// bin/pronto-prod-watch writes it into the app's own package (prod_watch_plugin.cue), where the
// app's prod_watch.cue gives prodWatch its values.
package prodwatch

// An app opts in with `prodWatch: {...}` in its own package (prod_watch.cue): the release's
// service and its apart sidecars are watched with no more said.
prodWatch: #Watch

#Watch: {
	// The Google Cloud project whose Cloud Run logs are read: the release's (release.cue's GCP.project) by
	// default; an app whose release.cue has no GCP (it releases elsewhere) names it here.
	project?: string
	// Other Cloud Run services of the release's project this app answers for.
	services: [...string]
	// The app's own noise, beside the shared rules below, which every app gets.
	noise: [string]: #Noise
	// The lines that open an instance's windows: an entry of that instance from two seconds before one
	// (its containers hear SIGTERM at once and write in any order) to the seconds after is in the
	// window. A marker below a warning is read for this and reported never.
	lifecycle: [_]: {marker: string & !="", within: int & >0}
	lifecycle: {
		// "Starting new instance. Reason: ..." (AUTOSCALING, DEPLOYMENT_ROLLOUT, ...): a container may
		// call its neighbour before that one listens; a minute covers Electric's own start.
		start: {marker: *"^Starting new instance" | string, within: *60 | (int & >0)}
		// "Shutting down idle instance", or, when a rollout retires a revision, no word from Cloud Run but
		// SIGTERM to every container, which say so their own way (Electric, PostgREST) and stop in any
		// order within Cloud Run's ten seconds; thirty covers a slow one.
		shutdown: {marker: *"^Shutting down .*instance|SIGTERM|^Container terminated on signal" | string, within: *30 | (int & >0)}
	}
}

#Noise: {
	// A regular expression (JavaScript, multiline) the entry's message meets, its timestamp and
	// colour codes off.
	match!: string & !=""
	// Anchored regular expressions on the Cloud Run service and the container, when the rule is
	// one's alone.
	service?:   string
	container?: string
	// Only in these windows of an instance (lifecycle, above), when what it says is what starting or
	// stopping looks like and the same line at any other time is a bug.
	during?: [...("start" | "shutdown")]
	// Why it is not a bug: what makes it, and why nothing is lost. Proved by a case.
	why!: string & !=""
}

// The noise every app shares, for what pronto's release runs beside every app
// (gcp/release.nu): Electric, the Cloud SQL proxy, the Managed Prometheus collector of an apart
// sidecar. An app's own rules join these in prodWatch.noise.
prodWatch: noise: {
	"scale-down": {
		match: "^Container terminated on signal (2|15)\\.$"
		why:   "Cloud Run stops an idle instance with SIGTERM (then SIGINT/SIGKILL): every container of it says so, once"
	}
	"erlang-sctp": {
		match:     "^\\[UNIX-ESSIO\\] Failed open sctp dynamic library"
		container: "electric"
		why:       "the Erlang VM probes for libsctp at boot; Electric never opens an SCTP socket, so the missing library costs nothing"
	}
	"electric-not-ready": {
		match:     "Electric\\.StatusMonitor condition failed"
		container: "electric"
		during: ["start", "shutdown"]
		why: "Electric's status monitor names each readiness condition not yet met while it starts (it waits for the replication lock the instance before it holds) and each no longer met as it stops on SIGTERM"
	}
	"cloud-sql-proxy-stopping": {
		match:     "proxy server error: accept tcp .*: use of closed network connection"
		container: "cloud-sql-proxy"
		during: ["start", "shutdown"]
		why: "the proxy closes its listener on SIGTERM and its accept loop reports the closed socket it was blocked on"
	}
	"neighbour-away": {
		match: "(error sending request|tcp connect error).*Connection refused"
		during: ["start", "shutdown"]
		why: "a container calling its neighbour (PostgREST, flagd) before that one listens or after it stopped on SIGTERM: every such caller (billing's grants, the analyst's queue) polls again, on this instance or the next"
	}
	"gmp-start-time": {
		match:     "Couldn't get start time for metrics\\. Using fallback start time\\."
		container: "gmp-collector"
		why:       "the OpenTelemetry Prometheus receiver warns at each scrape of a counter its target exposes with no _created/start time, and uses the scrape's own: the counters are still exported"
	}
	"gmp-discovery-cancelled": {
		match:     "Discovery manager failed.*\"error\": \"context canceled\""
		container: "gmp-collector"
		why:       "the receiver's discovery stops with its context when the collector stops or reloads: a cancellation, not a failure"
	}
}
