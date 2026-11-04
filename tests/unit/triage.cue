// A run's groups against the ledger of known fingerprints (../../prod-watch/watch.js triage and mark): what is
// new, what came back after its fix, what rises, and what a run leaves as it was.
package unit

// A group as a run makes it.
_g: {
	id:   string
	n:    *1 | int
	from: *"2026-11-02T10:00:00Z" | string
	to:   *"2026-11-02T10:30:00Z" | string
	rule: *null | string
	out: {fp: id, key: id, service: "bonk-chess", container: "analyst", title: "boom", frame: "", noise: rule, count: n, first: from, last: to, revisions: ["bonk-chess-00061-jrq"], samples: []}
}
// A ledger entry.
_l: {
	st:   string
	n:    *10 | int
	from: *"2026-11-01T00:00:00Z" | string
	to:   *"2026-11-02T09:00:00Z" | string
	extra: {...}
	out: {title: "boom", service: "bonk-chess", container: "analyst", frame: "", status: st, count: n, first: from, last: to} & extra
}
_now: "2026-11-02T10:30:00Z"

cases: {
	"a fingerprint never seen is new, and the ledger keeps it open with its count and times": {suite: "triage", steps: [
		{call: "watch.triage", args: [{a: (_g & {id: "a", n: 3}).out}, {}, _now]},
		{keep: "run"},
		{get: "report", holds: [{fp: "a", verdict: "new", status: "open"}]},
		{use: "run"},
		{get: "ledger.a", holds: {status: "open", count: 3, first: "2026-11-02T10:00:00Z", last: "2026-11-02T10:30:00Z"}},
	]}
	"a fixed one seen again after its fix regressed and is open again; seen only before it, it stays fixed": {suite: "triage", steps: [
		{call: "watch.triage", args: [{a: (_g & {id: "a"}).out, b: (_g & {id: "b", to: "2026-11-02T09:59:00Z"}).out}, {
			a: (_l & {st: "fixed", extra: {pr: 501, fixedAt: "2026-11-02T10:10:00Z"}}).out
			b: (_l & {st: "fixed", extra: {pr: 502, fixedAt: "2026-11-02T10:10:00Z"}}).out
		}, _now]},
		{keep: "run"},
		{get: "report", holds: [{fp: "a", verdict: "regressed", status: "open", pr: 501}, {fp: "b", verdict: "fixed", status: "fixed"}]},
		{use: "run"},
		{get: "ledger.a.reason", expect: "regressed after PR #501"},
	]}
	"an open one at more than twice its rate so far, five times at least, is rising; at its rate it is open": {suite: "triage", steps: [
		{call: "watch.triage", args: [{a: (_g & {id: "a", n: 20}).out, b: (_g & {id: "b", n: 1}).out}, {
			a: (_l & {st: "open", n: 33}).out
			b: (_l & {st: "watching", n: 33}).out
		}, _now]},
		{get: "report", holds: [{fp: "a", verdict: "rising"}, {fp: "b", verdict: "open", status: "watching"}], why: "33 in 33 hours is one an hour; 20 in half an hour is forty"},
	]}
	"noise by a rule or by the ledger is reported last, and a rule's noise is kept as noise with its name": {suite: "triage", steps: [
		{call: "watch.triage", args: [{a: (_g & {id: "a", rule: "erlang-sctp"}).out, b: (_g & {id: "b"}).out, c: (_g & {id: "c"}).out}, {
			b: (_l & {st: "noise", extra: {reason: "a bot's probes"}}).out
		}, _now]},
		{keep: "run"},
		{get: "report", holds: [{fp: "c", verdict: "new"}, {verdict: "noise"}, {verdict: "noise"}]},
		{use: "run"},
		{get: "ledger.a", holds: {status: "noise", reason: "rule erlang-sctp"}},
	]}
	"marked by hand: by a prefix of its fingerprint, noise only with why, fixed with when": {suite: "triage", steps: [
		{value: {abc123: (_l & {st: "open"}).out, def456: (_l & {st: "open"}).out}},
		{keep: "ledger"},
		{call: "watch.mark", args: ["$ledger", "abc", "fixed", {pr: 501, at: "2026-11-02T11:00:00Z"}]},
		{get: "abc123", holds: {status: "fixed", pr: 501, fixedAt: "2026-11-02T11:00:00Z"}},
		{call: "watch.mark", args: ["$ledger", "def", "noise"], throws: "noise says why"},
		{call: "watch.mark", args: ["$ledger", "zzz", "open"], throws: "no fingerprint zzz"},
		{call: "watch.mark", args: ["$ledger", "abc", "gone"], throws: "status gone"},
	]}
}
