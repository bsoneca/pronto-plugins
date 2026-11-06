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
	// Users of such an instance, by instance and name, each with a password OpenTofu makes and
	// puts in the secrets named (never in this state, always in its own).
	sqlUsers: [Instance=string]: [Name=string]: #SqlUser
	// The automated backups of a Cloud SQL instance another owner makes and keeps (#SqlBackups).
	sqlBackups: [Instance=string]: #SqlBackups
	repositories: [Name=string]:   #Repository
	buckets: [Name=#BucketName]:   #Bucket
	secrets: [Name=string]:        #Secret
	// Firebase and Identity Platform, and the budgets that watch the project's spend. Their APIs
	// are called with this project as the quota project (tofu.cue), as Google asks of a user's login.
	apiKeys: [Key=string]: #ApiKey
	identityPlatform?: #IdentityPlatform
	budgets: [Name=string]: #Budget
	// A budget there already is imported by its id.
	for nm, _ in budgets if !list.Contains(*fresh["budgets"] | [], nm) {budgets: (nm): id!: _}
	hostingSites: [Site=string]: #HostingSite
	// Workload identity pools, by id, each with its OIDC providers: made here, never imported (an
	// existing pool, such as GitHub's, is simply not declared, and so never touched).
	workloadIdentityPools: [Pool=#WifId]: #WorkloadIdentityPool
	// Cloud Monitoring: where an alert goes, by a name of your own, and PromQL alerting policies
	// a plugin generates into a file (pronto-journeys' observability/journeys.alerts.json), each
	// sent to the channels named. Both are made here, never imported: a policy is the file's,
	// and a change to the file is a change of the policies at the next apply.
	notificationChannels: [Name=string]: #NotificationChannel
	alertPolicies: [Name=string]:        #AlertPolicies
	for nm, a in alertPolicies for c in a.channels if notificationChannels[c] == _|_ {
		"alert policies \(nm) name no channel \(c)": _|_
	}

	// What OpenTofu applies: the whole project, or, while the rest is still a draft the live
	// project has not been checked against, these resources by kind and name (a role for iam;
	// a repository's name for repositoryIam, its grants without the repository itself).
	// Everything else here is description alone until it is adopted.
	adoptAll: *false | bool
	adopt: [#Adoptable]: [...string]
	// Of what is adopted, what is not there yet, by kind and name: it is made, never imported
	// (an import of one that does not exist fails). A binding is its own entry, so an existing
	// parent can get a new binding: a role for iam, and a role or `role/member` for members, `instance/name` for databases; `account/role`, `repository/role`
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

#Fresh: "apis" | "iam" | "members" | "serviceAccounts" | "serviceAccountIam" | "repositories" | "repositoryIam" | "bucketIam" | "runJobs" | "runServices" | "runServiceIam" | "databases" | "sqlUsers" | "apiKeys" | "budgets" | "hostingSites"

// identityPlatform is adopted by naming "config": a project has one.
#Adoptable: "apis" | "iam" | "members" | "serviceAccounts" | "repositories" | "repositoryIam" | "buckets" | "secrets" | "runJobs" | "runServices" | "databases" | "sqlUsers" | "sqlBackups" | "apiKeys" | "identityPlatform" | "budgets" | "hostingSites" | "notificationChannels" | "alertPolicies" | "workloadIdentityPools"

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

// A workload identity pool and its OIDC providers, by a name of your own. A provider whose issuer
// is not public (a k3s cluster's) carries its keys: `jwks` is the JWKS as JSON text, uploaded as
// jwks_json, and Google never fetches the issuer. Grant on a service account to
// principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<pool>/subject/<sub>
// through the iam kinds.
// Google's id rule for a pool and a provider: 4 to 32 of a-z, 0-9 and -, not starting with gcp-.
#WifId: =~"^[a-z0-9][a-z0-9-]{2,30}[a-z0-9]$" & !~"^gcp-"

#WorkloadIdentityPool: {
	displayName?: string
	providers: [Name=#WifId]: #WorkloadIdentityProvider
}

#WorkloadIdentityProvider: {
	issuer!: =~"^https://"
	// The JWKS as JSON text; absent, Google reads the issuer's own.
	jwks?: string & !=""
	allowedAudiences: [...string & !=""]
	mapping: {"google.subject"!: string, [string]: string}
	// A CEL condition on the token's claims.
	condition?: string & !=""
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
	// Instances kept running with no request, and whether the CPU is held back between requests
	// (the default) or kept (false): a service that works between requests, such as one scraped for
	// metrics, is billed by the instance instead.
	minInstances: *0 | int & >=0
	cpuIdle:      *true | bool
	// Requests one instance serves at once (Cloud Run requires 1 where the instance has less than
	// one CPU in all); absent, Cloud Run's own.
	concurrency?: int & >=1
	// A custom domain mapped to the service, made here and never imported (its DNS record is the
	// registrar's): a mapping that exists already is the registrar's to move.
	domain?: =~"^[a-z0-9.-]+$"
	env: [string]:           string
	secretEnv: [Var=string]: string
	secretFiles: [Dir=string]: {secret: string, path: string}
	sqlInstances: [...string]
	// Containers beside the one serving the port, each by its name: a proxy the server reaches on
	// localhost, say. With any, every container is named, the serving one by the service's name.
	sidecars: [Name=string]: {
		image: string
		args: [...string]
		cpu:    *"500m" | string
		memory: *"256Mi" | string
		env: [string]: string
		secretFiles: [Dir=string]: {secret: string, path: string}
	}
	// Who may call it: roles/run.invoker, authoritative.
	invokers: #Members
}

// A user of a Cloud SQL instance. OpenTofu makes its password (alphanumeric, 32 characters) and
// writes it as a version of `password`, and, if `url` is named, as the postgres URL of `database`
// over the instance's socket as a Cloud Run service reaches it (`query`, if any, is added to it:
// "&options=-c%20role%3Dx"). Both are secrets of this project, declared like any (made: true).
// Cloud SQL puts a user made through its API in cloudsqlsuperuser: what the user may do is the
// database's to narrow.
#SqlUser: {
	password!: string
	url?:      string
	database:  string
	region:    *"us-central1" | string
	query:     *"" | =~"^&"
}

// The automated backups of a Cloud SQL instance someone else makes and keeps (a release engine):
// OpenTofu imports the instance and holds its backup configuration alone. Every other setting is
// ignored, so a tier or flags its owner changes are never drift, and the instance is never
// destroyed or replaced from here. `databaseVersion` and `tier` are the instance's own, which the
// provider requires; this state never changes them.
//
// Turning point-in-time recovery on or off restarts the instance (Cloud SQL's instance settings):
// apply such a change at a quiet hour. Backups alone restart nothing.
#SqlBackups: {
	region:          *"us-central1" | string
	databaseVersion: =~"^POSTGRES_[0-9]+$"
	tier:            string
	// When the daily backup starts, in UTC (HH:00): Cloud SQL takes it within the four hours after.
	startTime: =~"^([01][0-9]|2[0-3]):00$"
	// How many daily backups are kept.
	retainedBackups: *7 | int & >=1 & <=365
	// Point-in-time recovery, and the days of transaction logs it keeps (1 to 7 on Enterprise).
	pointInTimeRecovery: *true | bool
	transactionLogDays:  *3 | int & >=1 & <=7
}

