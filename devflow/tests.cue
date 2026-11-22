// The flow's schema (schema.cue) held to what a repository may write: `cue vet -c=false ./devflow`.
// A check that fails is a conflict, so the vet fails; a refusal is a value the schema must make
// an error (`== _|_`).
package devflow

// A repository whose board exists already: no cluster, so `connect plane` installs nothing.
_existing: #DevFlow & {
	board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: project: "acme-prod"
}
existing: {
	noCluster: (_existing.cluster == _|_) & true
	kind:      _existing.board.kind & "plane"
	chart:     _existing.board.chart & "1.8.6"
	// A token with no kind is Secret Manager's, with the default secret.
	token: _existing.token & {kind: "secret-manager", project: "acme-prod", secret: "plane-api-token"}
	// Its states and roles are the flow's.
	states: len(_existing.states) & 9
	waitLabel: _existing.waitLabel & "waits-release"
	roles: _existing.roles & {backlog: "Backlog", implementing: "Implementing", cancelled: "Cancelled"}
}

// The token read from the environment: the variable PLANE_TOKEN unless it names another.
_env: #DevFlow & {
	board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: kind: "env"
}
_envNamed: #DevFlow & {
	board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: {kind: "env", name: "ACME_PLANE_TOKEN"}
}
envToken: {
	default: _env.token & {kind: "env", name: "PLANE_TOKEN"}
	named: _envNamed.token & {kind: "env", name: "ACME_PLANE_TOKEN"}
	// An env token has no Secret Manager project, and a Secret Manager token needs one.
	noProject: (_env.token.project == _|_) & true
	needsProject: ((#DevFlow & {token: kind: "secret-manager"}).token.project == _|_) & true
	// Another kind of token is refused.
	refused: ((#DevFlow & {token: kind: "vault"}).token == _|_) & true
}

// States and roles of the repository's own: every role names one of them.
_custom: #DevFlow & {
	board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: kind: "env"
	states: [
		{name: "Intake", group: "backlog", color: "#a3a3a3", means: "waiting"},
		{name: "Triage", group: "unstarted", color: "#60a5fa", means: "being refined"},
		{name: "To do", group: "unstarted", color: "#3b82f6", means: "refined"},
		{name: "In dev", group: "started", color: "#f59e0b", means: "building"},
		{name: "In review", group: "started", color: "#8b5cf6", means: "pull request open"},
		{name: "Merged", group: "completed", color: "#22c55e", means: "merged"},
		{name: "Shipped", group: "completed", color: "#14b8a6", means: "released"},
		{name: "Closed", group: "completed", color: "#15803d", means: "in production"},
		{name: "Dropped", group: "cancelled", color: "#ef4444", means: "will not be done"},
	]
	roles: {backlog: "Intake", refine: "Triage", ready: "To do", implementing: "In dev", review: "In review", live: "Shipped", done: "Closed", cancelled: "Dropped"}
}
customStates: {
	count: len(_custom.states) & 9
	first: _custom.states[0].name & "Intake"
	roles: _custom.roles & {backlog: "Intake", implementing: "In dev", merged: "Merged", done: "Closed"}
	// A role the repository leaves alone keeps the flow's name, which its states hold here.
	kept: _custom.roles.merged & "Merged"
}
// A role naming a state its states do not hold is refused. (A custom list that leaves a default
// role without its state is not an error here but is not concrete: `cue export` refuses it, saying
// which role names none of the states.)
refusals: {
	missingState: ((#DevFlow & {roles: ready: "Nowhere"}).roles == _|_) & true
	// The flow's states with a role renamed to a state that is not among them.
	renamedOnly: ((#DevFlow & {roles: implementing: "In dev"}).roles == _|_) & true
}

// The board's earlier name, plane: it vets, and is a board of kind plane.
_old: #DevFlow & {
	plane: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: {project: "acme-prod", secret: "acme-token"}
}
oldShapes: {
	board: _old.board & {kind: "plane", host: "plane.example.com", workspace: "acme", project: identifier: "ACME", chart: "1.8.6"}
	plane: _old.plane & {kind: "plane"}
	token: _old.token & {kind: "secret-manager", project: "acme-prod", secret: "acme-token"}
	// Writing both is fine while they say the same, and refused when they differ.
	both: ((#DevFlow & {plane: {host: "a.example.com", workspace: "w", project: {name: "n", identifier: "AB"}}, board: host: "a.example.com"}).board.host & "a.example.com")
	differ: ((#DevFlow & {plane: {host: "a.example.com", workspace: "w", project: {name: "n", identifier: "AB"}}, board: host: "b.example.com"}).board == _|_) & true
}

// github-projects: a GitHub Projects (v2) project owned by `workspace` (a GitHub login, upper case
// allowed), its issues in `repository`, on github.com (written or not); another kind is refused.
_gh: #DevFlow & {board: {kind: "github-projects", workspace: "Acme-Co", repository: "Acme-Co/shop", project: {name: "shop", identifier: "SHOP"}}, token: {kind: "env", name: "GH_PROJECTS_TOKEN"}}
boardKinds: {
	gh:      _gh.board.kind & "github-projects"
	ghHost:  _gh.board.host & "github.com"
	ghOwner: _gh.board.workspace & "Acme-Co"
	ghRepo:  _gh.board.repository & "Acme-Co/shop"
	ghElsewhere: ((#DevFlow & {board: {kind: "github-projects", host: "ghe.example.com", workspace: "a", repository: "a/b", project: {name: "b", identifier: "AB"}}}).board == _|_) & true
	ghBadRepo: ((#DevFlow & {board: {kind: "github-projects", workspace: "a", repository: "no-slash", project: {name: "b", identifier: "AB"}}}).board == _|_) & true
	planeLower: ((#DevFlow & {board: {host: "p.example.com", workspace: "Acme", project: {name: "n", identifier: "AB"}}}).board == _|_) & true
	refused: ((#DevFlow & {board: kind: "jira"}).board == _|_) & true
}

// Priorities: the flow's, and a repository's words for any of them.
_prio: #DevFlow & {priorities: P0: plane: "critical"}
priorities: {
	default: _existing.priorities.P1.plane & "high"
	own:     _prio.priorities.P0.plane & "critical"
	kept:    _prio.priorities.P0.does & _existing.priorities.P0.does
	others:  _prio.priorities.P3.plane & "low"
}

// The queue and its time zone (PRONTO-658): defaults, a repository's own, and a written `sprint`
// that still vets and only lends its time zone.
_queue: #DevFlow & {queue: {starvingDays: 5, mergedDays: 14}, timeZone: "Europe/Lisbon"}
_oldSprint: #DevFlow & {sprint: {ends: "18:00", perPerson: 3, timeZone: "America/New_York"}}
queueFlow: {
	starving: _queue.queue.starvingDays & 5
	merged:   _queue.queue.mergedDays & 14
	timeZone: _queue.timeZone & "Europe/Lisbon"
	carried:  _oldSprint.timeZone & "America/New_York"
	orderDefault:  (#DevFlow & {}).queue.order & "ready"
	jumpDefault:   (#DevFlow & {}).queue.jump & ["P0", "P1"]
	childrenOff:   (#DevFlow & {}).queue.childrenAtUmbrella & false
	orderFiled:    (#DevFlow & {queue: {order: "filed", childrenAtUmbrella: true}}).queue.order & "filed"
	orderRefused:  ((#DevFlow & {queue: order: "newest"}).queue == _|_) & true
	starvingRefused: ((#DevFlow & {queue: starvingDays: 0}).queue == _|_) & true
}

// A repository's devflow/devflow.cue, as written at the time of PRONTO-142: it still vets and every
// value it had is what it was, under the new fields (board beside plane, a token of kind
// secret-manager, the flow's roles).
_pronto: #DevFlow & {
	plane: {
		host:      "plane.example.com"
		workspace: "pronto"
		project: {name: "pronto", identifier: "PRONTO"}
	}
	cluster: {
		context: "node"
		ssh:     "pronto@203.0.113.10"
		tunnel:  "00000000-0000-4000-8000-000000000000"
	}
	token: project: "brawl-chess"
	team: {engineers: 4, sre: 1, product: 1}
	sprint: {ends: "18:00", perPerson: 3}
}
pronto: {
	board: _pronto.board & {kind: "plane", host: "plane.example.com", workspace: "pronto", project: {name: "pronto", identifier: "PRONTO"}, chart: "1.8.6"}
	plane: _pronto.plane & {host: "plane.example.com", workspace: "pronto", project: {name: "pronto", identifier: "PRONTO"}, chart: "1.8.6"}
	cluster: _pronto.cluster & {context: "node", ssh: "pronto@203.0.113.10", namespace: "plane", tunnel: "00000000-0000-4000-8000-000000000000", apiPort: 26443}
	token: _pronto.token & {kind: "secret-manager", project: "brawl-chess", secret: "plane-api-token"}
	team: _pronto.team & {engineers: 4, sre: 1, architect: 1, product: 1}
	queue: _pronto.queue & {starvingDays: 3, mergedDays: 7}
	timeZone: _pronto.timeZone & "America/Sao_Paulo"
	infra: _pronto.infra & ["infra"]
	// The architect seat (the owner, 2026-11-14): one by default, its issues in the module design.
	design: _pronto.design & ["design"]
	architectModel: _pronto.architectModel & "opus"
	architectRefused: ((#DevFlow & {team: architect: -1}).team == _|_) & true
	chore: _pronto.chore & "chore"
	states: [for s in _pronto.states {s.name}] & ["Backlog", "Refine", "Ready", "Implementing", "Review", "Merged", "Live", "Done", "Cancelled"]
	roles: _pronto.roles & {backlog: "Backlog", refine: "Refine", ready: "Ready", implementing: "Implementing", review: "Review", merged: "Merged", live: "Live", done: "Done", cancelled: "Cancelled"}
}

// The inbox (PRONTO-544): absent, the board is as it was; present, its defaults hold.
_inbox: #DevFlow & {
	board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
	token: project: "acme-prod"
	suggestions: {project: "SUGEST", from: ["aprende"]}
}
suggestions: {
	absent:  (_existing.suggestions == _|_) & true
	project: _inbox.suggestions.project & "SUGEST"
	from: _inbox.suggestions.from & ["aprende"]
	name:      _inbox.suggestions.name & "Suggestions"
	staleDays: _inbox.suggestions.staleDays & 14
	label:     _inbox.suggestions.label & "suggestion"
	states: [for s in _inbox.suggestions.states {s.name}] & ["Suggested", "Refine", "Cancelled"]
	own: (#DevFlow & {
		board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
		token: project: "acme-prod"
		suggestions: {project: "IDEAS", from: ["a", "b"], staleDays: 7}
	}).suggestions.staleDays & 7
	lowerCase: ((#DevFlow & {suggestions: {project: "sugest", from: ["aprende"]}}).suggestions == _|_) & true
	noApps: ((#DevFlow & {suggestions: {project: "SUGEST", from: []}}).suggestions == _|_) & true
	notPlane: ((#DevFlow & {
		board: {kind: "github-projects", workspace: "acme", repository: "acme/acme", project: {name: "acme", identifier: "ACME"}}
		suggestions: {project: "SUGEST", from: ["aprende"]}
	}).suggestions == _|_) & true
	sameAsBoard: ((#DevFlow & {
		board: {host: "plane.example.com", workspace: "acme", project: {name: "acme", identifier: "ACME"}}
		suggestions: {project: "ACME", from: ["aprende"]}
	}).suggestions == _|_) & true
}
