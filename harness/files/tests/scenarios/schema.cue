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
// Postfix aliases ([string]~(K,_)): the only form cue 0.18 accepts, and cue 0.16 takes it under
// this experiment, so every app reads this file whichever cue it pins.
@experiment(aliasv2)

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
// The pin is also the schema the board reads the repository's devflow/devflow.cue with: a devflow.cue newer than the
// pinned schema (the architect seat, against 17630bc5) fails `cue export`, so the filing fails (PRONTO-765). Move the pin
// whenever devflow/schema.cue changes.
flakes: {
	app?:     string
	priority: "P0" | "P1" | *"P2" | "P3"
	file: [...string] | *["deno", "run", "-A", "https://raw.githubusercontent.com/bsoneca/pronto-plugins/e8e32262a51ac2b17b55e8afa0447c9a1301ef2b/devflow/board.ts", "file"]
	// Runs nothing any more: a failed scenario is never run again for its verdict, only a wedged renderer is
	// (AGENTS.md). Kept so the apps that set it (Bonk Chess, Prontoweeper) still hold to this schema.
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
// calls them inert (`live`, regular expressions) and sibling apps' files the app reads (`outside`, regular
// expressions of `../<other>/…` paths: Studio's builder scans every apps/*, PRONTO-870).
select: {
	client: [...string] | *[]
	derived: [...string] | *[]
	inert: [...string] | *[]
	live: [...string] | *[]
	outside: [...string] | *[]
}
// The stack's database, for a `database` step (POSTGRES_DB, where set, wins).
database?: string
// The app's passkey sign-in, for a `signIn` step: what opens it (the first of them shown) and its
// passkey's button.
signIn?: {open: [...#Sel], passkey: #Sel}

scenarios: [string]~(Id,_): #Scenario & {id: Id}

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
	// The steps `together` and `any` hold are steps too, three levels down (`_in1`..`_in3`), and no deeper.
	_in1: [for s in steps for L in ["together", "any"] if s[L] != _|_ for t in s[L] {t}]
	_in2: [for s in _in1 for L in ["together", "any"] if s[L] != _|_ for t in s[L] {t}]
	_in3: [for s in _in2 for L in ["together", "any"] if s[L] != _|_ for t in s[L] {t}]
	// None deeper: a fourth level would be typed but not held to its kind, so it is refused.
	_in4: [for s in _in3 for L in ["together", "any"] if s[L] != _|_ for t in s[L] {t}] & []
	// Each holds to its one kind's whole shape, closed (`#Step`), and says what fails: `kinds` that it has
	// not one, `shape` that a field is not the kind's or has the wrong type, `missing` that a field the kind
	// requires is not there.
	_checked: [for l in [steps, _in1, _in2, _in3] for s in l let ks = [for K in _kindNames if s[K] != _|_ {K}] {
		if len(ks) != 1 {kinds: "a step has exactly one kind, this one has \(len(ks))" & "one kind"}
		if len(ks) == 1 {
			shape: s & close({#Common, _shapes[ks[0]]})
			missing: {for F, _ in _shapes[ks[0]] if s[F] == _|_ {(F): "a \(ks[0]) step needs \(F)" & "present"}}
		}
	}]
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

#Common: {
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
	// Asked only on the deployed app ("production") or only on a stack at hand ("local", never a
	// deployed preview): what a listing may be differs, a laptop's naming the stack's own address.
	on?: "production" | "local"
	// Open here: a step embeds it beside its kind's fields, and `#Scenario._checked` closes the whole
	// shape. Closed, cue 0.18 would refuse every kind's field on `#Step` (aprende, PRONTO-870).
	...
}

// A step is one of the kinds (`_kinds`, below), chosen by its field, never by a disjunction: a disjunction
// over every kind (about 60 closed structs, unified against every step of every scenario) cost Bonk
// Chess's scenarios 96 G instructions and 2.9 GB. `#Step` is open: it types each kind's own field, and a
// scenario (`#Scenario`'s `_checked`) holds every step it lists, those of `together` and `any` too, to the
// whole shape of its one kind, closed, with the fields every step has (`#Common`). So a field only a kind
// takes (an http's `poll`, a repeat's `until` and `max`, a gesture's `refused`) is allowed, and required,
// with that kind alone, and a step of no kind or of two is refused. The check is not in `#Step` because a
// definition is evaluated bare too, where it has no kind, and one that read its own fields to choose the
// kind (an embedded comprehension on `self`) took exponential time under cue 0.16.1.
#Step: {
	#Common
	for K, v in _kinds {(K)?: v[K]}
	together?: [...#Step]
	any?: [...#Step]
	...
}

#Action: _action
_action: or([for _, a in _actions {a}])
_actions: {
	open: {open: string} // a path of the app or a URL, waited for as the app's pages load (`loaded`)
	reload: {reload: true}
	revisit: {revisit: string} // the tab closed and the app opened again at this path in a new one: what the browser keeps (its storage, its cookies) stays, the tab's own session does not
	leave: {leave: true} // the page says it is being left (pagehide), as a closing tab does: what a page reports on leaving goes out
	rush: {rush: {open: string, click: #Sel, heldBy?: string, holdPage?: string, drawn?: #Sel}} // opened without waiting for the boot, and pressed at once: the press lands on what the document drew first and is held (heldBy: the id the document's script records, window.__fp.pressed). holdPage: a pattern of the page's own script, whose request waits until the press is made: the page cannot take the menu over before it, which a click's own round trips (a fast boot is over in 300 ms) would otherwise race. drawn: what the document sets once its menu is drawn and its press recorded (the first paint's own mark), waited for before the press, so the press is never earlier than the document can hold it
	click: {click: #Sel | [...#Sel]} // a list: the first of them shown
	trigger: {trigger: #Sel} // clicked as a script clicks it, shown or not
	drag: {drag: {from: #Sel, to: #Sel}} // a mouse pressed on from's middle, moved onto to's in steps, let go
	check: {check: #Sel}
	press: {press: string} // a key
	fill: {fill: {in: #Sel, value: string}}
	select: {select: {in: #Sel, value: string}} // an option of a select, by its value
	upload: {upload: {in: #Sel, file: string}} // a file under tests/fixtures
	submit: {submit: #Sel} // a form, as the browser submits it
	closeDialogs: {closeDialogs: true}
	throw: {throw: string} // an error thrown uncaught by a script of the page, as a bug would (error tracking's reporter sees it); the message is the string
	pay: {pay: true} // at the checkout the page was sent to (tests/checkout.ts): the stand-in's pay button, or Stripe's sandbox card form
	database: {database: string} // SQL run as the local stack's owner (DATABASE_PG_PORT, the app's `database`), never against a deployed app, an actor's `{ana.id}` and a kept value filled in: a row the open page learns of through its shape
	pause: {pause: number & >0} // seconds: a person's pace, where the app is waited on by nothing to see
	hold: {hold: {to: string, method: *"POST" | string, seconds?: number & >0}} // from now on, each such request of the page waits in the browser before it goes out: this long (seconds), or, with none, until a `release` of the same address: a slow line, or a write that is still on its way when the page leaves
	release: {release: string} // lets go the requests a `hold` of this address (no seconds) keeps waiting, and those still to come: the answer is late until this step, however long the steps before it took
	block: {block: string} // requests whose address matches the pattern are refused from here on, as a network that is down refuses them
	signUp: {signUp: true} // a passkey account the terminal registers, never shown to a person, on a virtual authenticator, named as its actor
	signIn: {signIn: true} // signs in with the app's passkey sign-in (`signIn`): at hand the actor makes an account the way signUp does and signs out first; with FLAGS_TESTER_CREDENTIAL, as that passkey's account
	google: {google: string} // the strip's Google button, through the local broker's stand-in, which says it is not Google and signs in the test person named; waits for a session that is no guest. Local stacks only: the runner skips such a scenario on a deployed app
	doorProbe: {doorProbe: true} // signin_door's live check: the identity broker's /probe/door, as the actor's session (PRONTO-268): in production the airlock adds Google's credential (`credential`); at hand the stand-in broker has no door (404)
	shot: {shot: string} // a screenshot under SHOTS
	keep: {keep: [string]: {of: #Sel, attr?: string, text?: true, value?: true}}
}

#Expect: _expect
_expect: or([for _, e in _expects {e}])
_expects: {
	see: {see: #Sel} // visible
	hidden: {hidden: #Sel} // not visible (or not there)
	attached: {attached: #Sel} // in the page, shown or not
	never: {never: string} // no address the page (this tab, since a `revisit`) has asked for so far holds this
	asked: {asked: string} // an address the page (this tab, since a `revisit`) has asked for holds this
	count: {count: {of: #Sel, is?: int, atLeast?: int}}
	text: {text: {of: #Sel, is?: string, has?: string, msg?: string}} // msg: a key of the app's `messages`
	value: {value: {of: #Sel, is: string}}
	attr: {attr: {of: #Sel, name: string, is?: string, matches?: string, below?: number, failing?: string, says?: string}} // failing: a value that fails the step at once, with the attribute `says` as the reason
	attrs: {attrs: {of: #Sel, name: string, are: [...string]}}
	address: {address: {matches: string}} // the page's own address, whole
	image: {image: {of: #Sel, width: int, height: int}}
	// A response the page gets while doing `when`; sent: a pattern the request's own body must match.
	response: {response: {to: string, method: *"GET" | string, status: int, matches?: string, sent?: string, when: #Action}}
	// Every box inside `of` at least `gutter` px from the side edges, the page never scrolling
	// sideways, and every button, link, field and select at least `tall` px tall, at each width.
	layout: {layout: {of: #Sel, gutter: number | *16, tall: number | *44, widths?: [...int]}}
	// Read in full: whole inside the box of its nearest `within` ancestor, under none of `clear`, and
	// the element found at its middle.
	inView: {inView: {of: #Sel, within: #Sel, clear?: [...#Sel]}}
}

#Http: _http
_http: {
	http: {
		method: *"GET" | "POST" | "PUT" | "PATCH" | "DELETE"
		// On the app's door, or a whole URL on another origin (a published game's address), which is asked
		// as no one in a request context of its own (no session, cookie, header or body), keeps nothing and
		// follows no redirect: a 3xx is its answer. A path on the door follows redirects onto its own host
		// or a name under it, on any port, and no further.
		path: string
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
		keep?: [string]:     string // a dotted path into the JSON answer
		keepText?: [string]: string // a regular expression over the answer's text: its first group is kept; no match fails the step
	}
	// Asked again until it answers as expected, every second, up to the timeout.
	poll?: true
}

// Steps of several actors sent at one instant, each before any is answered: two guests confirming
// one time.
#Together: _together
_together: {together: [...#Step]}

// Holds once one of its steps holds, all asked at once: which of two racing guests won is not for
// the scenario to say.
#Any: _any
_any: {any: [...#Step]}

// An action done again until an expectation holds, at most `max` times: a game played through to
// its end, however many moves that takes. The expectation is asked before each action; an
// expectation's `failing` value ends the step at once.
#Repeat: _repeat
_repeat: {repeat: #Action, until: #Expect, max: int & >0}

// The app's own step kinds, each a field: its name the kind, its value the step's whole shape (Bonk
// Chess's `play: {play: string, refused?: true}`, a move). tests/scenarios/app.ts says what each does.
#Gestures: [string]~(Kind,_): {(Kind): _}
#Gesture: _gesture
_gesture: or([for _, g in #Gestures {g}])

// Every kind a step takes, by its name: each value is the step's whole shape for that kind, so the
// fields only it takes are written with it. The app's own (`#Gestures`) are kinds too.
_kinds: {
	_actions
	_expects
	http:   _http
	repeat: _repeat
	for K, g in #Gestures {(K): g}
}
// `_kinds` and the two kinds that hold steps (which `#Step` declares itself).
_shapes: {
	_kinds
	together: _together
	any:      _any
}
_kindNames: [for K, _ in _shapes {K}]
