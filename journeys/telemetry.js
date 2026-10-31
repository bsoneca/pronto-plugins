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
// by "-", else "form". Nothing a reader typed, no row and no error message
// leaves the page.

const ENDPOINT = "__ENDPOINT__";
const READER = ["click", "dblclick", "change", "submit", "keydown", "drop"];
// How long a gesture waits for the state its outcome is read from, and how
// long after an ok a withdrawal still belongs to it.
const SETTLE_MS = 10000;
const HANDLER_MS = 1500;
const LATE_MS = 5000;
const BATCH = 20;
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
// class alone.
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
	addEventListener("error", (e) => emit({ type: "error", kind: "error", name: nameOf(e.error) }));
	addEventListener("unhandledrejection", (e) => emit({ type: "error", kind: "rejection", name: nameOf(e.reason) }));
}

const formName = (form) => form.id || [form.dataset.action, form.dataset.entity].filter(Boolean).join("-") || "form";

export default function mount(screen, { signal }) {
	const name = screen.dataset.screen ?? location.pathname;
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
