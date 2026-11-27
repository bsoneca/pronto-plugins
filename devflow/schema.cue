// The dev flow (devflow/dev-flow.md) as data: where the board is, the states an issue moves
// through, what a priority means, the team and how its Ready queue runs. Written once here and in the
// repository's own devflow/devflow.cue (its devFlow values); read by the intent that sets the
// board up (connect.ts), the hooks that move issues (hook.ts) and the skills. Every default and
// every normalization is here: the exported devFlow is final, and spec.ts adds none.
package devflow

devFlow: #DevFlow

#DevFlow: {
	// The board: one workspace, one project for every app. Plane is the board implemented; the
	// repository's own, or one `connect plane` installs (cluster, below).
	board: #Board
	// Read as the board's earlier name: a repository that writes `plane: {...}` vets and its
	// board is that, of kind plane. Write `board` in a new one.
	plane?: #Board & {kind: "plane"}
	if plane != _|_ {
		board: plane
	}

	// Where Plane runs, when this repository installs it: a k3s node reached over SSH, its door a Cloudflare Tunnel into the node's
	// Envoy Gateway, as pronto's release@k8s sets every node up (envs.Metal). Only the repository
	// the board is set up from names it: another repository whose pull requests move the same
	// board's issues names the board and its token alone,
	// and its hooks run. With no cluster, `connect plane` installs nothing: it checks that the
	// board's host answers and that the token signs in, then makes the project, its states, its
	// modules and its labels.
	cluster?: {
		context!:  string
		ssh!:      string & =~"^[a-z0-9_.-]+@[a-z0-9.-]+$"
		namespace: *"plane" | string
		// The tunnel (cloudflared) whose catch-all sends the node's hostnames to the gateway.
		tunnel!: string & =~"^[0-9a-f-]{36}$"
		// The local port the intent tunnels the node's API to, as the kube context names it.
		apiPort: *26443 | int
	}
	// The board's API token, by where it is kept: Secret Manager (read with the reader's own gcloud)
	// or the environment variable `name`. PLANE_TOKEN in the environment (a GitHub Actions secret)
	// wins for every kind. A token written as `{project, secret?}` with no kind is Secret Manager's.
	token: *#SecretManagerToken | #EnvToken
	// The team (rule 1). Engineers, SREs and architects build: each is a slot, and an issue in
	// Implementing takes one. An SRE's slots build the infra modules' issues, an architect's the
	// design modules' (the owner, 2026-11-14: "Add an architect seat"), an engineer's every other
	// module's, so infrastructure and design never wait behind app work, nor app work behind them.
	// The product managers take no slot: they design what is to come, turning Backlog issues into
	// Ready ones (objective, acceptance, flag) that the queue then holds.
	team: {
		engineers: *2 | (int & >=0)
		sre:       *1 | (int & >=0)
		architect: *1 | (int & >=0)
		product:   *1 | (int & >=0)
		// How many of the engineer slots take only feature issues (the label `featureLabel`); the others take any
		// engineer issue. Bugs and security fixes cannot fill every lane while features wait (the owner, 2026-11-21).
		// More than the engineers is as many as the engineers.
		featureEngineers: *3 | (int & >=0)
	}
	// The modules an SRE builds: the cloud's configuration (infra/) and the nodes. Made beside a
	// module per app.
	infra: *["infra"] | [...string]
	// The modules an architect designs. An issue there ends in a design doc in the repository and
	// follow-up issues filed in build order, never in an implementation or a release.
	design: *["design"] | [...string]
	// The model the architect's session runs on (the owner, 2026-11-14: "Architects work with opus";
	// then "I might also consider fable to architect"): opus by default, a repository changes it here.
	architectModel: *"opus" | string
	// There are no sprints (PRONTO-658, the owner, 2026-11-17): Ready is a first-in first-out queue,
	// each lane pulls the issue that became Ready first, and a bug at P1 jumps it. An issue is
	// starving when it has waited in Ready more than `starvingDays` days: `status` says so, and the
	// lead looks at what is in the way.
	queue: {
		starvingDays: *3 | (int & >=1)
		// The order a lane pulls its Ready issues in (PRONTO-1538). "ready": by when each issue
		// became Ready (its latest move into Ready), the order of PRONTO-658, which a board that
		// sets nothing keeps. "filed": by when each issue was filed (its creation time), then its
		// number; moving an issue into Ready again changes nothing, and a new ask made Ready today
		// waits behind an older one made Ready later.
		order: *"ready" | "filed"
		// The priorities at which a bug jumps the queue, each pulled before any issue that does not
		// (a P0's before a P1's, as the P0 starts past the slots). Only a bug jumps: a feature at P1
		// waits its turn.
		jump: *["P0", "P1"] | [...("P0" | "P1" | "P2" | "P3")]
		// Whether a child issue split from a design is ordered at its umbrella's place (the issue
		// the board gives as its parent): in "filed" order it sorts at the umbrella's creation time
		// and number, its siblings by their own number. A child whose parent the board did not
		// list sorts by its own creation. Read in "filed" order alone.
		childrenAtUmbrella: *false | bool
		// The window `status` counts merges over, in days.
		mergedDays: *7 | (int & >=1)
	}
	// The time zone the days `status` counts merges by, and the inbox's dates, are in.
	timeZone: *"America/Sao_Paulo" | string
	// A repository that still writes the old `sprint` vets, and is read for nothing but its time
	// zone, carried into `timeZone` as `plane` is into `board`. Delete it.
	sprint?: {
		perPerson?: int
		timeZone?:  string
		ends?:      string
	}
	if sprint != _|_ if sprint.timeZone != _|_ {
		timeZone: sprint.timeZone
	}

	// Hours an issue holding a slot (Implementing or Review) may go with no linked open pull request and no
	// commit on a branch naming its key before `status` calls it stuck.
	stuckHours: *6 | (number & >0)
	// The pull requests the hourly watch reads (`pronto-devflow prs`, and a line of `status`): the open,
	// non-draft ones of these repositories (owner/name) that nobody has touched in `idleHours`, or
	// whose check failed with no push since (flow.js forgottenPrs).
	prs: {
		repos:     *["bsoneca/pronto", "bsoneca/pronto-plugins"] | [...(string & =~"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")]
		idleHours: *1 | (number & >0)
	}
	// The repository whose apps' flags the pending-flags watch reads (`pronto-devflow flags`, and a line of
	// `status`): every apps/<app> with a flags_spec.cue at its origin/main (owner/name).
	flagsRepo: *"bsoneca/pronto" | (string & =~"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
	// Flags the owner holds back: merged and off, but not to be flipped, so the watch never lists them. The
	// list is the flow's, not the flag's: a held flag stays an ordinary one in its app, and flags_plugin.cue's
	// #Flag, generated into every app, is not changed for a watcher. Seeded with the one the owner holds.
	flagsHeld: *[{app: "brawl-chess", flag: "capture_fights", why: "the owner, 2026-11-22: \"If the capture_flags change to those boring fights, I don't want them.\""}] | [...{
		app:  string & !=""
		flag: string & !=""
		why:  string & !=""
	}]
	// The alerts watch (PRONTO-2182): `pronto-devflow alerts` reads each project's Cloud Monitoring incidents and files a bug
	// for each alert policy that is down (outage), opens and closes over and over (flapping) or has been open for days
	// (stale). Absent, the repository has no such watch. `apps` maps a policy's `app` (else `owner`) user label to the
	// board's module; one that maps to none is filed under `plugins`, naming the label. `sources` say which file holds a
	// policy by the start of its display name (the longest prefix; "" matches all), so a bug names what to change.
	alerts?: {
		projects: [...string & =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"]
		// More events (incidents opened within 5 minutes of each other are one) than this in 24 hours, or two incidents that
		// closed within `flapCloseMin` minutes of opening, is flapping, unless the policy is open now (an outage, or stale).
		flapOpens:    *3 | (int & >0)
		flapCloseMin: *30 | (number & >0)
		// An incident open longer than this is stale.
		staleHours: *24 | (number & >0)
		apps: [string]: string
		// Policies whose `app` or `owner` label is listed are never filed (an app on hold, whose policies await deletion).
		ignore: *[] | [...string]
		sources: [...{prefix: string, cue: string}]
		// The board's priority word of each class.
		priority: {
			outage:   *"urgent" | string
			flapping: *"high" | string
			stale:    *"medium" | string
		}
	}
	// A pull request with this label needs no issue (dependency bumps, the CI fingerprint).
	chore: *"chore" | string
	// The board label of an Implementing flip issue that waits for the release holding its fix: it holds no
	// slot (PRONTO-666) until the release clears it.
	waitLabel: *"waits-release" | string
	// The board label of a feature issue: one of the slots the team reserves for them (team.featureEngineers).
	featureLabel: *"feature" | string
	// An inbox project beside the board's, where an app files what its players suggest (PRONTO-544).
	// Nothing in the loop reads it: the owner approves a suggestion by moving it to Refine, or rejects
	// it by moving it to Cancelled, and `pronto-devflow approve` files an approved one as an issue of
	// the board. Absent, the board is as it was.
	// A Plane board alone holds an inbox: another kind's board has no second project to make.
	suggestions?: #Suggestions & {project: !=board.project.identifier, _plane: board.kind & "plane"}

	// The states, in order, each in one of the board's groups: the flow's own, or a repository's
	// list of its own (then every role below names one of them).
	states: *(_states & [...#State]) | [...#State]
	// Which state plays each role of the flow, by the repository's name for it. The rules
	// (flow.js) reason in roles; the board knows names.
	roles: #Roles
	// P0..P3 as the board's priorities, and what each does.
	priorities: #Priorities
	// Every role names a state of `states`.
	roles: [string]: or([for s in states {s.name}])
}

#Board: {
	// plane: a Plane workspace (plane.ts). github-projects: a GitHub Projects (v2) project
	// (github-projects.ts), owned by the user or organization `workspace`, its issues in `repository`.
	kind:  *"plane" | "github-projects"
	host!: string & =~"^[a-z0-9.-]+$"
	// Plane's workspace slug; on GitHub, the project's owner's login.
	workspace!: string
	if kind == "plane" {
		workspace!: =~"^[a-z0-9-]+$"
	}
	if kind == "github-projects" {
		host:       "github.com"
		workspace!: =~"^[A-Za-z0-9-]+$"
		// The repository whose issues the project holds: PRONTO-123 is its #123.
		repository!: string & =~"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
	}
	project: {
		name!: string
		// The key every issue, branch and pull request carries: PRONTO-123.
		identifier!: string & =~"^[A-Z]{2,12}$"
	}
	// The plane-ce chart (https://helm.plane.so) the intent installs, when it installs Plane.
	chart: *"1.8.6" | string
	// Who gets in, on a Plane the intent installs (cluster), written into Plane's instance
	// configuration by `connect plane`, never in god-mode by hand: sign-up off, so only an invited
	// person joins (an invitation's email may still sign up), and GitHub's sign-in when `github` names
	// the repository's SOPS file holding its OAuth App (a Secret's stringData `client_id` and
	// `client_secret`, from the repository's root). The App's callback is
	// https://<host>/auth/github/callback/. GitHub signs a person in by their primary, verified email.
	// Plane's own keys (secret_key, live_server_secret_key): a repository whose Plane data must outlive
	// its cluster (a move, a reinstall) keeps them in devflow/secrets.plane-keys.enc.yaml, a SOPS
	// Secret with both. `connect plane` installs plane-keys from it, never new ones, and stops where the
	// cluster's differ. Without it, connect makes random keys once and keeps them in the cluster.
	access: {
		signup: *false | bool
		github?: secrets!: string & =~"(^|/)secrets\\.[a-z0-9-]+\\.enc\\.yaml$"
	}
}

#Suggestions: {
	// The inbox's key: SUGEST-3. It is not the board's own.
	project!: string & =~"^[A-Z]{2,12}$"
	name:     *"Suggestions" | string
	// The apps that may file into it, each a module of the board.
	from!: [string, ...string]
	// A waiting suggestion is flagged once it is older than this many days.
	staleDays: *14 | (int & >=1)
	label:     *"suggestion" | string
	// Plane's own default states stay in the inbox; status and approve read these three alone.
	states: [
		{name: "Suggested", group: "backlog", color: "#a3a3a3", means: "waiting on the owner"},
		{name: "Refine", group: "unstarted", color: "#60a5fa", means: "approved by the owner, to file"},
		{name: "Cancelled", group: "cancelled", color: "#ef4444", means: "rejected by the owner"},
	]
}

#SecretManagerToken: {
	kind:     "secret-manager"
	project!: string
	secret:   *"plane-api-token" | string
}

