// pronto-journeys' telemetry: a host-DOM hatch on every screen that reports
// what a reader did and what the terminal made of it, for the journeys
// collector to assemble into runs. Written by pronto-journeys; regenerated, do
// not edit.
//
// The terminal (omnishell 0.12.1) reports nothing itself, so this reads what it
// already shows: the screen's data-state, which it moves through form-submit,
// success, validation-error and network-error, and the events a reader makes
// on elements the markup binds. A gesture's outcome is the state that follows
// it; a handler that leaves the screen out of network-error is ok.
//
// Names follow the markup as journeys_gestures.cue derives them: a data-on-*
// handler by its module, a form by its id, else its action and entity joined
// by "-", else "form". Nothing a reader typed and no row leaves the page; an error
// leaves as its name alone and, only while the app's error-detail flag is on
// (globalThis.__prontoErrorDetail, set by pronto-errors), also a redacted message, its
// top script frames, a browser tag and the screen it happened on, which the collector
// redacts again and writes as a log line (prod-watch).

const ENDPOINT = "__ENDPOINT__";
const READER = ["click", "dblclick", "change", "submit", "keydown", "drop"];
// How long a gesture waits for the state its outcome is read from, and how
// long after an ok a withdrawal still belongs to it.
const SETTLE_MS = 10000;
const HANDLER_MS = 1500;
const LATE_MS = 5000;
const BATCH = 20;
// An error's text and frame are cut to this; a page reports this many errors in all.
const ERROR_TEXT = 200;
// The frames of an error's stack that leave the page, and their total length.
const STACK_FRAMES = 5;
const STACK_TEXT = 600;
const ERRORS_PER_PAGE = 10;
// The terminal moves between screens without unloading the page, so pagehide
// may not come for a long while: a batch also goes this long after its first
// event, which is what keeps a dashboard live.
const FLUSH_MS = 2000;

const hex = (bytes) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");

// One per tab, kept where the tab keeps it; a fresh one where storage is refused.
const session = (() => {
	const key = "pronto-journeys.session";
	try {
		const kept = sessionStorage.getItem(key);
		if (kept) return kept;
		const minted = hex(16);
		sessionStorage.setItem(key, minted);
		return minted;
	} catch {
		return hex(16);
	}
})();

// The screen mounted last, which an error is reported on.
let current = "";
let queue = [];
let timer;
const flush = () => {
	clearTimeout(timer);
	timer = undefined;
	if (queue.length === 0) return;
	const body = JSON.stringify(queue);
	queue = [];
	try {
		// A string, not a Blob: a Blob's body can be dropped when the document
		// reloads mid-send, a string's length is fixed when the beacon is queued.
		// It arrives as text/plain, which the collector reads as bytes alike.
		if (navigator.sendBeacon?.(ENDPOINT, body)) return;
		fetch(ENDPOINT, { method: "POST", body, keepalive: true, headers: { "content-type": "application/json" } }).catch(() => {});
	} catch {
		// Reporting never breaks what it reports on.
	}
};
const emit = (event) => {
	queue.push({ t: Date.now(), session, ...event });
	if (queue.length >= BATCH) flush();
	else timer ??= setTimeout(flush, FLUSH_MS);
};

// Every mounted screen's way to end its gestures still waiting: a page that goes
// away runs no cleanup, and a reader leaving before the state says otherwise is
// how most gestures end.
const unsettled = new Set();
// What the page holds when it goes is also kept for the tab's next load: a
// beacon sent while the document is torn down — a reload of the same address,
// above all — can be dropped on the way. A batch that did arrive is sent again
// and the collector drops the repeat by its traces.
const UNSENT = "pronto-journeys.unsent";
const leave = () => {
	for (const end of unsettled) end();
	if (queue.length > 0) {
		try {
			const kept = JSON.parse(sessionStorage.getItem(UNSENT) ?? "[]");
			sessionStorage.setItem(UNSENT, JSON.stringify([...kept, ...queue]));
		} catch {
			// Storage refused: the beacon below is all there is.
		}
	}
	flush();
};

