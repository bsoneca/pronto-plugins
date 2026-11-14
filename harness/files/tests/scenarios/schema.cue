// The online acceptance as data: scenarios of actors and steps, run against APP_URL by
// tests/scenarios.ts. Scenarios are independent, each with its own players and accounts, so they
// run side by side (`parallel` at most); a scenario's steps run in order. A step is one action or
// one expectation, waited for up to its timeout. Strings take `{name}`: an actor's `{ana.id}` (its
// account), `{ana.token}` (its session) and `{ana.name}`, a value a step kept, `{uuid}`, fresh each
// time, `{run}`, fresh each run of the scenario, `{past}`, a minute ago as a row's timestamp, or
// `{host}`, the host the run reaches the app at.
//
// Every pronto app's copy is the same (pronto-plugins' harness). What is the app's own it writes in a
// file of its own beside its scenarios (tests/scenarios/app.cue): the facts below where its default
// is not the app's, the fields its actors have besides these (`#Actor`), its own step kinds
// (`#Gestures`, done by tests/scenarios/app.ts) and those a production scenario may not take
// (`#barred`).
package scenarios

// How many scenarios run at once: at hand (a stack on this machine) the machine's cores are the
// limit; against a deployed preview (tests/scenarios.ts: a dotted host that is not this machine's)
// the machine that drives it is.
parallel:         int & >=1 | *4
deployedParallel: int & >=parallel | *parallel

// A flake under load (PRONTO-437): a scenario that failed beside others in a pass and passes when run
// again alone, after the pass, on the same head. The run still fails (a flake is a bug, never retried
// away); the runner says so ("⚠ <id> flaked under load") and files it once as a bug on the dev flow's
// board: `file`, the board's command at a pinned pronto-plugins commit, with the repository, then --app
// (`app`, the app's folder's name unless said), --bug, --priority, --title and --body appended. Filed
// once per scenario a week (a marker in ~/.cache/pronto/flakes); FLAKES_FILE=0 files nothing.
flakes: {
	app?:     string
	priority: "P0" | "P1" | *"P2" | "P3"
	file: [...string] | *["deno", "run", "-A", "https://raw.githubusercontent.com/bsoneca/pronto-plugins/17630bc5c541cca31f10921bf30c060a89fb210e/devflow/board.ts", "file"]
	// An app whose release run (release-cron's rehearsal, RETRY_FAILED, or a deployed preview) runs a failed
	// scenario again once, at once, and lets a pass on that retry through ("⚠ <id> flaked"): Bonk Chess's
	// and Prontoweeper's, as they were before the runner was shared. Off by default: a failure stays one.
	retry: bool | *false
}