#EnvToken: {
	kind: "env"
	name: *"PLANE_TOKEN" | string
}

// The flow's roles, in order, and the name each state has by default.
#Roles: {
	backlog:      *"Backlog" | string
	refine:       *"Refine" | string
	ready:        *"Ready" | string
	implementing: *"Implementing" | string
	review:       *"Review" | string
	merged:       *"Merged" | string
	live:         *"Live" | string
	done:         *"Done" | string
	cancelled:    *"Cancelled" | string
}

#Priorities: {
	P0: {plane: *_priorities.P0.plane | string, does: *_priorities.P0.does | string}
	P1: {plane: *_priorities.P1.plane | string, does: *_priorities.P1.does | string}
	P2: {plane: *_priorities.P2.plane | string, does: *_priorities.P2.does | string}
	P3: {plane: *_priorities.P3.plane | string, does: *_priorities.P3.does | string}
}

#State: {
	name:  string
	group: "backlog" | "unstarted" | "started" | "completed" | "cancelled"
	color: =~"^#[0-9a-f]{6}$"
	means: string
}

// Merged, Live and Done are all in Plane's completed group: an issue counts as done once it merged
// (rule 8), and `status` counts merges by day from when each reached it.
_states: [
	{name: "Backlog", group: "backlog", color: "#a3a3a3", means: "on the board, not yet being refined"},
	{name: "Refine", group: "unstarted", color: "#60a5fa", means: "being turned into an objective that can be met"},
	{name: "Ready", group: "unstarted", color: "#3b82f6", means: "designed: objective, acceptance, flag and app written down; in the queue, oldest first"},
	{name: "Implementing", group: "started", color: "#f59e0b", means: "a Claude session is building it; takes an engineer's, an SRE's or an architect's slot"},
	{name: "Review", group: "started", color: "#8b5cf6", means: "its pull request is open"},
	{name: "Merged", group: "completed", color: "#22c55e", means: "merged to main; done for the flow"},
	{name: "Live", group: "completed", color: "#14b8a6", means: "released, its flag still off"},
	{name: "Done", group: "completed", color: "#15803d", means: "in production, its flag flipped on; the task is closed"},
	{name: "Cancelled", group: "cancelled", color: "#ef4444", means: "will not be done; why is in a comment"},
]

_priorities: {
	P0: {plane: "urgent", does: "fixed now: straight to Implementing, past the slots"}
	P1: {plane: "high", does: "a bug at P1 jumps the Ready queue, then waits for a free slot"}
	P2: {plane: "medium", does: "Backlog, refined by the lead in value order"}
	P3: {plane: "low", does: "Backlog"}
}
