# Setting up your own

`scripts/bootstrap.sh` writes a complete NSX Terraform repository into whatever
directory you point it at. This document covers the run, the decisions it
deliberately leaves to you, and the variants it supports.

Nothing here touches a live NSX manager. Everything up to "First contact with a
manager" is offline.

---

## 0. What you need

```bash
bash          # 4.x or later
coreutils
python3       # 3.9+. PyYAML optional — there is a fallback parser.
terraform     # 1.9+
git
```

`make preflight` in the generated tree reports what is missing. The generator
itself needs only bash and coreutils: no network, no package install, no access
back to this repository.

---

## 1. Generate

```bash
git clone https://github.com/sampath9966/nsx-terrafrom
./nsx-terrafrom/scripts/bootstrap.sh
```

With no arguments it asks what you want:

```
 1) Basic deployment      — best practices assumed, four questions
 2) Advanced deployment   — every option asked
 3) Update an existing tree
 4) Add version control and the review pipeline to an existing tree
 5) Dry run               — show what a basic run would write
 6) Help                  — list every flag
 7) Quit
```

- **Basic** asks four things: the directory, **where the files live and how
  changes get reviewed**, the state backend, and whether to include the worked
  example data. Everything else takes the recommended answer — `git init` on a
  tree that is not already one, and never overwrite.
- **Advanced** asks about every flag, including what the run is allowed to
  overwrite and whether to dry-run first.
- **Update an existing tree** is the day-two path: it keeps the backend the tree
  already uses, never re-seeds example data, and offers a dry run first.
- **Add version control and the review pipeline** is the migration path for a
  tree set up without either.

They print the equivalent command line before writing anything, so a single pass
through the menu gives you the scripted form to put in a runbook.

Everything is also available directly, and **any flag suppresses the menu** —
which is what keeps CI working:

```bash
./nsx-terrafrom/scripts/bootstrap.sh --dir ~/work/nsx-estate --backend gitlab
./scripts/bootstrap.sh --dry-run          # report every file, write nothing
./scripts/bootstrap.sh --interactive      # force the menu anyway
./scripts/bootstrap.sh --no-interactive   # never prompt, even with a terminal
```

### Where it goes — three shapes

| You want | Do this |
|---|---|
| A fresh repository of your own | `--dir ~/work/nsx-estate --git-init`, then push it to your own remote. **The usual choice.** |
| To build on top of this one | Run it in place, in a clone: `./scripts/bootstrap.sh`. Generator and generated tree share a history. |
| To evaluate first | `--dir /tmp/try --dry-run`, then without `--dry-run`. Throw it away after. |

The generator copies itself and `docs/ARCHITECTURE.md` into the tree it creates,
so the result is standalone: it can regenerate and update itself with no link
back to here.

### With or without the worked example

The default ships realistic example content — 4 managers, 10 groups, 4 policy
files, a site's network and platform, 2 tagged VMs — describing **no real
site**. It exists so `make validate` and `terraform validate` have something to
chew on, and so you can see the intended shape of each file.

```bash
./scripts/bootstrap.sh --dir PATH                  # with examples (recommended first time)
./scripts/bootstrap.sh --dir PATH --no-examples    # structure and tooling only
```

With examples, replace `inventory/managers.yaml` and everything under `data/`
before you go near a manager. The example inventory uses `gm1`, `lon1`, `nyc1`,
`fra1` — if any of those happen to be your real site ids, be especially careful.

### Re-running it later — day two

This is the case that matters. Six months in, the tree is full of your work and
somebody re-runs the generator to pick up an update. That must not be able to
revert anything.

**With no flag, nothing that already exists is ever overwritten.** A file whose
content differs is kept, reported, and the run exits `2`. New files are still
added, so this is the safe way to pick up additions.

```bash
./scripts/bootstrap.sh                  # add what is missing, touch nothing else
./scripts/bootstrap.sh --dry-run        # report only
```

