# nsx-terrafrom

Terraform for **NSX across a multi-VCF estate** — one Global Manager owning the
federated distributed firewall, 10+ Local Managers owning their own networking,
and every day-to-day change made as reviewed data rather than as an HCL edit or
a click in the NSX UI.

This repository is the **generator and the design**. `scripts/bootstrap.sh`
writes the working tree — modules, stacks, schemas, tooling, CI and worked
example data — into whatever directory you point it at.

```bash
./scripts/bootstrap.sh                  # interactive: pick basic or advanced
./scripts/bootstrap.sh --profile lab    # one command to a running pipeline
```

`--profile lab` writes the tree, starts GitLab and a runner in Docker, creates
the project, pushes, sets the credential variables, records the state address,
initialises the stacks and waits until the pipeline is green. Nothing external
has to exist first. If a stage fails it names the stage and the command that
resumes; every stage is idempotent.

```
 1) Basic deployment      — best practices assumed, four questions
 2) Advanced deployment   — every option asked
 3) Update an existing tree
 4) Add version control and the review pipeline to an existing tree
 5) Dry run               — show what a basic run would write
```

**Basic** asks where to put it, **where the files live and how changes get
reviewed**, which state backend, and whether to include the worked example —
everything else takes the recommended answer. **Advanced** asks about every
flag, including where credentials come from. Either way it prints the equivalent
command line before it writes anything, so one pass teaches you the scripted
form:

```bash
./scripts/bootstrap.sh --dir ~/work/nsx --backend gitlab --git-init
cd ~/work/nsx && make validate              # offline checks, no credentials
```

Any flag on the command line suppresses the menu, so CI is unaffected.

`docs/SETUP.md` walks the whole thing, including the choices you have to make.

> The repository name contains a typo for "terraform". It is reproduced verbatim
> in remotes and CI config; renaming is the owner's call.

## What problem it solves

In an estate of this size the firewall is edited daily, by several people,
across more than ten managers. Doing that through the NSX UI gives you no
review, no history, and no way to answer *why does this rule exist*. Doing it as
hand-written HCL gives you review, but a rule change becomes a code change and
the blast radius of a mistake is a live datacenter.

So rules are **data**:

```yaml
# data/policies/payments.yaml
rules:
  allow-web-to-app:
    sequence_number: 300
    source_groups: [prod-payments-web]
    destination_groups: [prod-payments-app]
    services: [https]
    scope: [prod-payments-app]     # mandatory: bounds where the rule is pushed
    action: ALLOW
```

and nobody writes even that by hand:

```bash
make add-rule POLICY=prod-payments RULE=allow-web-to-app \
  ARGS='--source prod-payments-web --destination prod-payments-app --service https --scope prod-payments-app'
make validate
make plan STACK=global-security SITE=gm1
```

Group membership comes from tags, so it follows the workload instead of being
maintained by hand. Tagging is automated too — either from your provisioning
system or from this repository — so **no part of the daily loop needs the NSX
UI**. That choice is `docs/TAGGING.md`.

## What the generator produces

| | |
|---|---|
| **7 modules** | `dfw-policy`, `group`, `service`, `segment`, `vm-tags`, `tier1`, `tier0`. `for_each` over stable keys, never `count`. |
| **5 stacks** | `global-security`, `local-security`, `local-tags`, `local-network`, `platform`. One state boundary each, instantiated once per manager. |
| **Schemas** | JSON Schema for every data file, plus the tag scope vocabulary. Enforced in CI. |
| **Tooling** | Validation, CI matrix, credential handling, estate import, rule and tag editing, drift reporting. |
| **CI** | Validate on every PR; plan per site from a matrix derived from the inventory. |

It is self-contained: no network, no package install, and no dependency on this
repository once generated. It copies itself and `docs/ARCHITECTURE.md` into the
tree it creates, so that tree can regenerate and update itself.

It is also idempotent and non-destructive — see below.

## A rule change is a merge request

Nobody edits the firewall. They edit a file, and a pipeline turns that into a
plan somebody approves:

```
edit data/policies/payments.yaml
  -> push, open a merge request
  -> VALIDATE  schemas and conventions, offline, no credentials
  -> PLAN      one job per manager, READ-ONLY credentials,
               rendered plan posted onto the merge request
  -> APPROVER  reads the plan, approves
  -> MERGE     to the default branch
  -> APPLY     MANUAL job, protected environment, applies the SAVED plan
```

**The apply never re-plans.** It applies the artifact the approver looked at, so
what was reviewed is what reaches the firewall.

