// The Google Cloud state an operator keeps in CUE (README.md): the projects, and in each what
// OpenTofu applies. Nothing about any one account is written here; the operator's own state
// file says it (`plan: #Plan & {...}`), and tofu.cue exports it as OpenTofu JSON.
package infra

#Member: =~"^((user|serviceAccount|group|domain|principalSet|principal):.+|allUsers|allAuthenticatedUsers)$"

// Members are a set, so that the same grant from two sources unifies into one.
#Members: [#Member]: true

#ProjectID:  =~"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"
#Billing:    =~"^billingAccounts/[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$"
#BucketName: string & =~"^[a-z0-9][a-z0-9._-]{2,61}[a-z0-9]$"

// Where OpenTofu keeps its own state: a bucket `setup` makes the first time (say.cue.txt).
#Backend: {
	bucket!:  #BucketName
	project!: #ProjectID
	location: *"us-central1" | string
	prefix:   *"infra" | string
}

#State: {
	projects: [ID=string]: #Project & {id: ID}
}

#Project: P={
	id: #ProjectID
	// Its display name, the id unless it was made with another.
	name:    *id | string
	billing: #Billing

	// Enabled services. The ones a project is created with are listed so that plan does not
	// call them drift; retiring one is a decision of its own.
	apis: [=~"^[a-z0-9-]+\\.googleapis\\.com$"]: true

	// Project IAM, authoritative for each role named here: the members of a role named are
	// exactly these, and a role not named is left as it is.
	iam: [Role=string]: #Members
	// Single grants of a role whose other members someone else keeps: each is added beside
	// them, never in their place.
	members: [Role=string]: #Members
	// A role is authoritative or additive, never both: the binding would remove what the grant adds.
	for r, _ in members if iam[r] != _|_ {
		"\(r) is in both iam and members": _|_
	}

	serviceAccounts: [Name=string]: #ServiceAccount & {email: "\(Name)@\(P.id).iam.gserviceaccount.com"}
	runJobs: [Name=string]:     #RunJob
	runServices: [Name=string]: #RunService
	// Databases on an instance another owner keeps, by instance and name.
	databases: [Instance=string]: [Name=string]: true
	repositories: [Name=string]: #Repository
	buckets: [Name=#BucketName]: #Bucket
	secrets: [Name=string]:      #Secret

	// What OpenTofu applies: the whole project, or, while the rest is still a draft the live
	// project has not been checked against, these resources by kind and name (a role for iam;
	// a repository's name for repositoryIam, its grants without the repository itself).
	// Everything else here is description alone until it is adopted.
	adoptAll: *false | bool
	adopt: [#Adoptable]: [...string]
	// Of what is adopted, what is not there yet, by kind and name: it is made, never imported
	// (an import of a binding that does not exist fails). Buckets and secrets say so with `made`.
	fresh: [#Adoptable]: [...string]
	// A project this state makes rather than finds: OpenTofu creates it and everything in it,
	// with nothing to import, so it is adopted whole.
	create: *false | bool
	if create {adoptAll: true}
}

#Adoptable: "apis" | "iam" | "members" | "serviceAccounts" | "repositories" | "repositoryIam" | "buckets" | "secrets" | "runJobs" | "runServices" | "databases"

// A Cloud Run job. Its image is the one it is made with: what runs it later may set another,
// so OpenTofu leaves the image as it finds it.
#RunJob: {
	location: string
	image:    string
	command: [...string]
	args: [...string]
	serviceAccount: string
	cpu:            string
	memory:         string
	timeout:        =~"^[0-9]+s$"
	maxRetries:     int & >=0
	tasks:          *1 | int & >0
}

// A Cloud Run service whose image is chosen here, not built by a release: applying it is how it
// is released. Its secrets are env (name to secret) and files (a mount path's directory to the
// secret and the file name it is read as); a secret this state keeps a version of
// (#Secret.file) is read at that version, so a change to the file rolls a new revision.
#RunService: {
	location: string
	image:    string
	args: [...string]
	port:           int
	serviceAccount: string
	cpu:            string
	memory:         string
	timeout:        =~"^[0-9]+s$"
	maxInstances:   int & >0
	env: [string]:           string
	secretEnv: [Var=string]: string
	secretFiles: [Dir=string]: {secret: string, path: string}
	sqlInstances: [...string]
	// Who may call it: roles/run.invoker, authoritative.
	invokers: #Members
}

#ServiceAccount: {
	email:       string
	displayName: string
	// Who may act as it.
	iam: [Role=string]: #Members
}

#Repository: {
	location: string
	format:   "DOCKER"
	iam: [Role=string]: #Members
}

#Bucket: {
	location:         string
	uniformAccess:    true
	publicPrevention: "enforced" | "inherited"
	versioning:       *false | bool
	// Objects deleted this many days after they are written.
	deleteAfterDays?: int & >0
	iam: [Role=string]: #Members
	// Made here rather than adopted: it was not there to import.
	made: *false | bool
	// A bucket any role is granted to everyone (allUsers, allAuthenticatedUsers) says why.
	public?: string
	if len([for _, ms in iam for m, _ in ms if m == "allUsers" || m == "allAuthenticatedUsers" {m}]) > 0 {public!: string & !=""}
}

#Secret: {
	// Who puts its versions, and how. A value is never here.
	source:    string & !=""
	accessors: #Members
	// Who adds its versions themselves (a service that learns the value).
	adders: *{} | #Members
	// Made here rather than adopted: it was not there to import.
	made: *false | bool
	// Its grants are new, though the secret was there: nothing to import for them.
	newGrants: *false | bool
	// A secret whose one value is a file of the operator's repository, beside the state
	// folder: applying adds the file as a new version whenever it changes.
	file?: string
}