**Overwriting takes a flag *and* a typed phrase.** The flag alone is not enough:
the first file that would actually be overwritten stops the run and asks.

```
-------------------------------------------------------------------
About to OVERWRITE files that already exist and differ from what this
script generates. First one found: modules/group/main.tf

Scope: Regenerated files only — modules, stacks, scripts, schemas, CI, docs.
       Estate data in data/, inventory/ and envs/ will NOT be touched.

This cannot be undone by re-running the script. If the tree is a git
working copy, commit or stash first — that is your undo.
-------------------------------------------------------------------

Type exactly this phrase to continue, or anything else to abort:
  wipe everything & start fresh
>
```

Answer once and it covers the rest of that run. Anything other than the exact
phrase aborts with nothing overwritten. The prompt names estate data explicitly
when `--force-data` widened the scope to it.

| Command | Overwrites |
|---|---|
| *(no flag)* | nothing — differing files kept, exit 2 |
| `--force` | the generator's own output: modules, stacks, scripts, schemas, CI, docs. **Never** `data/`, `inventory/`, `envs/` |
| `--force-data` | the above **and** estate data. Still refuses anything in `data/.import-manifest.json` |

Three things hold no matter what you pass:

- **It never deletes.** Files you added that the generator knows nothing about
  are left alone in every mode.
- **Imported estate is never overwritten.** Anything recorded in
  `data/.import-manifest.json` is refused outright, flag and phrase or not.
- **Without a terminal, an overwrite aborts** rather than proceeding. For a
  pipeline, pass the phrase deliberately:

  ```bash
  ./scripts/bootstrap.sh --force --confirm 'wipe everything & start fresh'
  # or BOOTSTRAP_CONFIRM='wipe everything & start fresh'
  ```

Your real undo is git. Commit before a `--force` run and the diff tells you
exactly what the generator changed.

---

## 2. The decisions that are yours

The generator refuses to guess these. They are listed in
`docs/ARCHITECTURE.md` section 14; three block a real apply.

### 2.1 State backend — blocking

`stacks/*/backend.tf` ships a placeholder `backend "local" {}` so the stacks
initialise for offline validation. **It is not acceptable for a real manager.**

Pick one with a flag rather than editing the stacks by hand:

```bash
./scripts/bootstrap.sh --force --backend gitlab    # GitLab-managed state
./scripts/bootstrap.sh --force --backend s3        # or minio, ceph
./scripts/bootstrap.sh --force --backend azure
./scripts/bootstrap.sh --force --backend local     # filesystem on this server
```

The flag takes the Terraform backend type (`http`, `s3`, `azurerm`, `local`) or
a friendly name for it — `gitlab` is `http`, `minio` and `ceph` are `s3`,
`azure` is `azurerm`, `file`/`filesystem`/`server` are `local`. Case does not
matter.

Whatever you choose needs three things. The third is the one people skip:

1. **Encryption at rest** — state holds the estate's security posture.
2. **Access limited to the pipeline identity.**
3. **Locking.** One state per stack per manager, up to ~50 states across a
   10-manager estate, with CI running them in parallel. Without locking, a
   pipeline job and an engineer running the same site at once will corrupt the
   state file, and Terraform will not warn you.

#### GitLab-managed state — `--backend gitlab`

If you have GitLab, this is the least work: locking, encryption at rest and
version history come from GitLab, with no object store to run.

```hcl
# envs/lon1.backend.hcl
address        = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security"
lock_address   = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security/lock"
unlock_address = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security/lock"
lock_method    = "POST"
unlock_method  = "DELETE"
retry_wait_min = 5
```

The state **name** at the end of the address must be unique per stack per
manager — that is what keeps `lon1-local-security` and `lon1-local-tags` apart.

Credentials never go in that file, because it is committed. In a GitLab job
`scripts/tf.sh` authenticates with the job's own token (`gitlab-ci-token` and
`CI_JOB_TOKEN`), so nothing needs storing; set `TF_HTTP_USERNAME` and
`TF_HTTP_PASSWORD` yourself only to override that.

