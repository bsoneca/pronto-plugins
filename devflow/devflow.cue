// The board this repository's pull requests move: bsoneca/pronto's PRONTO project, set up from that
// repository (its devflow/devflow.cue names the node and the team). Here the board and its token
// alone, as pronto-plugins' devflow/schema.cue allows a repository that only reports to a board:
// the `plane` workflow's hook moves an issue whose key a pull request
// names (PRONTO-204).
package devflow

devFlow: {
	board: {
		host:      "plane.bsoneca.com"
		workspace: "pronto"
		project: {name: "pronto", identifier: "PRONTO"}
	}
	token: project: "brawl-chess"
	// The queue is pulled in filing order (the owner, PRONTO-1538): a design's children sort at
	// their umbrella's place, and a bug at P1 or P0 still jumps.
	queue: {order: "filed", childrenAtUmbrella: true}
}
