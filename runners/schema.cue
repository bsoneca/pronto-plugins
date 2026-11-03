// What a runners setup (README.md) is, written as data: where the cluster is, whose GitHub jobs it
// takes, its runner scale sets, the BuildKit they share and the secret they register with (named,
// never its values). A setup is one field of `setups` (setups.cue); host.cue renders it into what
// runners.ts applies.
package runners

setups: [Name=string]: #Setup & {name: Name}

#Setup: {
	name!: =~"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"

	// The cluster the controller, BuildKit and the runners run in: a Colima k3s VM this machine
	// starts, or a cluster a kubeconfig context already reaches (a remote k3s, a cloud one).
	cluster: #Colima | #Context

	github: {
		owner!: =~"^[A-Za-z0-9-]+$"
		// A user account's runners belong to one repository each, so each of its scale sets names
		// one; an organization's may serve all its repositories.
		kind: *"user" | "org"
	}

	// The Kubernetes secret, in the runners' namespace, the scale sets register with. Created by a
	// person (runners.ts prints how), never written here: a fine-grained token (`pat`, key
	// github_token) or a GitHub App's id, installation and key (`app`).
	secret: {
		name: *"gha-token" | #DNS
		kind: *"pat" | "app"
	}

	// What a workflow writes in runs-on, to each scale set's settings. Each job gets a fresh pod.
	scaleSets: [Name=#DNS]: {
		// The repository, owner's name only; an organization's scale set without one serves them all.
		if github.kind == "user" {repo!: string}
		repo?: =~"^[A-Za-z0-9_.-]+$"
		// Runner pods kept idle, and at most running at once.
		min: *0 | (int & >=0)
		max: *3 | (int & >=min & >=1)
		// The nodes the runners run on (kubernetes.io/arch): a Mac's VM is arm64.
		arch: *"arm64" | "amd64"
	}

	buildkit: {
		// The layer cache kept across jobs, and what BuildKit prunes it down to, in GiB.
		cache: *60 | (int & >0)
		keep:  *40 | (int & >0 & <=cache)
		// Foreign platforms BuildKit runs build steps for under QEMU emulation (binfmt registered in
		// the cluster's kernel before BuildKit starts). Empty: the node's own platform only.
		emulate: [...("linux/amd64" | "linux/arm64" | "linux/riscv64" | "linux/ppc64le" | "linux/s390x" | "linux/386" | "linux/arm/v7")]
	}

	// Pinned: the charts of GitHub's Actions Runner Controller and the images, by digest.
	versions: {
		charts:      *"0.15.1" | string
		runnerImage: *"ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232" | string
		buildkit:    *"moby/buildkit:v0.34.2@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe" | string
		binfmt:      *"tonistiigi/binfmt:qemu-v10.2.3@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0" | string
	}
}

#DNS: =~"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"

#Colima: {
	// A profile of its own, so a VM someone uses for other work is left alone.
	colima: {
		profile: *"arc" | #DNS
		// The VM's share of the Mac: its CPUs are shared with the host, not reserved.
		cpus:   *6 | (int & >=2)
		memory: *12 | (int & >=4)   // GiB
		disk:   *100 | (int & >=20) // GiB
	}
}

#Context: {
	// A kubeconfig context name, used as it is: runners.ts starts nothing for it.
	context!: string & !=""
}