// A Cloud Monitoring notification channel: mail to one address.
#NotificationChannel: {
	email!: =~"^[^@\\s]+@[^@\\s]+$"
}

// PromQL alerting policies, one per entry of a JSON file of the operator's repository, beside the
// state folder (as #Secret.file): a list of {name, displayName, expr, duration, severity
// ("page" is CRITICAL, any other WARNING), documentation, labels, and optionally interval, the
// evaluation interval, 60s by default}, which is what pronto-journeys writes. Each goes to every channel named.
#AlertPolicies: {
	file!: string & =~"\\.json$"
	channels: [...string]
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
	// A secret whose one value is this text, written by the state itself (a configuration file
	// built from the state's other facts): a new version whenever the text changes.
	text?: string
	// A secret whose one value OpenTofu makes at random (alphanumeric, 48 characters) the first
	// time and keeps: a key nobody needs to know.
	random: *false | bool
	// A secret the operator puts the value of, which a service reading it needs to exist before
	// it does: this text is its first version, made once and never changed again (the operator's
	// versions follow it, and readers take the latest).
	placeholder?: string
	// A secret has one source of value.
	if (file != _|_ && text != _|_) || (random && (file != _|_ || text != _|_)) || (placeholder != _|_ && (file != _|_ || text != _|_ || random)) {
		"a secret has one source of value": _|_
	}
}