**GitLab is the default**, because it is the only host this script can take all
the way — server, project, runner, CI variables and the approval gate. GitHub
gets complete workflows, but its secrets and environment protection are yours to
set. Local-only writes no pipeline at all and leaves the manual path.

That choice also settles the two things that otherwise need infrastructure
nobody has yet:

- **Credentials** are GitLab CI/CD variables by default. Two NSX accounts, not
  one: a read-only account for plan that every branch can read, and an account
  that can write in **protected** variables only a protected branch can read.
  That split is the security property. HashiCorp Vault is the stronger
  production answer and is one flag away — `--creds vault`, and
  `scripts/vault-up.sh` will run and seed a lab one — but it is not required to
  get started, and nothing is installed unless you ask for it.
- **State** is GitLab-managed Terraform state by default. GitLab provides the
  locking, the encryption at rest and the version history, so there is no object
  store to stand up. S3 with a DynamoDB table (or Terraform 1.10's own
  lockfile), Azure blob and GCS are all supported, and `deploy/state/` contains
  Terraform that creates each one properly — versioned, encrypted, private.

| Choice | Written | Done for you |
|---|---|---|
| **GitLab** *(default)* | `.gitlab-ci.yml` + child pipeline + MR template | remote, and optionally the whole server |
| GitHub | `.github/workflows/{validate,plan,apply}.yml` + PR template | remote only |
| Another git host | both | remote only; location printed |
| Local only | nothing | nothing — `make plan` / `make apply` |

Three ways to turn it on:

```bash
scripts/enable-gitops.sh --remote git@gitlab.example.com:net/nsx.git
scripts/enable-gitops.sh --local-gitlab   # no GitLab? stand one up in Docker
scripts/bootstrap.sh                      # or answer the question at first run
```

`--local-gitlab` runs GitLab CE and a runner in Docker, creates the project,
pushes, registers the runner, and prints the initial root password. A lab
instance, not a production one.

The per-manager jobs come from `inventory/managers.yaml`, so adding an eleventh
Local Manager stays a data change. GitLab and GitHub read the same
`scripts/ci_matrix_lib.py` and cannot drift apart.

Three jobs run outside the review flow: `verify-credentials` checks that each
manager's credentials actually authenticate, `drift` runs on a schedule and
reports what changed outside Terraform, and `state-check` confirms every state
address is still reachable and lockable.

## Dev, UAT and production

The `tier` already recorded against each manager — `prod`, `preprod`, `nonprod`
or `lab` — **is** the environment boundary, and it is load-bearing rather than
descriptive:

- it is part of the state address, so production and non-production state can
  never be the same file
- it names the approval environment, so protecting everything under `nsx/prod/`
  is one rule instead of one per manager
- **a production apply is always manual.** `NSX_APPLY_MODE=auto` applies to
  non-production tiers only; a variable set once in project settings cannot
  remove the human from a change to a production firewall

`--envs prod,preprod` declares which tiers a tree serves, and a manager whose
tier falls outside that set fails `make validate` offline — before the typo can
address state nobody is watching.

## Why the state is split five ways

By **change cadence and blast radius**, not topology — a daily rule edit must
never force Terraform to refresh transport zones.

| Stack | Runs on | Cadence | Blast radius | Approver |
|---|---|---|---|---|
| `global-security` | GM | daily | all sites | security review |
| `local-security` | each LM | weekly | one site | site owner |
| `local-tags` | each LM | daily | the VMs listed | site owner |
| `local-network` | each LM | weekly | one site | network owner |
| `platform` | each LM | rarely | one site, total | change advisory |

Adding an eleventh Local Manager is a data change in `inventory/managers.yaml`,
not a code change: CI derives its run matrix from there.

## Re-running the generator is safe

The case that matters is day two: months in, the tree is full of your work, and
somebody re-runs the generator to pick up an update.

**With no flag, nothing that already exists is ever overwritten.** Differing
files are kept and reported, and the run exits `2`. Missing files are still
added, so this is the safe way to take additions.

**Overwriting takes a flag *and* a typed phrase.** `--force` alone does not do
it — the first file that would be overwritten stops the run and asks you to type
`wipe everything & start fresh` in full. Anything else aborts with nothing
changed. The prompt states whether estate data is in scope.

Three things hold in every mode: it **never deletes**; imported estate recorded
in `data/.import-manifest.json` is **never** overwritten, flag and phrase or not;
and without a terminal an overwrite **aborts** instead of proceeding (pipelines
pass `--confirm 'wipe everything & start fresh'` deliberately).