// Once per page, not per screen: what the last page kept goes first, the last
// batch goes when the page does, and a throw nobody caught is reported by its
// name alone, or with its detail while the error-detail flag is on.
if (!globalThis.__prontoJourneys) {
	globalThis.__prontoJourneys = true;
	try {
		const kept = JSON.parse(sessionStorage.getItem(UNSENT) ?? "[]");
		sessionStorage.removeItem(UNSENT);
		if (kept.length > 0) {
			queue.push(...kept);
			flush();
		}
	} catch {
		// Nothing kept, or nowhere to keep it.
	}
	addEventListener("pagehide", leave);
	document.addEventListener("visibilitychange", () => {
		if (document.visibilityState === "hidden") flush();
	});
	const nameOf = (x) => (x instanceof Error ? x.name : typeof x);
	// An error's detail is sent only while its own flag answers true (pronto-errors asks it, from the app's
	// detailFlag, and sets globalThis.__prontoErrorDetail); pending, off, or with no errors reporter, the
	// event is the name alone, every time, exactly as it was.
	const detailOn = () => globalThis.__prontoErrorDetail === true;
	// What the collector would redact, done here too so none of it is sent: urls, emails, tokens and long
	// digit runs, then the whole message dropped if it names a chess position or a move (a saved game's
	// text must never leave the page).
	const FEN = /(?:[pnbrqkPNBRQK1-8]+\/){3,}[pnbrqkPNBRQK1-8]+/;
	const MOVE = /\b(?:[a-h][1-8]){2}[qrbn]?\b|\b[KQRBN][a-h]?[1-8]?x?[a-h][1-8]\b|\b[a-h]x?[a-h]?[1-8]\b|\bO-O(?:-O)?\b/;
	const scrub = (text) =>
		String(text ?? "")
			.replace(/https?:\/\/\S*/gi, "<url>")
			.replace(/(\/[\w.~%-]*)[?#]\S*/g, "$1")
			.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g, "<email>")
			.replace(/(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_.-]*/g, "$1<token>")
			.replace(/[A-Za-z0-9_+/=-]{24,}/g, "<token>")
			.replace(/\d[\d.\-/ ]{6,}\d/g, "<number>");
	// A path is scrubbed a segment at a time, each as it reads once decoded (ana%40gmail.com is an address): a
	// segment that holds something is replaced by its scrubbed form, any other is kept as written, so a long
	// legitimate path (/shell/hatches/journeys/telemetry.js) is not taken for a token.
	const scrubPath = (path) =>
		path
			.split("/")
			.map((segment) => {
				// The file's ending stays on whatever replaces its name, so a frame still ends in a script.
				const ending = segment.match(/\.m?js$/)?.[0] ?? "";
				// Decoded until it stops changing (ana%2540gmail.com is an address too), at most three times. A
				// malformed escape ("%E0%A4%A") hides whatever else the segment holds, an encoded address included,
				// and so does an escape left after three: such a segment is a fixed marker, never as written.
				let read = segment;
				for (let i = 0; i < 3; i++) {
					let next;
					try {
						next = decodeURIComponent(read);
					} catch {
						return `<undecodable>${ending}`;
					}
					if (next === read) break;
					read = next;
				}
				if (/%[0-9A-Fa-f]{2}/.test(read)) return `<undecodable>${ending}`;
				const clean = scrub(read);
				if (clean === read) return segment;
				// What goes out is escaped again, so a decoded newline or ")" cannot reshape the frame or the stack.
				// encodeURIComponent throws on a lone surrogate: that segment is the marker too, never a lost beacon.
				let out;
				try {
					// toWellFormed turns an unpaired surrogate into U+FFFD (older engines lack it: the catch holds); the u flag
					// keeps an emoji whole, so a valid Unicode name is escaped, not discarded.
					out = (clean.toWellFormed?.() ?? clean).replace(/[^\w.~<>-]/gu, encodeURIComponent);
				} catch {
					return `<undecodable>${ending}`;
				}
				return ending && !out.endsWith(ending) ? out + ending : out;
			})
			.join("/");
	const clean = (text) => (FEN.test(text) || MOVE.test(text) ? "" : scrub(text).slice(0, ERROR_TEXT));
	const messageOf = (x) => clean(x instanceof Error ? x.message : typeof x === "string" ? x : "");
	// A frame is rebuilt from fields a strict shape validated, never copied: Chrome's "at fn (url:1:2)" or
	// Gecko's and Safari's "fn@url:1:2", where url is a script (.js or .mjs) on http(s) or a path, with its
	// origin, query and fragment left out (a ")" or ":" in them is no end of it: the line and column are read
	// from the end). Any other line, an exception's name and message above all, is dropped. The stack's
	// first lines are the message's, so they are cut off before the lines are read, too.
	const CHROME = /^at (?:async )?(?:((?:new )?[\w$.<>[\]]+(?: \[as [\w$]+\])?) \()?((?:https?:\/\/[^\s()?#]+|\/[^\s()?#]*)\.m?js)(?:[?#]\S*?)?:(\d+):(\d+)\)?$/;
	const GECKO = /^([\w$.<>/-]*)@((?:https?:\/\/[^\s?#]+|\/[^\s?#]*)\.m?js)(?:[?#]\S*?)?:(\d+):(\d+)$/;
	const framesOf = (x) => {
		if (!(x instanceof Error) || typeof x.stack !== "string") return [];
		const head = `${x.name}: ${x.message}`;
		const body = x.stack.startsWith(head) ? x.stack.slice(head.length) : x.stack;
		const out = [];
		for (const line of body.split("\n")) {
			const l = line.trim();
			const c = CHROME.exec(l);
			const g = c ? null : GECKO.exec(l);
			const m = c ?? g;
			if (!m) continue;
			// The path is scrubbed too: a valid script path can hold an address or a token (/users/ana@x.com/app.js).
			const path = scrubPath(m[2].replace(/^https?:\/\/[^/]*/, ""));
			out.push((c ? `${m[1] ? `${m[1]} (` : ""}${path}:${m[3]}:${m[4]}${m[1] ? ")" : ""}` : `${m[1]}@${path}:${m[3]}:${m[4]}`).slice(0, ERROR_TEXT));
			if (out.length === STACK_FRAMES) break;
		}
		return out;
	};
	// The first frame.
	const frameOf = (x) => framesOf(x)[0] ?? "";
	const stackOf = (x) => framesOf(x).join("\n").slice(0, STACK_TEXT);
	// The browser the page runs in, as a tag from a fixed list, never the user agent itself: an
	// in-app browser (Instagram, Facebook's FBAN/FBAV) or a WebView ("wv"), else "other".
	const browserOf = () => {
		const ua = String(navigator.userAgent ?? "");
		return /Instagram/i.test(ua) ? "instagram" : /FBAN|FBAV/.test(ua) ? "facebook" : /; wv\)|\bwv\b/.test(ua) ? "wv" : "other";
	};
	// While the detail is on a page reports a few errors, each once: a loop in a tab is no flood of beacons.
	const reported = new Set();
	const report = (kind, thrown, fallback) => {
		if (!detailOn()) {
			emit({ type: "error", kind, name: nameOf(thrown) });
			return;
		}
		const event = { type: "error", kind, name: nameOf(thrown), message: messageOf(thrown) || clean(fallback), frame: frameOf(thrown), stack: stackOf(thrown), browser: browserOf(), screen: current };
		const key = `${event.name} ${event.message} ${event.frame}`;
		if (reported.has(key) || reported.size >= ERRORS_PER_PAGE) return;
		reported.add(key);
		emit(event);
	};
	addEventListener("error", (e) => report("error", e.error, e.message));
	addEventListener("unhandledrejection", (e) => report("rejection", e.reason));
}

// A form by its id, else the name its data-gesture gives it (forms of one action and entity on a
// screen, or repeated in a list, told apart), else its action and entity.
// The outcomes a hatch may report, the reporter's own.
const OUTCOMES = new Set(["ok", "failed", "refused", "invalid"]);

const formName = (form) => form.id || form.dataset.gesture || [form.dataset.action, form.dataset.entity].filter(Boolean).join("-") || "form";

export default function mount(screen, { signal }) {
	const name = screen.dataset.screen ?? location.pathname;
	current = name;
	emit({ type: "screen", screen: name, state: screen.dataset.state });

	// The gestures waiting on the state that says how they went.
	let pending = [];
	const settle = (gesture, outcome) => {
		clearTimeout(gesture.timer);
		pending = pending.filter((g) => g !== gesture);
		const ms = Math.round(performance.now() - gesture.start);
		emit({ type: "gesture", screen: name, gesture: gesture.name, kind: gesture.kind, outcome, ...(gesture.timed ? { ms } : {}), trace: gesture.trace });
		if (outcome === "ok" && gesture.kind === "form") {
			gesture.lateUntil = performance.now() + LATE_MS;
			settledForms.push(gesture);
		}
	};
	let settledForms = [];

	const begin = (gestureName, kind, wait, otherwise) => {
		const gesture = { name: gestureName, kind, start: performance.now(), trace: `00-${hex(16)}-${hex(8)}-01`, timed: kind === "form" };
		gesture.timer = setTimeout(() => settle(gesture, otherwise), wait);
		pending.push(gesture);
		return gesture;
	};

	let state = screen.dataset.state;
	const observer = new MutationObserver(() => {
		const from = state;
		const to = screen.dataset.state;
		// The terminal writes the state again on each failure: a second failure
		// on a screen already in network-error is no change, but is an outcome.
		if (to !== from) emit({ type: "state", screen: name, from, to });
		state = to;
		for (const g of [...pending]) {
			if (g.kind === "form" && to === "success") settle(g, "ok");
			// A reader's own invalid input settled at submit, before the terminal
			// moved: what reaches validation-error now is the server's no.
			else if (to === "validation-error") settle(g, "refused");
			else if (to === "network-error") settle(g, "failed");
		}
		// A write withdrawn after its form said ok: a refusal on that trace.
		if (to === "validation-error" || to === "network-error") {
			const now = performance.now();
			settledForms = settledForms.filter((g) => g.lateUntil > now);
			for (const g of settledForms.splice(0)) {
				emit({ type: "refusal", screen: name, gesture: g.name, outcome: to === "validation-error" ? "refused" : "failed", trace: g.trace });
			}
		}
	});
	observer.observe(screen, { attributes: true, attributeFilter: ["data-state"] });

	const onEvent = (e) => {
		if (e.type === "submit") {
			const form = e.target.closest?.("form");
			if (!form || !screen.contains(form)) return;
			const gesture = begin(formName(form), "form", SETTLE_MS, "ok");
			// The terminal checks the form's own constraints first: a reader's
			// invalid input is no failure of the app's.
			if (typeof form.checkValidity === "function" && !form.checkValidity()) settle(gesture, "invalid");
			// A navigation is its own effect and its own feedback.
			else if (form.dataset.action === "navigate") settle(gesture, "ok");
			return;
		}
		const bound = e.target.closest?.(`[data-on-${e.type}]`);
		if (!bound || !screen.contains(bound)) return;
		// Ok unless the screen fails within the window the reduce has to fail in.
		begin(bound.getAttribute(`data-on-${e.type}`), "handler", HANDLER_MS, "ok");
	};
	for (const type of READER) screen.addEventListener(type, onEvent, { capture: true, signal });
	// A gesture a hatch carries out itself, which the terminal never sees as a submit (a form the
	// hatch holds while it calls a service, a token it hands over by fetch): the hatch reports it
	// whole, as a "journeys:gesture" event on the screen, detail {gesture, outcome, ms?}, and the
	// app's journeys_spec.cue declares its name (`reported`). A hatch on an app without this
	// reporter dispatches it to no one.
	screen.addEventListener("journeys:gesture", (e) => {
		const d = e.detail ?? {};
		if (typeof d.gesture !== "string" || !OUTCOMES.has(d.outcome)) return;
		const ms = Number.isFinite(d.ms) ? Math.round(d.ms) : undefined;
		emit({ type: "gesture", screen: name, gesture: d.gesture, kind: "hatch", outcome: d.outcome, ...(ms === undefined ? {} : { ms }), trace: `00-${hex(16)}-${hex(8)}-01` });
	}, { signal });
	// Leaving the screen with nothing gone wrong is how many gestures end.
	const end = () => {
		for (const g of [...pending]) settle(g, "ok");
	};
	unsettled.add(end);

	return () => {
		observer.disconnect();
		unsettled.delete(end);
		end();
		flush();
	};
}