Outside CI, use a project access token with the `api` scope, sourced the same
way NSX credentials are. `make validate` errors if a credential appears in
`envs/*.hcl`, and errors on an `address` with no `lock_address`.

#### Filesystem state on a server — `--backend local`

Workable for a lab or a single-operator setup, and only with all of:

- **one** runner, and nobody running Terraform from a laptop;
- a persistent volume that is encrypted and backed up — losing state means
  Terraform no longer knows it owns anything;
- filesystem permissions restricting it to the pipeline user.

There is still no locking. `scripts/tf.sh` refuses to apply through it unless
`ALLOW_LOCAL_STATE=1` is set explicitly, and that guard is deliberate.

#### Not an option: state committed to git

Not to this repository, not to another one, GitLab or otherwise:

- State stores values in **plaintext**, including anything credential-shaped
  that a provider wrote into it.
- Git history is **permanent**. Once pushed, removing it means rewriting history
  everywhere it was cloned.
- Git has **no locking**. Two runs produce a merge conflict on a binary-ish
  blob, and resolving it by hand means hand-editing state.

`.gitignore` blocks `*.tfstate` for this reason. GitLab-managed state (above) is
a different mechanism — an API GitLab hosts, not a file in a repository — and it
is the right way to keep state in GitLab.

### 2.2 Where the files live, and how changes get reviewed — first-run decision

Asked at first run because it decides whether a firewall change is reviewable at
all. It is **not** irreversible: `.gitlab-ci.yml`, the GitHub workflows and the
helper scripts are generated whatever you pick, so changing your mind later
costs one command.

```
  1) GitLab   — full CI/CD pipeline, set up for you      (recommended)
  2) GitHub   — workflows written; you wire them up
  3) Another git host — CI files written; you wire them up
  4) Local files only — no versioning, no pipeline, manual apply
```

| Choice | Flag | Written | Done for you |
|---|---|---|---|
| **GitLab** *(default)* | `--vcs gitlab --git-remote URL` | `.gitlab-ci.yml`, child-pipeline generator, MR template | remote attached |
| GitLab in Docker | `--vcs gitlab-docker` | same | server started, project created, pushed, runner registered, root password printed |
| GitHub | `--vcs github` | `.github/workflows/{validate,plan,apply}.yml`, PR template | remote attached; **secrets and environment protection are yours** |
| Another git host | `--vcs git` | both sets | remote attached; their location printed |
| Local only | `--vcs none` | **nothing** | nothing — `make plan` / `make apply` by hand |

`--ci gitlab\|github\|both\|none` overrides which pipeline is written, if you
want GitHub workflows on a GitLab remote or anything else unusual.

**GitLab is the default because it is the only one this script can take all the
way** — server, project, runner, variables and gate. For GitHub the workflows
are complete and correct, but the repository secrets and the apply environments
are yours to configure, and nothing here can do it for you.

The choice is recorded in `.nsx-bootstrap.conf`, so a later bare re-run keeps
it. A tree set up as local-only will not sprout a pipeline because somebody
re-ran the generator.

#### Local only — the manual path

No pipeline is written at all. The workflow is what it was before CI existed:

```bash
make validate                                 # schemas and conventions
make plan  STACK=local-security SITE=lon1     # writes a saved plan
make show  STACK=local-security SITE=lon1     # read it — this is the review
APPROVE=yes make apply STACK=local-security SITE=lon1
```

`scripts/tf.sh` still refuses to apply without a saved plan, without
`APPROVE=yes`, and through the placeholder local backend — so the shape of the
review survives even with nobody to review it. What is missing is the record of
who changed what and why.

Migrating later, from a tree with no versioning — this also **writes the
pipeline files that were skipped**:

```bash
scripts/enable-gitops.sh --remote git@gitlab.example.com:net/nsx.git
scripts/enable-gitops.sh --remote git@github.com:org/nsx.git --ci github
scripts/enable-gitops.sh --local-gitlab
```

