# A broker at several replicas on a metal cluster (PRONTO-371), shared by identity/metal.nu and
# billing/metal.nu, in the shape pronto's k8s schema gives an app's workloads: spread over the nodes
# by hostname where it can (ScheduleAnyway: on one node it schedules as before, and spreads the day
# more exist), and a PodDisruptionBudget of all but one, so a drain takes one pod at a time.

# The pod spec's spread, for pods labelled `labels`.
export def spread [labels: record]: nothing -> list<record> {
	[{maxSkew: 1, topologyKey: "kubernetes.io/hostname", whenUnsatisfiable: "ScheduleAnyway", labelSelector: {matchLabels: $labels}}]
}

# The budget: all but one of `replicas` stay up through a voluntary disruption. None for one replica,
# which a budget of all but one would leave free to go.
export def budget [meta: record, name: string, labels: record, replicas: int]: nothing -> list<record> {
	if $replicas < 2 { return [] }
	[{apiVersion: "policy/v1", kind: "PodDisruptionBudget", metadata: ($meta | insert name $name), spec: {minAvailable: ($replicas - 1), selector: {matchLabels: $labels}}}]
}
