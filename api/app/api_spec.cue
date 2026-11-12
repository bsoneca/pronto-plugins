package __PACKAGE__

// The app's API (pronto-plugins api/README.md): which entities are exported over /api/v1, their
// public fields and methods. Written once by pronto-api; the app's own from then on. Nothing is
// exported until a resource is named here.
api: {
	// The flag the API rides (flags_spec.cue's own; default false, local true).
	flag: "api_export"
	entities: {}
}