It refuses to commit if a state or plan file is present, and refuses outright if
`.gitignore` does not exclude `*.tfstate` — committing state is the one mistake
with no clean undo.

#### What the pipeline gives you

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

Four of the controls live on the git host, not here, and a pipeline without them
is one anybody can bypass:

- branch protection on the default branch;
- an approval requirement on merge requests;
- `VAULT_PLAN_TOKEN` **read-only**, available everywhere;
- `VAULT_APPLY_TOKEN` write and **protected**, so only protected branches can
  apply.

`docs/GITOPS.md` in the generated tree has the rest, including what the approver
is checking.

#### No GitLab? One command

```bash
scripts/gitlab-up.sh
```

GitLab CE and a runner in Docker, the project created and pushed, the runner
registered, and the initial root password printed the way GitLab does it —
readable again later with `scripts/gitlab-up.sh --password`. Needs Docker and
about 4 GB of RAM, and first boot takes several minutes. It is a lab instance:
no TLS, no backups, no HA.

### 2.3 Credentials — blocking

Credentials never live in this repository, and never pass through a Terraform
data source: the `vault_*` data sources write the fetched secret into state in
plaintext.

`scripts/with-credentials.sh` fetches outside Terraform and execs with `NSXT_*`
in the environment. There are two sources, chosen automatically (Vault when
`VAULT_ADDR` is set, otherwise the environment):

- **Vault.** It assumes KV v2 at the path recorded per manager in
  `inventory/managers.yaml`; the mount convention and auth method are yours to
  set. `vault_path` records **where the credential lives, never the credential**.
- **GitLab CI/CD variables.** `NSX_PLAN_USERNAME` / `NSX_PLAN_PASSWORD` for
  merge request plans and `NSX_APPLY_USERNAME` / `NSX_APPLY_PASSWORD` for apply,
  or per manager as `NSX_<SITE>_PLAN_USERNAME` and so on (`hyd-gm01` is
  `HYD_GM01`). The exact lookup order, and why unprotected plan variables need a
  read-only NSX account, are in `docs/GITOPS.md`.

If a manager's certificate comes from an internal CA, or is self-signed, give
the pipeline that PEM as a CI/CD variable of type File: `NSX_CA_FILE_<SITE>` for
that manager (`hyd-gm01` is `NSX_CA_FILE_HYD_GM01`), or `NSX_CA_FILE` for every
manager without its own. Check first that the certificate lists the manager's
name or address as a Subject Alternative Name; one with only a Common Name is
rejected whatever you trust (`docs/GITOPS.md` shows the one-line check). Run by hand, set
`SSL_CERT_FILE` to a bundle that holds your CA and, for a GitLab with its own CA,
GitLab's too.

### 2.4 Who tags the workloads — decide before writing group criteria

Group membership resolves from tags, so this decides whether a membership change
is reviewable. Two supported variants, covered in full in `docs/TAGGING.md`:

| | Variant A — *default* | Variant B |
|---|---|---|
| Who writes NSX tags | VCF/vRA automation, CMDB, provisioning | this repository |
| Where it is declared | that system | `data/vm-tags/<site>.yaml` |
| Applied by | that system | `stacks/local-tags` |
| Suits | the estate | bounded exception sets |
| Ceiling | none | a few hundred VMs |

**Neither variant requires the NSX UI.** The question is which system is the
source of truth.

Pick **A** if anything else already writes NSX tags — VCF automation, vSphere
tag sync, a CMDB. Any one of those is decisive: `nsxt_policy_vm_tags` replaces a
VM's *entire* tag set, so two writers overwrite each other forever.

Pick **B** for VMs nothing else tags — hand-built servers, appliances, workloads
not onboarded to a CMDB, and quarantine:

```bash
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make validate
make plan STACK=local-tags SITE=lon1
```

