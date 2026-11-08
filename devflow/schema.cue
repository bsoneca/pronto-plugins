// The dev flow (bsoneca/pronto's docs/dev-flow.md) as data: where the board is, the states an
// issue moves through, what a priority means, and the sprint's cap and end. Written once here and
// in the repository's own devflow/devflow.cue (its devFlow values); read by the intent that sets
// the board up (connect.ts), the hooks that move issues (hook.ts) and the skills.
package devflow

devFlow: #DevFlow

#DevFlow: {
	// The board: a self-hosted Plane (plane-ce), one workspace, one project for every app.
	plane: {
		host!:      string & =~"^[a-z0-9.-]+$"
		workspace!: string & =~"^[a-z0-9-]+$"
		project: {
			name!: string
			// The key every issue, branch and pull request carries: PRONTO-123.
			identifier!: string & =~"^[A-Z]{2,12}$"
		}
		// The plane-ce chart (https://helm.plane.so) the intent installs.
		chart: *"1.8.6" | string
	}
	// Where Plane runs: a k3s node reached over SSH, its door a Cloudflare Tunnel into the node's
	// Envoy Gateway, as pronto's release@k8s sets every node up (envs.Metal).
	cluster: {
		context!:  string
		ssh!:      string & =~"^[a-z0-9_.-]+@[a-z0-9.-]+$"
		namespace: *"plane" | string
		// The tunnel (cloudflared) whose catch-all sends the node's hostnames to the gateway.
		tunnel!: string & =~"^[0-9a-f-]{36}$"
		// The local port the intent tunnels the node's API to, as the kube context names it.
		apiPort: *26443 | int
	}
	// The board's API token: kept in Secret Manager, read with the reader's own gcloud; PLANE_TOKEN
	// in the environment (a GitHub Actions secret) wins.
	token: {
		project!: string
		secret:   *"plane-api-token" | string
	}
	// How many issues may be in Implementing at once (rule 1): the sessions the machines can run.
	agents: *4 | (int & >=1)
	// A sprint is one day and ends at this time, each day.
	sprint: {
		ends:     *"18:00" | (string & =~"^([01][0-9]|2[0-3]):[0-5][0-9]$")
		timeZone: *"America/Sao_Paulo" | string
	}
	// A pull request with this label needs no issue (dependency bumps, the CI fingerprint).
	chore: *"chore" | string

	// The states, in order, each in one of Plane's groups. Fixed by the flow, not by a repository.
	states: [...#State] & _states
	// P0..P3 as Plane's priorities, and what each does.
	priorities: _priorities
}

#State: {
	name:  string
	group: "backlog" | "unstarted" | "started" | "completed" | "cancelled"
	color: =~"^#[0-9a-f]{6}$"
	means: string
}

// Merged, Live and Done are all in Plane's completed group: a sprint counts an issue done once it
// merged (rule 8), and a cycle's progress is its completed group's share.
_states: [
	{name: "Backlog", group: "backlog", color: "#a3a3a3", means: "on the board, not planned"},
	{name: "Refine", group: "unstarted", color: "#60a5fa", means: "in the sprint, being turned into an objective that can be met"},
	{name: "Ready", group: "unstarted", color: "#3b82f6", means: "objective, acceptance, flag and app written down"},
	{name: "Implementing", group: "started", color: "#f59e0b", means: "a Claude session is building it; counts against the agent cap"},
	{name: "Review", group: "started", color: "#8b5cf6", means: "its pull request is open"},
	{name: "Merged", group: "completed", color: "#22c55e", means: "merged to main; done for the sprint"},
	{name: "Live", group: "completed", color: "#14b8a6", means: "released, its flag still off"},
	{name: "Done", group: "completed", color: "#15803d", means: "in production, its flag flipped on; the task is closed"},
	{name: "Cancelled", group: "cancelled", color: "#ef4444", means: "will not be done; why is in a comment"},
]

_priorities: {
	P0: {plane: "urgent", does: "fixed now: straight to Implementing, past the agent cap"}
	P1: {plane: "high", does: "enters the current sprint, waits for the work in progress"}
	P2: {plane: "medium", does: "Backlog, considered at the next planning"}
	P3: {plane: "low", does: "Backlog"}
}
