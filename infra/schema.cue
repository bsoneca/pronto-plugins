// The Google Cloud state an operator keeps in CUE (README.md): the projects, and in each what
// OpenTofu applies. Nothing about any one account is written here; the operator's own state
// file says it (`plan: #Plan & {...}`), and tofu.cue exports it as OpenTofu JSON.
package infra

import "list"

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
	// Firebase and Identity Platform, and the budgets that watch the project's spend. Their APIs
	// are called with this project as the quota project (tofu.cue), as Google asks of a user's login.
	apiKeys: [Key=string]: #ApiKey
	identityPlatform?: #IdentityPlatform
	budgets: [Name=string]: #Budget
	// A budget there already is imported by its id.
	for nm, _ in budgets if !list.Contains(*fresh["budgets"] | [], nm) {budgets: (nm): id!: _}
	hostingSites: [Site=string]: #HostingSite

	// What OpenTofu applies: the whole project, or, while the rest is still a draft the live
	// project has not been checked against, these resources by kind and name (a role for iam;
	// a repository's name for repositoryIam, its grants without the repository itself).
	// Everything else here is description alone until it is adopted.
	adoptAll: *false | bool
	adopt: [#Adoptable]: [...string]
	// Of what is adopted, what is not there yet, by kind and name: it is made, never imported
	// (an import of one that does not exist fails). A binding is its own entry, so an existing
	// parent can get a new binding: a role for iam and members; `account/role`, `repository/role`
	// and `bucket/role` for those parents' grants; a service's name for its invokers. Buckets
	// and secrets, and the grants of a secret, say so with `made` and `newGrants` instead.
	fresh: [#Fresh]: [...string]
	// Of a project this state makes (create), what someone else made in it first, by kind and
	// name: it is imported, as in a project the state finds. A grant is `role/member`. A budget
	// with an id is always imported: the id is Google's, so it is there.
	found: [#Found]: [...string]
	// A project has one Identity Platform config, adopted by this name alone.
	adopt: identityPlatform?: [..."config"]
	// A project this state makes rather than finds: OpenTofu creates it and everything in it,
	// with nothing to import, so it is adopted whole.
	create: *false | bool
	if create {adoptAll: true}
}

#Fresh: "apis" | "iam" | "members" | "serviceAccounts" | "serviceAccountIam" | "repositories" | "repositoryIam" | "bucketIam" | "runJobs" | "runServices" | "runServiceIam" | "databases" | "apiKeys" | "budgets" | "hostingSites"

// identityPlatform is adopted by naming "config": a project has one.
#Adoptable: "apis" | "iam" | "members" | "serviceAccounts" | "repositories" | "repositoryIam" | "buckets" | "secrets" | "runJobs" | "runServices" | "databases" | "apiKeys" | "identityPlatform" | "budgets" | "hostingSites"

#Found: "serviceAccounts" | "members"

// An API key, by its id (the key's uid, as `gcloud services api-keys list` shows it). The key's
// string is Google's and never here; what it may call, and from where, is.
#ApiKey: {
	displayName: string
	// The services it may call, as api targets.
	services: [...=~"^[a-z0-9-]+\\.googleapis\\.com$"]
	// A browser key's referrers, in the order the key keeps them.
	referrers: [...string & !=""]
}

// Identity Platform's project config. Only what this schema names is OpenTofu's; the rest of the
// config (its templates, hash, reCAPTCHA) is left as it is, since the provider sends a field only
// when it changes.
#IdentityPlatform: {
	// Sign-in by phone number, and by e-mail (with a password, when it is on).
	phone: *false | bool
	email: *false | bool
	// SMS is sent only to these regions (ISO 3166 alpha-2), when any are named.
	smsRegions: [...=~"^[A-Z]{2}$"]
	// The domains a sign-in may start from, in the order the config keeps them.
	authorizedDomains: [...string & !=""]
	// Blocking functions, by event (beforeSendSms, beforeCreate, beforeSignIn): the URI each calls.
	// None is handed the user's tokens.
	blockingFunctions: [Event=string]: =~"^https://"
}

// A budget on the project's billing account, by a name of the state's own. It watches what its
// filter names; its alerts go to the billing account's admins.
#Budget: {
	// Google's id for it, which an import needs: a budget made here (fresh) has none until it is.
	id?:         =~"^[0-9a-f-]+$"
	displayName: string & !=""
	amount: {units: int & >0, currency: =~"^[A-Z]{3}$"}
	period:               *"MONTH" | "QUARTER" | "YEAR"
	creditTypesTreatment: *"INCLUDE_ALL_CREDITS" | "EXCLUDE_ALL_CREDITS"
	// What it watches: projects by number, and services by their billing id.
	projects: [...=~"^projects/[0-9]+$"]
	services: [...=~"^services/[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$"]
	// Alerts at these fractions of the amount, of what is spent and of what is forecast.
	current: [...number & >0]
	forecasted: [...number & >0]
}

// A Firebase Hosting site, by its id (its default address is <id>.web.app). What it serves is
// deployed by its app (firebase deploy), not here.
#HostingSite: {}

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