Mixing is per **VM**, never per tag. The boundary is enforced: every scope in
`data/schema/tag-scopes.yaml` records its owning system, and `make validate`
errors if `data/vm-tags/` writes a scope not owned by `terraform`.

### 2.5 The rest

| Decision | Default taken | Revisit when |
|---|---|---|
| Terragrunt vs CI matrix | CI matrix over `inventory/managers.yaml` | the matrix demonstrably hurts |
| GM owns the Application category, or delegated per site | GM owns it | site teams need independent app policy |
| One federation or several | one — `global-security` is a single state | a second GM appears; it becomes one state per federation |
| Import scope and pilot site | none chosen | before the first adoption tranche |

---

## 3. Describe your estate

Everything derives from one file.

```yaml
# inventory/managers.yaml
managers:
  gm1:
    role: gm
    host: gm1.nsx.example.com
    site: global
    vcf_instance: vcf-lon
    vault_path: secret/nsx/gm1      # a path. Never a secret.
    tier: prod
  lon1:
    role: lm
    host: lon1-nsx.example.com
    site: lon1
    vcf_instance: vcf-lon
    vault_path: secret/nsx/lon1
    tier: prod
```

Then one `envs/<site>.backend.hcl` per manager — the filename must match the
manager key, which is how `scripts/tf.sh` finds it.

```bash
make validate     # schemas + conventions, offline
make matrix       # exactly what CI will run
```

Adding an eleventh Local Manager later is these two files and nothing else.

---

## 4. Greenfield or brownfield

### Greenfield — no NSX objects exist yet

Write data files and plan. Start with one site and one application; expand once
a plan has been reviewed against a real manager.

### Brownfield — adopt what is already there

The common case, and the one to take slowly: one policy of one manager per merge
request, each step reversible. `docs/IMPORT.md` in the generated tree is the full
runbook, including what is deliberately not adopted.

From the pipeline, with no credentials on any server: *Run pipeline* on the
default branch with `ADOPT_SITE=lon1` lists what can be adopted; adding
`ADOPT_POLICY=legacy-app` opens a merge request that adopts it. By hand:

```bash
# 0. with no data for the manager yet, a plan must say "no changes"
make plan STACK=local-security SITE=lon1

# 1. capture, read-only (reports/ is gitignored)
scripts/with-credentials.sh lon1 -- scripts/import-estate.py --site lon1 --dump-only reports/lon1-raw.json

# 2. convert one policy and what it needs, offline
make import SITE=lon1 DUMP=reports/lon1-raw.json POLICY=legacy-app

# 3. merge request: the plan must only import; apply; the next plan says no changes
make plan STACK=local-security SITE=lon1
```

What protects the live estate is mechanical, not a review checklist:

- **`scripts/plan-guard.py` runs after every plan and before every apply.**
  While a tranche is open the plan may only import: a create (a would-be
  duplicate) or an update (data that does not match NSX yet) fails the job. Any
  destroy or replace fails it too, unless that exact object is approved in
  `allow-destroy.txt` in the same merge request.
- **A tranche is done when the next plan reports *no changes*.** Then delete its
  import file.
- **Nothing is adopted lossily.** Objects the converter cannot represent exactly
  (MAC or identity groups, unusual service entries, inline rule services) stay
  in the UI and are listed.
- **Undo is one command:** `make hand-back` stops managing an object without
  deleting it.

Imported files are recorded in `data/.import-manifest.json` and are never
overwritten by the generator, by any flag. Re-running the importer writes a
`.new` sidecar rather than clobbering your edits.

---

## 4b. Are you ready?

Generating the files is not the same as being ready to apply them.

```bash
make ready
```

It exits non-zero while anything blocks, so it works as a gate in a pipeline or
a runbook. On a freshly generated tree it reports four blocking items, which is
correct — that tree is not production ready:

```
BLOCK   state is still the placeholder local backend, which has NO LOCKING.
BLOCK   no .terraform.lock.hcl committed.
BLOCK   inventory/ and data/ are still the shipped EXAMPLE content.
BLOCK   no git remote. Nothing is pushed, so nothing can be reviewed.
```