| Command | Overwrites |
|---|---|
| *(no flag)* | nothing — differing files kept, exit 2 |
| `--force` | generator output only: modules, stacks, scripts, schemas, CI, docs |
| `--force-data` | the above **and** `data/`, `inventory/`, `envs/` |

Details in [`docs/SETUP.md`](docs/SETUP.md#re-running-it-later--day-two).

## Documentation

Two documents live here. The rest are written into the tree the generator
creates, because they describe that tree.

### In this repository

| Document | Read it for |
|---|---|
| **[`README.md`](README.md)** *(this file)* | What this is, what it produces, and current status. Start here. |
| **[`docs/SETUP.md`](docs/SETUP.md)** | Standing up your own, end to end: prerequisites, generating, the decisions that are yours, greenfield vs brownfield, first contact with a manager, daily use, troubleshooting. |
| **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** | The design and the operating rules — 16 sections. The reference, not the tutorial. Copied into every generated tree. |

### Written into the generated tree

| Document | Read it for |
|---|---|
| `README.md` | Orientation for whoever opens that repository. |
| `docs/ARCHITECTURE.md` | The same reference, carried across so its links resolve. |
| `docs/STRUCTURE.md` | What each directory is for, and what must *not* go in it. |
| `docs/TAGGING.md` | Who applies tags — the two variants, the ownership constraint, and how the boundary is enforced. |
| `docs/IMPORT.md` | Adopting an estate that already exists: the tranche workflow. |
| `docs/GITOPS.md` | The review flow end to end, the CI variables, the branch protection it depends on, and what the approver is checking. |
| `deploy/gitlab/README.md` | Running a local GitLab in Docker. |
| `modules/*/README.md` | Input shape and gotchas, one per module. |
| `stacks/*/README.md` | Cadence, blast radius, approver, and what the stack consumes. |
| `inventory/README.md` | How the manager registry drives everything else. |

### Where to start, by question

| You want to | Go to |
|---|---|
| Understand what this is | this README |
| Stand one up | `docs/SETUP.md` |
| Know why it is built this way | `docs/ARCHITECTURE.md` §1–§9 |
| Avoid breaking a live firewall | `docs/ARCHITECTURE.md` §2 — ten failure modes |
| Add a firewall rule | `docs/ARCHITECTURE.md` §8, §10 |
| Decide who tags workloads | `docs/TAGGING.md` |
| Choose a state backend | `docs/SETUP.md` §2.1 |
| Get changes reviewed before they apply | `docs/SETUP.md` §2.2, then `docs/GITOPS.md` |
| Adopt an existing estate | `docs/IMPORT.md` |
| Find a command | `docs/ARCHITECTURE.md` §16 — every command that exists |
| Know what is still undecided | `docs/ARCHITECTURE.md` §14 |

## Repository contents

| Path | What it is |
|---|---|
| `scripts/bootstrap.sh` | The generator. Every file it writes is embedded in it. |
| `scripts/bootstrap.sh --profile lab` | The same, plus standing the lab up and proving the pipeline runs. |
| `docs/ARCHITECTURE.md` | The design, the conventions, and the operating rules. |
| `docs/SETUP.md` | How to stand up your own, and the variants on offer. |
| `README.md` | This file. |
| `LICENSE` | Apache-2.0. |

## Status — read before acting

**The scaffold exists and has never touched a live manager.** What has been
verified, offline:

- `terraform fmt -check` clean; all five stacks pass `terraform validate`
  against the real `vmware/nsxt` provider (3.12.0, resolved from `~> 3.9`).
- Data wiring evaluated with `terraform console`; group and policy filtering by
  owner and site confirmed.
- `scripts/validate-data.py` passes on the example data and was tested against
  deliberately planted defects.
- The generator reproduces itself byte-for-byte.

What that does **not** cover:

- **No `terraform plan` has run against an NSX manager.** Provider schema
  validity is not API validity.
- **No GitLab has been started from this environment.** `--profile lab` is
  exercised offline — its stages, guards and dry-run behaviour are covered by
  `make selftest` — but the Docker path itself has not been run end to end.
- **All example data describes no real site.** Replace it, or generate with
  `--no-examples`.

The state backend is no longer a placeholder unless you ask for one: any run
with a GitLab defaults to GitLab-managed state, and `backend "local"` is
reachable only through `--backend local`, which `scripts/tf.sh` still refuses to
apply through.

`docs/ARCHITECTURE.md` section 14 lists every decision deliberately left to the
owner. Section 2 — ten things that will break this repository — is worth reading
before the first change.
