# pronto-infra

An operator's Google Cloud state, kept in CUE and applied by OpenTofu with the operator's own
`gcloud` login. The state says what a project holds (its services, IAM, service accounts,
Artifact Registry repositories, buckets, secrets, Cloud Run jobs and services, databases);
`cue export` turns it into OpenTofu JSON; two verbs plan and apply it. Nothing about any one
account is in this plugin: projects, billing and members are all the operator's own state.

```text
infra/
  schema.cue    #State, #Project, #Backend: what the state may say, and what it refuses
  tofu.cue      #Plan: the state and a backend in, OpenTofu JSON (plan.tofu) out
  host.cue      the files written into the operator's folder (#Host)
  say.cue.txt   the verbs written there: setup, generate, lint, verify@infra, release@infra
  export/       the host's files by tag, for bin/pronto-infra
  tests.cue     the schema's constraints and the export's output, checked by cue vet
```

## Set up a folder

In a repository of your own (a pronto app's, or one for infra alone):

```sh
<this repo>/bin/pronto-infra infra example.com/infra@v0 my-org-infra-tfstate my-admin-project
cd infra
cue mod get github.com/bsoneca/pronto-plugins@v0     # the schema and the export, imported
./saytw --script tools.nu mise trust .mise.toml
./saytw --script tools.nu mise install
gcloud auth login                                     # in a terminal of your own
./saytw setup                                         # the state bucket, then tofu init
```

The arguments are the folder, its CUE module path, the bucket OpenTofu keeps its own state in
and the project that holds the bucket. `setup` makes the bucket (versioned, uniform access,
public access prevented) when it is not there. `bin/pronto-infra` writes `state.cue`, `cue.mod/module.cue` and
the `saytw` launcher once and leaves them yours; it rewrites `.say.cue`, `.mise.toml` and
`.gitignore` each run.

## The state

`state.cue` is `plan: infra.#Plan & {backend: {...}, state: projects: {...}}`;
[`examples/infra/state.cue`](../examples/infra/state.cue) is a whole one, with invented
projects. A project says its `id`, its `billing` account and the rest of what it holds.

| Field | |
| --- | --- |
| `adoptAll` | OpenTofu applies everything the project says. Default `false` |
| `adopt` | while the rest is a draft: only these, by kind and name (`adopt: iam: ["roles/viewer"]`) |
| `create` | OpenTofu makes the project too, and everything in it new, with nothing to import |
| `iam` | authoritative for each role named: its members are exactly these; roles not named are left as they are |
| `members` | single grants of a role whose other members someone else keeps |
| `secrets` | the secret and who may read or add versions; a value is never written, `source` says who puts it. `file` adds a file of your repository, beside the state folder, as a new version whenever it changes |
| `fresh` | of what is adopted, what does not exist yet, by kind and name: made, never imported (one that is not there cannot be imported). A binding has its own entry, so an existing parent can get a new one: `serviceAccountIam: ["account/role"]`, `repositoryIam: ["repository/role"]`, `bucketIam: ["bucket/role"]`, `runServiceIam: ["service"]`. Buckets and secrets say so with `made`, and a secret's grants with `newGrants` |
| `runJobs` | the image is the one it is made with; OpenTofu leaves a later image as it finds it |

What the project already has is imported, never made again, so a first plan of a live project
shows only the difference between it and the state. `cue vet` refuses a project id, a billing
account, a member, a bucket name or an API that Google would refuse, and a role in both `iam` and `members`, and a bucket granted to `allUsers` or
`allAuthenticatedUsers` in any role that gives no reason.

## The verbs

All run as your own `gcloud` login (a short-lived token handed to OpenTofu), never a key.

```sh
./saytw generate       # tofu/main.tf.json from the state
./saytw lint           # cue vet, cue fmt, tofu validate
./saytw verify@infra   # the plan: read-only, exit 2 when applying would change something
./saytw release@infra  # applies the plan verify@infra kept, and nothing else
```

`verify@infra` removes the plan it kept before, vets the whole state (`cue vet -c`, which an
export alone skips), exports it afresh and plans into a temporary file. It reads that plan with
`tofu show -json`, and keeps it as `infra.tfplan` only when it reads as a plan and deletes
nothing; on any failure the temporary plan is removed, so a failed verify leaves nothing to
release. A plan that deletes anything is refused unless `INFRA_ALLOW_DESTROY=1` (exactly) is set
for that run: a resource dropped from the state is not a reason to delete it from the project.
`release@infra` reads the kept plan again by the same rule before it applies, refuses when none
was kept, and removes the plan once it is applied. Declared accounts, repositories, secrets and
buckets also carry `prevent_destroy`. A secret's `file` is added as a new version before the old
one is left behind, and a service reads that version, so a change to the file rolls a new
revision.

## Checks

```sh
./saytw --script tools.nu cue vet -c ./infra
./saytw --script tools.nu cue vet -c ./examples/infra
./saytw --script tools.nu cue vet -c -t module=example.com/infra@v0 -t bucket=my-org-infra-tfstate -t project=my-admin-project ./infra/export
```