It also prints what it **cannot** see, because those live on your git host and
in Vault rather than in this repository:

- branch protection on the default branch;
- an approval requirement on merge/pull requests;
- `VAULT_ADDR` and a read-only `VAULT_PLAN_TOKEN`;
- `VAULT_APPLY_TOKEN`, marked protected;
- a protected environment (GitLab) or required reviewers (GitHub) on apply;
- whether a `terraform plan` has ever run against a real manager.

Delete `data/.example-content` once the estate data is yours — that is how you
tell the check the data is real, and re-running the generator will not put it
back.

---

## 5. First contact with a manager

Everything above is offline. From here a mistake reaches a live firewall.

```bash
make preflight
make validate
scripts/with-credentials.sh lon1 -- scripts/tf.sh init local-security lon1
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
scripts/tf.sh show local-security lon1        # review the rendered plan
```

Commit the `.terraform.lock.hcl` from that first `init`. An unpinned provider
across 10+ managers means different sites realize different behaviour.

Review the plan against the checklist in `.github/pull_request_template.md`. The
two that catch real damage:

- **No unexpected destroys.** A destroy on a rule you did not touch means map
  keys shifted — stop and find out why.
- **The resource count delta matches the intent.**

Then, and only then:

```bash
APPROVE=yes scripts/tf.sh apply local-security lon1
```

`apply` requires a saved plan and an explicit `APPROVE=yes`. There is no path
that plans and applies in one step, deliberately.

### Suggested order

1. `local-security` at one non-production site — smallest blast radius.
2. `local-tags` at the same site, if you chose variant B.
3. `local-network` at that site.
4. `global-security` — every site at once. Do this last, and with the security
   reviewer present.
5. `platform` only under change advisory.

---

## 6. Daily use, once it is running

```bash
make add-rule POLICY=prod-payments RULE=allow-web-to-app \
  ARGS='--source prod-payments-web --destination prod-payments-app --service https --scope prod-payments-app'
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make validate
```

Open a pull request. CI validates and posts a plan per site. A human approves;
the pipeline applies.

`make drift STACK=local-security SITE=lon1` reports what changed outside
Terraform. It writes a report and never reverts anything and never writes
`data/` — drift is a ticket for a person, not something to auto-fix.

---

## 7. If something is wrong

| Symptom | Cause |
|---|---|
| `make validate` errors on a tag scope | The scope is not in `data/schema/tag-scopes.yaml`, or `data/vm-tags/` is writing a scope another system owns. `docs/TAGGING.md`. |
| Plan shows a *create* during an import | The `nsx_id` does not match the live object. **Stop** — do not apply. |
| Plan destroys rules you did not touch | Map keys shifted. Never `count` for rules; check what renamed. |
| `apply` refuses | No saved plan, no `APPROVE=yes`, or the local backend is still in place. All three are deliberate. |
| Generator reports "kept" and exits 2 | You edited a generated file. Take the update with `--force`, or keep your edit. |
| Group is empty and traffic drops | A tag scope was renamed. That is a restricted change and needs proof that no criteria reference it. |

`docs/ARCHITECTURE.md` section 2 lists the ten failure modes worth internalising
before the first change.

---

## Keeping it up to date — the same command every time

This repository is the generator. Your tree is generated from it once; after
that, **improvements arrive by updating this clone and running one command**.
The command does not change between releases.

```bash
cd ~/nsx-terrafrom                       # the clone of this public repository
scripts/update.sh --dir ~/nsx-estate     # first time only; the path is remembered
scripts/update.sh                        # every time after
```

It pulls this repository (fast-forward only), generates what your tree *would*
be today in a scratch directory, and **shows you the difference before writing
anything**:

```
  1 new   3 update   1 yours, kept   1 conflict   107 unchanged

NEW       scripts/gitlab-https.sh
UPDATE    .gitignore                 (diff shown)
CONFLICT  modules/group/main.tf      (diff shown; kept unless you say otherwise)
YOURS     README.md                  (you edited it, the generator did not; left alone)

Apply 4 change(s) to /root/nsx-estate? [y/N]
```