// The screen an actor reads the app on: a viewport, or a device Playwright knows by name (its
// viewport, scale, touch and user agent: "Pixel 7").
#Screen: {viewport: {width: int & >0, height: int & >0}} | {device: string}
// Every actor's, unless it names one of `screens` (its `device`): a phone held upright.
screen: *{viewport: {width: 390, height: 844}} | #Screen
screens: [string]: #Screen
// The language its pages are read in, unless an actor says otherwise (its `locale`).
locale: string | *"en-US"
// The app's texts, by key, for a `text` step's `msg`: a file from the app's root. An app whose texts
// are not in one has none, and a `msg` then names nothing.
messages: string | *"messages/en.json"
// How a page is waited for once it loads (open, reload, revisit, a checkout's return), unless the app's
// tests/scenarios/app.ts waits its own way: the document's load, then the loader's script gone.
loaded: {
	// What the terminal draws once it has drawn the page's screen, waited for (two minutes): on a cold
	// door it comes well after the document's load.
	screen?: #Sel
	// The app's pages are served first and then taken over by the shell (omnishell drops a screen's
	// data-served then): a load waits for it, and so does every gesture, since a click on served
	// markup, which has no handlers yet, is lost.
	adopted: bool | *false
}
// The scenario selection (tests/scenarios/select.ts) in the local gate: the app's sources whose only
// effect on a scenario is the static assets it loads (`client`, path globs from the app's root), those
// that only build a generated file judged in its turn (`derived`, prefixes), files no scenario can see
// (`inert`, regular expressions) and files the app runs while a scenario does though the shared list
// calls them inert (`live`, regular expressions).
select: {
	client: [...string] | *[]
	derived: [...string] | *[]
	inert: [...string] | *[]
	live: [...string] | *[]
}
// The stack's database, for a `database` step (POSTGRES_DB, where set, wins).
database?: string
// The app's passkey sign-in, for a `signIn` step: what opens it (the first of them shown) and its
// passkey's button.
signIn?: {open: [...#Sel], passkey: #Sel}

scenarios: [Id=string]: #Scenario & {id: Id}

// A person: each in a browser of its own, a guest the terminal mints at boot, or an account once its
// steps sign it up. On the app's `screen`, or the one of its `screens` it names; in the app's
// `locale`, or its own.
#Actor: {name: string, device?: string, locale?: string}

#Scenario: {
	id: string
	// What it shows of acceptance.md.
	accepts: [...=~"^accept-[a-z0-9-]+$"]
	actors: [=~"^[a-z]+$"]: #Actor
	steps: [...#Step]
	// A race a slow page loses (a lobby's pairing, a sign-in's boot): a pull request's gate throttles the
	// pages of the scenarios marked so, as the release rehearsal throttles every scenario (tests/slow.ts).
	// Those that measure nothing about time run as fast as the machine allows.
	slow?: true
	// Needs a stack's stand-in (billing's for Stripe, whose portal ends a trial at a press; the model's,
	// replaying a recorded session): a deployed app has the real one, which has no such press or keys, so
	// the runner skips these there, as it does a scenario that signs in with Google (`google`), which only
	// the local broker's stand-in signs in.
	standin?: true
	// The pronto-flags flags (flags_spec.cue) it exercises: a flip of one runs its scenarios
	// (`pronto-flags push`). A step's own `flag` counts too.
	// Each must gate a step of its own (`flag`, or `unless` for the app as it is with the flag off):
	// a flag no step names changes nothing the scenario checks, and the steps that need it on would
	// fail wherever it is off.
	flags?: [...string]
	if flags != _|_ {
		_gated: {for f in flags {"\(f)": [for s in steps for k in ["flag", "unless"] if s[k] != _|_ if s[k] == f {s}]}}
		_gated: [string]: [_, ...]
	}
	// Safe to run on the deployed app: one actor at most, and nothing that writes what another person
	// could see or that spends (no step `#barred` names), only GET requests. A flip (pronto-flags push)
	// runs, once the flag is on for everyone, only those that sign in as no one (PRONTO-284: a flip has
	// no tester); those open no page (a page boots a guest, which the database keeps) and read only with
	// anonymous `http` steps, as a crawler. One that signs in (`signIn`, with FLAGS_TESTER_CREDENTIAL's
	// passkey) is listed by a flip and not run. The runner refuses any other scenario against
	// production (flags_spec.cue's flagsLive.url).
	production?: true
	if production != _|_ {
		_one: true & (len(actors) <= 1)
		_barred: [for s in steps for k, _ in #barred if s[k] != _|_ {k}]
		_barred: []
		_writes: [for s in steps if s.http != _|_ if s.http.method != "GET" {s}]
		_writes: []
		_signsIn: [for s in steps if s.signIn != _|_ {s}]
		if len(_signsIn) == 0 {
			_page: [for s in steps if s.http == _|_ {s}]
			_page: []
			_signed: [for s in steps if s.http != _|_ if s.http.anon != true {s}]
			_signed: []
		}
	}
}

// The step kinds a production scenario never takes: they write or spend. An app adds its own.
#barred: {signUp: true, pay: true, database: true}

// A selector, in Playwright's CSS dialect.
#Sel: string

#Step: {
	// Whose page the step acts on or reads; an http step's session too.
	by?: string
	// Waited for up to this many seconds (default 30).
	timeout?: number & >0
	// Why, when it is not plain from the step.
	why?: string
	// A flag (flags_spec.cue) the step needs on: where the door answers that it is off, the step
	// is skipped. A door whose flags do not answer is a failure, never a reason to skip.
	flag?: string
	// A flag whose absence the step needs: skipped where the door answers that it is on. The
	// app as it is with the flag off keeps its steps here, and a flag's flip runs them (`flags`).
	unless?: string
	// On an expectation about what another actor changed, which a page that reads from the server
	// shows only on its next load: the page is reloaded every few seconds until the expectation
	// holds or the step's timeout passes.
	fresh?: true
	// Only asked once a step has kept this variable (`keep`, to a value that exists): a check of what
	// a listing names runs once there is a listing, as in production before anyone has published.
	ifKept?: string
	// Asked only on the deployed app ("production") or only on a stack at hand ("local"): what a
	// listing may be differs, a laptop's naming the stack's own address.
	on?: "production" | "local"
	#Action | #Expect | #Http | #Together | #Any | #Repeat | #Gesture
}

#Action: {open: string} | // a path of the app or a URL, waited for as the app's pages load (`loaded`)
	{reload: true} |
	{revisit: string} | // the tab closed and the app opened again at this path in a new one: what the browser keeps (its storage, its cookies) stays, the tab's own session does not
	{leave: true} | // the page says it is being left (pagehide), as a closing tab does: what a page reports on leaving goes out
	{rush: {open: string, click: #Sel, heldBy?: string, holdPage?: string, drawn?: #Sel}} | // opened without waiting for the boot, and pressed at once: the press lands on what the document drew first and is held (heldBy: the id the document's script records, window.__fp.pressed). holdPage: a pattern of the page's own script, whose request waits until the press is made: the page cannot take the menu over before it, which a click's own round trips (a fast boot is over in 300 ms) would otherwise race. drawn: what the document sets once its menu is drawn and its press recorded (the first paint's own mark), waited for before the press, so the press is never earlier than the document can hold it
	{click: #Sel | [...#Sel]} | // a list: the first of them shown
	{trigger: #Sel} | // clicked as a script clicks it, shown or not
	{drag: {from: #Sel, to: #Sel}} | // a mouse pressed on from's middle, moved onto to's in steps, let go
	{check: #Sel} |
	{press: string} | // a key
	{fill: {in: #Sel, value: string}} |
	{select: {in: #Sel, value: string}} | // an option of a select, by its value
	{upload: {in: #Sel, file: string}} | // a file under tests/fixtures
	{submit: #Sel} | // a form, as the browser submits it
	{closeDialogs: true} |
	{throw: string} | // an error thrown uncaught by a script of the page, as a bug would (error tracking's reporter sees it); the message is the string
	{pay: true} | // at the checkout the page was sent to (tests/checkout.ts): the stand-in's pay button, or Stripe's sandbox card form
	{database: string} | // SQL run as the local stack's owner (DATABASE_PG_PORT, the app's `database`), never against a deployed app, an actor's `{ana.id}` and a kept value filled in: a row the open page learns of through its shape
	{pause: number & >0} | // seconds: a person's pace, where the app is waited on by nothing to see
	{hold: {to: string, method: *"POST" | string, seconds?: number & >0}} | // from now on, each such request of the page waits in the browser before it goes out: this long (seconds), or, with none, until a `release` of the same address: a slow line, or a write that is still on its way when the page leaves
	{release: string} | // lets go the requests a `hold` of this address (no seconds) keeps waiting, and those still to come: the answer is late until this step, however long the steps before it took
	{block: string} | // requests whose address matches the pattern are refused from here on, as a network that is down refuses them
	{signUp: true} | // a passkey account the terminal registers, never shown to a person, on a virtual authenticator, named as its actor
	{signIn: true} | // signs in with the app's passkey sign-in (`signIn`): at hand the actor makes an account the way signUp does and signs out first; with FLAGS_TESTER_CREDENTIAL, as that passkey's account
	{google: string} | // the strip's Google button, through the local broker's stand-in, which says it is not Google and signs in the test person named; waits for a session that is no guest. Local stacks only: the runner skips such a scenario on a deployed app
	{doorProbe: true} | // signin_door's live check: the identity broker's /probe/door, as the actor's session (PRONTO-268): in production the airlock adds Google's credential (`credential`); at hand the stand-in broker has no door (404)
	{shot: string} | // a screenshot under SHOTS
	{keep: [Var=string]: {of: #Sel, attr?: string, text?: true, value?: true}}

#Expect: {see: #Sel} | // visible
	{hidden: #Sel} | // not visible (or not there)
	{attached: #Sel} | // in the page, shown or not
	{never: string} | // no address the page (this tab, since a `revisit`) has asked for so far holds this
	{asked: string} | // an address the page (this tab, since a `revisit`) has asked for holds this
	{count: {of: #Sel, is?: int, atLeast?: int}} |
	{text: {of: #Sel, is?: string, has?: string, msg?: string}} | // msg: a key of the app's `messages`
	{value: {of: #Sel, is: string}} |
	{attr: {of: #Sel, name: string, is?: string, matches?: string, below?: number, failing?: string, says?: string}} | // failing: a value that fails the step at once, with the attribute `says` as the reason
	{attrs: {of: #Sel, name: string, are: [...string]}} |
	{address: {matches: string}} | // the page's own address, whole
	{image: {of: #Sel, width: int, height: int}} |
	// A response the page gets while doing `when`; sent: a pattern the request's own body must match.
	{response: {to: string, method: *"GET" | string, status: int, matches?: string, sent?: string, when: #Action}} |
	// Every box inside `of` at least `gutter` px from the side edges, the page never scrolling
	// sideways, and every button, link, field and select at least `tall` px tall, at each width.
	{layout: {of: #Sel, gutter: number | *16, tall: number | *44, widths?: [...int]}} |
	// Read in full: whole inside the box of its nearest `within` ancestor, under none of `clear`, and
	// the element found at its middle.
	{inView: {of: #Sel, within: #Sel, clear?: [...#Sel]}}

#Http: {
	http: {
		method: *"GET" | "POST" | "PUT" | "PATCH" | "DELETE"
		path:   string
		// Sent as JSON, or as it is when a string.
		body?: _
		headers?: [string]: string
		// No session: by itself, else as `by`.
		anon?: true
		expect: {
			status?:  int
			refused?: true // any status from 400 on
			// What the JSON answer holds, as a subset; for an array, of every element.
			json?:   _
			length?: int
			// What the answer's body holds, and what it never does, as text: a crawler's read of a
			// document, which no script has run.
			has?: [...string]
			lacks?: [...string]
			// A response header, by its lower-case name: the whole value.
			header?: [string]: string
		}
		keep?: [Var=string]: string // a dotted path into the JSON answer
	}
	// Asked again until it answers as expected, every second, up to the timeout.
	poll?: true
}

// Steps of several actors sent at one instant, each before any is answered: two guests confirming
// one time.
#Together: {together: [...#Step]}

// Holds once one of its steps holds, all asked at once: which of two racing guests won is not for
// the scenario to say.
#Any: {any: [...#Step]}

// An action done again until an expectation holds, at most `max` times: a game played through to
// its end, however many moves that takes. The expectation is asked before each action; an
// expectation's `failing` value ends the step at once.
#Repeat: {repeat: #Action, until: #Expect, max: int & >0}

// The app's own step kinds, each a field: its name the kind, its value the step's whole shape (Bonk
// Chess's `play: {play: string, refused?: true}`, a move). tests/scenarios/app.ts says what each does.
#Gestures: [Kind=string]: {(Kind): _}
#Gesture: or([for _, g in #Gestures {g}])
