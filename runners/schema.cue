// What a runners setup (README.md) is, written as data: where the cluster is, whose GitHub jobs it
// takes, its runner scale sets, the BuildKit they share and the secret they register with (named,
// never its values); or, on a `host` setup, GitHub's runner itself on this machine, each runner a
// launchd agent on macOS or a systemd unit on Linux. A setup is one field of `setups` (setups.cue); host.cue renders it into what
// runners.ts applies.
package runners

import "list"

setups: [Name=string]: #Setup & {name: Name}

#Setup: {
	name!: =~"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"

	// The cluster the controller, BuildKit and the runners run in: a Colima k3s VM this machine
	// starts, or a cluster a kubeconfig context already reaches (a remote k3s, a cloud one). Or
	// `host`: no cluster, the runners are this Mac's own processes (hostRunners).
	cluster: #Colima | #Context | #Host

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

	// A host setup's runners: GitHub's actions/runner for the machine's platform, installed under
	// the home and run as a service (hostService), so it comes back at every login or boot. Each
	// takes one job at a time, on the machine itself (its tools, its caches, no container). What
	// runs-on says: self-hosted, its OS and arch (GitHub's own labels: macOS or Linux, ARM64 or X64)
	// and the runner's `labels`.
	hostRunners: [Name=#DNS]: {
		if github.kind == "user" {repo!: string}
		repo?: =~"^[A-Za-z0-9_.-]+$"
		labels: *[Name] | [...=~"^[A-Za-z0-9._-]+$"]
		// The runner's folder, under the home; its jobs' checkouts go in `work`, under it.
		dir:  *"actions-runners/\(Name)" | (string & !~"^/")
		work: *"_work" | (string & !~"^/")
		// The PATH its jobs run with (config.sh records it in .path), ~ the home: not the PATH of
		// whoever ran apply.
		path: *_defaultPath | [...(=~"^(/|~/)")]
		// The service's CPU priority (launchd's and systemd's Nice): its jobs yield to the person's own work.
		nice: *10 | (int & >=0 & <=20)
	}
	// What runs a host runner: a launchd agent (macOS, in the person's session) or a systemd unit
	// (Linux, the system's, as GitHub's svc.sh installs it, run as the person). By the host's OS.
	if cluster.host != _|_ {
		hostService: *{macos: "launchd", linux: "systemd"}[cluster.host.os] | "launchd" | "systemd"
		if cluster.host.os == "linux" {hostService: "systemd"}
		if cluster.host.os == "macos" {hostService: "launchd"}
	}

	// The jobs' default PATH: Homebrew's on a Mac, none on Linux.
	_os: [if cluster.host != _|_ {cluster.host.os}, "macos"][0]
	_defaultPath: {
		macos: ["~/.deno/bin", "~/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
		linux: ["~/.deno/bin", "~/.local/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
	}[_os]

	// Where an amd64 image (Cloud Run's) builds when the runners' own platform is not amd64: in
	// Cloud Build (`gcloud builds submit`), under QEMU in the setup's BuildKit (`emulate`, which
	// then lists linux/amd64), or nowhere (`none`: the setup builds its own platform only). Every
	// runner's jobs read it as PRONTO_AMD64. A Colima VM shares the Mac's cores with everything else
	// it runs, and QEMU starves them, so it never emulates; a host setup has no BuildKit to emulate
	// with, so it builds in Cloud Build unless told none. By default: Cloud Build there, and on a
	// cluster, emulation when its BuildKit emulates amd64, else none.
	amd64: *_amd64 | "cloud-build" | "emulate" | "none"
	_amd64: [
		if cluster.colima != _|_ || cluster.host != _|_ {"cloud-build"},
		if list.Contains(buildkit.emulate, "linux/amd64") {"emulate"},
		"none",
	][0]
	if amd64 == "emulate" {
		_emulatesOnACluster: (cluster.colima == _|_ && cluster.host == _|_) & true
		_emulatesAmd64:      list.Contains(buildkit.emulate, "linux/amd64") & true
	}

	// A setup is one or the other: host runners on this Mac, or scale sets on a cluster.
	if cluster.host == _|_ {
		hostRunners: [string]: _|_
	}
	if cluster.host != _|_ {
		scaleSets: [string]: _|_
	}

	buildkit: {
		// The layer cache kept across jobs, and what BuildKit prunes it down to, in GiB.
		cache: *60 | (int & >0)
		keep:  *40 | (int & >0 & <=cache)
		// Foreign platforms BuildKit runs build steps for under QEMU emulation (binfmt registered in
		// the cluster's kernel before BuildKit starts). Empty: the node's own platform only.
		emulate: [...("linux/amd64" | "linux/arm64" | "linux/riscv64" | "linux/ppc64le" | "linux/s390x" | "linux/386" | "linux/arm/v7")]
	}
	// A Colima VM shares the machine's cores with everything else it runs, and QEMU starves them:
	// its amd64 images build in Cloud Build (`gcloud builds submit`) instead.
	if cluster.colima != _|_ {
		buildkit: emulate: []
	}

	// Pinned: the charts of GitHub's Actions Runner Controller and the images, by digest.
	versions: {
		charts:      *"0.15.1" | string
		runnerImage: *"ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232" | string
		buildkit:    *"moby/buildkit:v0.34.2@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe" | string
		binfmt:      *"tonistiigi/binfmt:qemu-v10.2.3@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0" | string
		// A host runner's first install; it updates itself afterwards, as GitHub requires. One
		// tarball per platform, each pinned by its sha256 (the release's notes list them).
		hostRunner: {
			version: *"2.338.2" | string
			sha256: [#Platform]: =~"^[0-9a-f]{64}$"
			sha256: {
				"osx-arm64":   *"25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388" | _
				"linux-x64":   *"baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40" | _
				"linux-arm64": *"670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945" | _
			}
		}
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

#Host: {
	// This machine: nothing to start, no cluster. A Mac (osx-arm64) unless it says Linux, on arm64
	// or x64 (GitHub's runner ships no macOS x64 build we pin).
	host: {
		os:   *"macos" | "linux"
		arch: *"arm64" | "x64"
		if os == "macos" {arch: "arm64"}
	}
}

// The runner tarball's platform, as actions/runner names its releases.
#Platform: "osx-arm64" | "linux-x64" | "linux-arm64"

#Context: {
	// A kubeconfig context name, used as it is: runners.ts starts nothing for it.
	context!: string & !=""
}