How each file is judged — by comparing what the generator writes now, what is in
your tree, and what the generator wrote last time (`.nsx-generated.sha256`,
written by `bootstrap.sh`):

| | Meaning | What happens |
|---|---|---|
| **NEW** | not in your tree yet | created |
| **UPDATE** | generator changed it, you did not | replaced |
| **YOURS** | you changed it, generator did not | never touched |
| **CONFLICT** | both changed, or there is no record from last time | kept; `--overwrite-unknown` applies it |

Always true: `data/`, `inventory/` and `envs/` are never read or written; nothing
is ever deleted; every overwritten file is first copied to
`.nsx-update-backup/<timestamp>/`.

```bash
scripts/update.sh --check          # preview only; exit 3 if anything is pending
scripts/update.sh --summary        # file list without the diffs
scripts/update.sh --yes            # apply without asking (safe changes only)
scripts/update.sh --commit         # in a git tree: commit on update/<rev>; never pushes
scripts/update.sh --overwrite-unknown   # also apply CONFLICT files, backed up
scripts/update.sh --remote URL --branch main    # pull from somewhere else
```

Use `--commit`, push the `update/<rev>` branch and open a merge request: the
update then goes through the same review and plan pipeline as any other change.
Some updates need an action afterwards (a changed `deploy/gitlab/` file means
restarting the container; a changed `backend.tf` means `terraform init`); the
command lists them at the end and does not do them silently.

### What the update does to the host

After the files, `update.sh` runs `scripts/converge.sh` in your tree, so a release
that needs something new from the server just arrives:

| Step | What it does when it is not already right |
|---|---|
| Docker | reports clearly if it is missing or unreachable, and stops |
| CI image `nsx-ci:1` | builds it from Docker Hub images (Python, Terraform, bash, curl, git); jobs download nothing |
| GitLab container | recreates it if its configuration changed (data kept), waits until it answers |
| Runner | registers it, or re-registers it if it was lost or the settings for this host changed |
| Network check | from inside a job container: can Terraform providers be downloaded? |

Each step is independent and says what to do when it fails. It never restarts the
runner unless the runner's configuration changed, so it is safe to run while a job
is running. Run it any time with `scripts/converge.sh` (or `--check` to only look).

**Locked-down networks.** The jobs need no package mirrors, and the NSX provider is
built into the CI image (pinned in `deploy/ci-image/providers.tf`), so plans
download nothing. Only the image build fetches it, once; if that fails, converge
warns and jobs fall back to downloading it. If the job containers cannot reach
`registry.terraform.io` and the provider is not in the image:

- the `terraform` validate job ends as a **warning** (exit 42), never silently and
  never as a hard failure, and its log says what to set;
- set the CI/CD variable `NSX_TF_NETWORK_MIRROR` to an internal provider mirror
  (or `NSX_TF_FS_MIRROR` to a directory made with `terraform providers mirror`);
- if the network uses a proxy, it is found automatically (your shell, then the
  Docker daemon's settings). To set it explicitly, put `NSX_HTTPS_PROXY=...`,
  `NSX_HTTP_PROXY=...` and `NSX_NO_PROXY=...` in `deploy/gitlab/ci-network.env`
  (never overwritten, never committed) and run `scripts/converge.sh`.

The release notes for every version are in `CHANGELOG.md`; `update.sh` prints the
ones your tree has not seen.

A tree generated before this existed has no record of last time, so its first
update shows every differing file as **CONFLICT**. Read the diffs once, apply
with `--overwrite-unknown` if they are all the generator's, and it is
tracked from then on.

If the clone's `origin` is not this repository (for example it points at your
own GitLab), pass `--remote https://github.com/sampath9966/nsx-terraform` or
`git remote add upstream` and use `--remote upstream`.
