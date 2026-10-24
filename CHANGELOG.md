# Release notes

Every release is on `main`. To take one, on each server:

```bash
cd ~/nsx-generator && git pull        # or just: scripts/update.sh, which pulls for you
scripts/update.sh                     # shows what changes, asks, applies, then fixes up the host
```

That one command is the upgrade for every release below. It shows the notes for
the releases you have not applied yet, previews each file change, and ends by
running `scripts/converge.sh`, which brings the host (CI image, runner, GitLab
container) to what the release expects and tells you plainly about anything it
cannot fix itself. Run it again after fixing whatever it reported.

## 1.4.2

**The mirror job works on large managers.** A manager with thousands of objects made the mirror job fail with `python3: Argument list too long` just after pushing `mirror/<site>`, so the merge request was never opened. The list of changed files and the importer's report went to Python in environment variables, and Linux limits one variable to 128 KiB. They now go through files. The adopt job had the same limit, and is fixed the same way.

**A merge request's description stays within GitLab's limit.** The mirror and adopt merge requests list at most 400 files and 400 "left in the UI" lines; past that they say how many more there are and point at the job's log, which has them all.

## 1.4.1

**A manager's mode comes from `inventory/managers.yaml` only.** The CI/CD variable `NSX_MODE_<SITE>` added in 1.3.0 is gone. Entering and leaving mirror mode is now always a reviewed merge request, and the mode can no longer differ between a merge request's pipeline and the default branch's, as it could with a protected variable. A leftover `NSX_MODE_*` variable stops the pipeline, `tf.sh`, the mirror job and change control, and says to set `mode:` in the inventory instead, so it never looks as if it works.

**With `MIRROR_SITE=all` and no manager in mirror mode,** the mirror job lists every manager with its mode and says to add `mode: mirror` in the inventory.

**A CI/CD variable named in the wrong case stops the job and says so.** Variable names are case-sensitive and every `NSX_*` variable these scripts read is upper-case, so `NSX_CA_FILE_hyd_gm01` was silently ignored and the manager's CA never trusted. The inventory reader and `with-credentials.sh` now stop with the variable's name and the name to rename it to.

**`NSXT_ALLOW_UNVERIFIED_SSL` reaches the capture too, and is never silent.** The flag switches off TLS verification in the NSX provider. The importer, used by the mirror and adopt jobs, ignored it, so a manager without a trusted certificate could be planned but not read. It now honours the flag. Every job that talks to NSX prints a warning while it is set: the manager's identity is not checked, and whoever answers receives the credentials.

**Fixed:** `tf.sh` and `with-credentials.sh` read the manager through `eval "$(...)"`, and a failure inside it went unnoticed (`set -e` does not see it), leaving the manager's mode unset. Both now stop if the inventory cannot be read, so an error there can never let a mirror-mode manager be applied.

**Tests:**
- `tests/brownfield.sh`: a leftover `NSX_MODE_` variable stops the mirror job and `tf.sh` (nothing applied); an unknown mode in the inventory is an error; the mirror job's message; a capture with the flag and no CA succeeds with the warning.
- `tests/ci-scripts.sh`: a mode variable stops the child pipeline; a wrong-case CA variable stops the pipeline and `with-credentials.sh`; the warning is printed while verification is off.

## 1.4.0

**Change control: two approvals, enforced by the pipeline, and a change log.** GitLab Community Edition has no enforced approval rules or deployment approvals, so `NSX_APPLY_MODE=approval` enforces them in the pipeline (`scripts/change-control.py`, `scripts/approve-apply.sh`; `docs/GITOPS.md`, "Change control"):

- **Change Request.** After the plans on the default branch, a `change request` job opens an issue with what each plan changes in NSX, the merge requests in the change, their authors and reviewers, and the plans in full.
- **Review check.** Every merge since the last applied change must have been merged or approved by someone other than its author. A self-merged change, or a commit pushed without a merge request, blocks the change request and fails the pipeline.
- **Approvals.** It needs `NSX_REQUIRED_APPROVALS` (default 2) :thumbsup: on the issue, from Maintainers, never from an author of a change in it.
- **Standby approvals.** `inventory/delegations.yaml` hands a Maintainer's approval to another engineer until a date, reviewed like any change. A stand-in and their Maintainer count once.
- **One apply per change.** A single `approve and apply` job applies every manager's saved plan and stops at the first failure. A Maintainer or the approvals schedule (`APPROVAL_SWEEP=1`) starts it, and it checks the approvals again before touching anything. It is manual and non-blocking, so the pipeline shows passed while the change waits.
- **Record.** The result is written on the Change Request, which is closed or marked failed, and a line is added to the wiki page "NSX Change Log".
- **Supersession.** A newer change request supersedes an older one still waiting.
- **Plans per manager.** Plan jobs now also keep their plan under `plans/<site>/<stack>/`, so a job taking several plans gets each manager's own even when two share a stack.

`make validate` checks the standby approvals file and warns about a Global Manager `domain` other than `default`.

**Tests:**
- `tests/change-control.sh`, against a stand-in GitLab API (`tests/fake_gitlab_cc.py`), covers:
  - nothing to approve;
  - the change request's contents;
  - who counts: author, bot, Developer, Maintainer, ended, foreign and active standby approvals, a stand-in and their Maintainer once;
  - the approve job applying each manager's own plan, skipping no-ops and mirror managers, stopping at a failure, and recording both results;
  - the wiki log;
  - blocking on a self-merged change or a push without a merge request, across every merge since the last applied change;
  - supersession;
  - the sweep starting only approved changes, once;
  - token hygiene;
  - the validator.
- `tests/ci-scripts.sh` covers the pipeline structure.
- `tests/change-control-gitlab.sh` runs the same flow against a **real GitLab**. It verified every API call on GitLab CE 17.5.2: merge requests of a commit, approvals, members, project access tokens, issues, award emoji, wiki, pipeline jobs and job play. `tests/e2e-gitlab.sh` now runs it.
- The end-to-end test also runs GitLab's own CI lint on every generated pipeline, in every apply mode.
- On a real GitLab with a runner, a pipeline whose approve job waits shows **success**, and the change request's number reaches that job.

## 1.3.1

**Pipelines on the default branch end "passed", not "blocked".** A manual apply job used to hold the whole pipeline "blocked" until someone ran or cancelled it, so every merge left a blocked pipeline behind. Manual apply jobs are now non-blocking: the pipeline finishes "passed" once its plans pass, and each apply stays available behind its ▶ button with the same gate as before (manual, the saved plan only, plan-guard again, the protected write credential). An apply that is run and fails shows as failed on the job and as a warning on the pipeline. With `NSX_APPLY_MODE=auto`, applies still fail the pipeline outright.

**Fixed: with any manager in mirror mode, GitLab rejected the generated child pipeline (1.3.0).** A line of the `sync-state` job held `: ` unquoted, which YAML reads as a key, not a command: `script config should be a string`. Python's YAML parser accepts it silently, so the tests did not see it; GitLab's own CI lint did. The line is fixed, and `tests/ci-scripts.sh` now checks that every script line of the generated child pipeline, in every apply mode, is a plain string. Every generated pipeline was also checked with the CI lint API of a real GitLab CE 17.5.

**Upgrading from 1.2.x with a mirror schedule already created:** until the tree is on 1.3.x its CI file does not know `MIRROR_SITE`, so a schedule runs an ordinary pipeline. Pause the schedule, update, then resume it.

**Tests:** `tests/ci-scripts.sh` checks that a manual apply is non-blocking and an automatic one is not.

## 1.3.0

**Mirror mode: the whole manager in the repository and in Terraform's state, following the UI, until you cut over.** For a manager engineers still run from the UI, while the other managers carry on as normal.

**Turning it on.** Put a manager in mirror mode with the CI/CD variable `NSX_MODE_<SITE>` = `mirror`, with no commit (`hyd-gm01` is `NSX_MODE_HYD_GM01`), or with `mode: mirror` in `inventory/managers.yaml`. The variable wins. An unknown value stops the pipeline and names the variable.

**The `mirror` job.** Schedule it under *Build → Pipeline schedules* with `MIRROR_SITE` = `all` or one manager, and `MIRROR_AUTO_MERGE` = `1` for hands-off. Each sync:
- reads the manager with the read-only plan credential;
- rewrites that manager's own files with every object the importer can represent exactly: groups, custom services, and distributed firewall policies and rules. Objects added, edited or deleted in the UI follow;
- keeps one merge request up to date listing the changes, and does nothing when NSX matches the repository. An unchanged manager rewrites the same bytes.

**State follows, NSX is never written.** On the default branch a mirror manager has no apply job. It gets an automatic `sync-state` job instead, which applies its plan only if the plan just imports and refreshes. `plan-guard --observe` refuses any create, update, destroy (approved or not) or hand-back, and `tf.sh` lets a mirror manager be applied only with the read-only credential. So new objects are imported, edited ones refreshed, and deleted ones leave state. A copy that is behind the UI is refused, never pushed back onto NSX, and the next sync brings the change in.

**Other managers are not held up.** A mirror manager's plans may fail as a warning on other merge requests and on the default branch, so its UI churn never blocks other managers' work. Its own mirror merge request must plan cleanly. GitHub Actions leaves mirror managers out of the apply matrix.

**Cutover.** Sync, check that the plan reports no changes, then switch the manager to managed. State already holds everything, so there is nothing to apply. Then delete the mirror's import file. `docs/IMPORT.md`, "Mirror mode", has the steps.

**Mirror files.** They start with `# nsx-mirror: <site>` and belong to the job. Objects declared in other files are left to them (`MANAGED`); objects that cannot be represented exactly stay in the UI (`NOT ADOPTED`). `scripts/import-estate.py --mirror` is the same conversion by hand.

**A Global Manager and its Local Managers: nothing taken twice, no drift loops.** Each object has one owner in `data/`, so one stack manages it. These changes keep that true when both are copied:

- **Global objects stay the GM's.** The importer keeps only the manager's own tree: a Local Manager's listing of the GM's objects is never taken (`NOT ADOPTED ... belongs to the Global Manager`).
- **Global references resolve.** A site-local rule using a global group or service is written by name, and the local-security stack now resolves GM-owned names to their `/global-infra` paths without managing them. Before, the converter wrote the raw path and the validator failed the merge request. Until the GM's copy holds the object, the rule waits in the UI.
- **No silent mis-binding.** A local object whose id another manager owns in `data/` is not taken, nor are the rules that use it, which would otherwise resolve to the other object. Neither is an LM group that nests a global group.
- **No raw paths.** A reference that resolves to nothing now leaves the rule in the UI, with the reason, instead of writing a raw path.
- **No empty policies.** A policy with no rule left to take stays in the UI whole.

**Fixed in adoption generally:**
- **Apply To `ANY`.** A rule or policy whose *Applied To* is `ANY` was written with an empty scope, which the validator and the dfw-policy module refuse. It is now written as `ANY`, which plans with no change.
- **Predefined services named twice.** The same predefined service (for example `HTTPS`) named in two files, by the GM's and an LM's copy or by two adoptions, was reported as defined twice. Identical declarations are now accepted.
- **GM domain.** The importer read a Global Manager's objects from domain `global`; NSX keeps global objects in `default`, as the stacks already assumed. The example inventory and the global-security README said `global` too; fixed.
- **Not-adopted reasons.** Rules reported as not adopted now say why.

**Tests:**
- `tests/brownfield-provider.sh`, with the real provider: an LM rule using the GM's group and service, Apply To `ANY`, plans as a pure import (`10 to import, 0 to change`), manages none of the GM's objects, applies as imports only, and the next two plans report no changes.
- `tests/brownfield.sh` copies a GM and an LM side by side and covers:
  - the LM's listing of a global object;
  - an LM group with a GM group's id, and the rule using it;
  - an LM group nesting a global group;
  - rules using a declared and an undeclared global group;
  - `ANY` scope, and `HTTPS` named by both managers;
  - no id declared twice, no raw paths, the copy validating, and a re-sync changing nothing;
  - both sync orders (LM first, then GM) converging.
- `tests/brownfield-provider.sh`, mirror mode, with the real provider:
  - the whole copy plans as `8 to import, 0 to add, 0 to change, 0 to destroy`;
  - the write credential is refused, and the read-only sync-state apply imports all 8;
  - a UI change not yet synced is refused, by the plan and by the apply;
  - after the sync, an edited group needs nothing and a new policy is imported, and state holds both;
  - a policy deleted in the UI leaves state with nothing done in NSX;
  - at cutover Terraform already holds everything;
  - NSX receives no write.
- `tests/brownfield.sh`: the mirror job end to end against the mock manager, a bare git remote and a new fake GitLab API (`tests/fake_gitlab_api.py`). Covers syncs, merge request updates and closure, add, edit and delete, auto-merge, `all`, managed managers refused, and token hygiene. Also `plan-guard --observe`, and `tf.sh` refusing the write credential and honouring `NSX_MODE_<SITE>`.
- `tests/ci-scripts.sh`: the child pipeline. A mirror manager gets no apply job, an automatic read-only sync-state job, and a lenient plan except in its own mirror merge request. Managed managers keep manual applies and strict plans, the variable override works both ways, and an invalid value fails. Also the schema, the mirror job's rules, and the GitHub apply matrix.
- `tests/mock_nsx.py` re-reads its data when it changes, to stand in for an engineer in the UI.

## 1.2.10

**Plan jobs failed with `remote error: tls: unrecognized name` on a network with an internet proxy.** The runner gives jobs the host's proxy and a `NO_PROXY` of private address ranges. Terraform, curl and Python match `NO_PROXY` against the name in the URL, and a range such as `10.0.0.0/8` only ever covers a literal IP address, so a manager named by FQDN was sent to the proxy, which refused it. `scripts/with-credentials.sh`, which every job that talks to NSX already runs through, now adds the manager's host from `inventory/managers.yaml` (and `SDDC_MANAGER_HOST`) to `NO_PROXY`, so managers are always reached directly. Downloads of providers and images still use the proxy. Where managers really are reached through a proxy, set `NSX_MANAGER_VIA_PROXY=1`.

**The NSX provider is built into the CI image.** Every plan downloaded vmware/nsxt (about 40 MB, from GitHub's release storage) through the proxy, so a slow or blocked download failed plans at random (`Client.Timeout exceeded while awaiting headers` on `release-assets.githubusercontent.com`). `scripts/ci-image.sh` now fetches the version pinned in the new `deploy/ci-image/providers.tf` (3.12.1) once, before the image build: it uses `terraform providers mirror`, which checks the provider's signature, with the proxy settings jobs get and the host's CA bundle. The image carries it in Terraform's implied local mirror, `/usr/local/share/terraform/plugins`, so `terraform init` installs it with no network at all, and every job runs the same provider version until you change the pin. If the fetch fails, the image is still built, `converge.sh` warns with the reason and the fix, jobs download the provider as before, and the next converge tries again. `NSX_TF_NETWORK_MIRROR` and `NSX_TF_FS_MIRROR` still take precedence. The update rebuilds the image once.

**Tests:** `tests/ci-scripts.sh` covers the image's provider: fetched for the host's platform, as the invoking user, with the jobs' network settings; current when inside; rebuilt for a new pin; a failed fetch builds a working image, exits 2 with the reason, and is retried; the pin satisfies the stacks' constraint. Checked for real with Docker: the built image's `terraform init` succeeds with `--network none`. `tests/brownfield-provider.sh` reproduces the failure with the real provider against a proxy that refuses the handshake as a corporate proxy does (`tests/sni_reject_proxy.py`): an FQDN manager outside `NO_PROXY` fails with exactly this error, the same plan through `with-credentials.sh` succeeds with nothing reaching the proxy, and `NSX_MANAGER_VIA_PROXY=1` keeps the proxy.

## 1.2.9

**Plan jobs failed with `HTTP remote state endpoint requires auth`.** The docs said jobs reach GitLab-managed state with their own token, but nothing set it: `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` appeared only in comments. `scripts/tf.sh` now sets them to `gitlab-ci-token` and `CI_JOB_TOKEN` inside a GitLab job, so no state credential is stored anywhere; credentials you set yourself are left alone, and nothing is set outside CI. The end-to-end tests never ran a plan job (there is no NSX in CI), which is how this was missed.

**Each NSX manager can have its own certificate authority.** Set `NSX_CA_FILE_<SITE>` (a CI/CD variable of type File; `hyd-gm01` is `NSX_CA_FILE_HYD_GM01`, the same naming as the credentials) to the PEM of the CA that signed that manager's certificate, or to the certificate itself if the manager is self-signed. It wins over `NSX_CA_FILE`, so each manager's run trusts only its own CA; `NSX_CA_FILE` remains the default for managers without their own, and may hold several PEMs. Nothing changes for a tree that uses `NSX_CA_FILE` today.

**The importer's capture now trusts the same CA files.** `scripts/import-estate.py` read the manager with Python's default trust only, so capturing a manager with an internal or self-signed certificate failed even with `NSX_CA_FILE` set; its hint suggested `--insecure`. It now uses `NSX_CA_FILE_<SITE>`, then `NSX_CA_FILE`, and the hint names the variable to set. It also no longer applies Python 3.13's strict X.509 checks, which reject internal CAs that lack a keyUsage extension: Terraform accepts those, so the capture and the plan would have disagreed about the same manager. The chain and the hostname are still verified.

**A certificate with only a Common Name is rejected whatever you trust** (`x509: certificate relies on legacy Common Name field`), by Terraform and by current Python alike. `docs/GITOPS.md` has a one-line `openssl` check to run against each manager before you start; such a certificate has to be replaced on the manager.

**Adopt from the pipeline, with no credentials on any server.** *Run pipeline* on the default branch with `ADOPT_SITE` runs only a new `adopt` job (`scripts/adopt.sh`): on its own it surveys the manager and lists each policy and whether it can be adopted, changing nothing; with `ADOPT_POLICY` (and optionally `ADOPT_TRANCHE`) it converts those policies, commits them to a branch `adopt/<site>-<tranche>` and opens a merge request carrying the converter's report and a review checklist. From there it is an ordinary change: planned, refused by `plan-guard` unless a pure import, reviewed, merged, applied by the manual job. The job reads the manager with the read-only plan credential and the same per-manager CA trust as plans, never applies, never pushes to the default branch, and never keeps the capture. It needs `NSX_ADOPT_TOKEN` (project access token, `api` and `write_repository`, masked and protected); git receives it in a header, never in a URL, and pushes with GitLab's CA from the job itself, through `GIT_SSL_CAINFO`, so a value inherited from the image cannot override it. `scripts/import-estate.py --list` is the survey on its own. Other jobs stand aside in an adoption run.

**Tests:** `tests/brownfield-provider.sh` now verifies TLS for real: the mock manager presents a certificate from its own CA, trusted through `NSX_CA_FILE_<SITE>`, and a manager signed by another CA is refused by the real provider. `TEST_EXTRA_CA` adds a TLS-inspecting proxy's CA for provider downloads where one is in the way. The offline suite checks the per-manager choice in `tf.sh`, a real TLS capture against the mock, and the adopt job end to end against the mock manager, a bare git remote and a fake GitLab API: survey, branch contents, merge request, no capture committed, token never printed, already-managed and repeated tranches; and the real push path, over HTTPS to a git server with its own CA (`tests/git_https_server.py`), authenticated by header, despite a misleading inherited `GIT_SSL_CAINFO`, and refused without the CA.

## 1.2.8

Adopting an existing estate safely, one policy of one manager at a time, and hardening found in a review before production use. A tree on Vault needs no action. Read **"Fixed: dangerous"** below if anyone runs `scripts/tf.sh` by hand for more than one manager from the same checkout.

**Nothing live is deleted, duplicated or changed by accident. This is enforced, not left to review.** A new `scripts/plan-guard.py` runs inside `scripts/tf.sh` after every plan and again before every apply, by hand and in CI:
- any destroy or replace is refused unless that exact object is approved in `allow-destroy.txt` at the repository root, in the same merge request (the refusal prints the line to paste);
- while an import tranche is open for that manager, the plan may only import: a create (an object about to be built twice) or an update (data that does not match NSX yet) fails the job. There is deliberately no override.

**Adopt one policy at a time.** `make import SITE=<site> POLICY="id1 id2" [TRANCHE=name]` (`scripts/import-estate.py --policy`) converts only those policies and exactly what they need: referenced groups, nested groups followed through, and custom services. Anything already in `data/` is skipped. Each tranche gets its own files (`data/*/imported-<site>-<tranche>.yaml`, `stacks/<stack>/import-<site>-<tranche>.tf`). Whole-manager import still works and now writes `-all` files.

**Import blocks no longer break other managers.** They were written to `stacks/<stack>/import.tf`, which every Local Manager running that stack evaluates, so a tranche for one manager failed every other manager's plan until it was applied. Import blocks are now gated on `var.site`.

**Nothing is adopted lossily.** Terraform clears any setting it does not manage, so a lossy import changes the live object on its first apply. The converter now carries group tags, service entry names, rule notes, log labels, context profiles (App-ID, FQDN) and tags, and policy comments and tags; the modules and schema gained policy and rule tags and policy comments. What cannot be represented exactly (MAC, external-id or identity groups, extended criteria, other service entry types, inline rule service entries, and anything using them) is not adopted: it is listed with the reason and stays in the UI. The rest of a policy is still adopted, rule by rule. Context profiles are the one thing data may reference by path.

**Custom services were never imported.** The converter wrote them to data without import blocks, so the first plan tried to create services that already exist. They are now imported.

**Capture read only the first page of each list.** The policy API pages its results; large estates were silently cut short. Capture now follows the cursor.

**Fixed: dangerous.** `scripts/tf.sh plan` initialised a stack only when `.terraform` was missing. Planning a second manager from the same checkout reused the first manager's backend, so the plan compared the second manager's data with the first manager's state and proposed destroying the first manager's objects through the second manager's credentials. Separately, the saved plan `stacks/<stack>/tfplan` was not tied to a manager, so a plan made for one manager could be applied with another's credentials. `tf.sh` now records the manager it initialised for and re-initialises when it changes, and records the manager with each saved plan (`tfplan.site`, carried with the plan artifact in CI); `show` and `apply` refuse a plan made for another manager. CI was not affected, because every job starts from a fresh checkout.

**A site-local custom service was created on every Local Manager.** Services had no `sites`, unlike groups and policies, so adopting one manager's service would have created it on all the others. Services now take `sites`, `local-security` creates them only there, and the validator requires the list for a site-local service (`["*"]` for all). A service with no `sites` keeps its old behaviour until you add it, so nothing is destroyed by upgrading.

**Hand an object back without deleting it.** `make hand-back STACK=<stack> ADDRESS='<address>'` (`scripts/hand-back.py`) stops managing one object, leaving it in NSX as it is: Terraform's `removed` block cannot name one instance of a `for_each`, so the file moves the instance to a stand-alone address and forgets it there. Terraform refuses the plan while the object is still in `data/`.

**Terraform now trusts the CAs it needs.** `scripts/tf.sh` builds a bundle of the system roots plus GitLab's CA (`CI_SERVER_TLS_CA_FILE`, which git and curl already used) and the NSX managers' CA (`NSX_CA_FILE`, a CI/CD variable of type File) and sets `SSL_CERT_FILE` for the run. A missing or non-PEM `NSX_CA_FILE` stops the run; an `SSL_CERT_FILE` you set yourself is left alone.

**Credentials from CI/CD variables explain themselves.** `--from env` with nothing set died with `invalid variable name`; it now lists what it looked for, in order, for the job's scope. Blank values are not credentials. A plan job never uses the apply credential, or the reverse.

**`scripts/update.sh` repeats any file it kept** in an ATTENTION block at the end, with the exact command, so "applied N change(s)" can no longer read as complete while part of a release is not in effect.

**Smaller:** `docs/IMPORT.md` is a runbook that names, for each guarantee, what enforces it. `make ready`, the GitLab setup summary and the docs describe both credential options, `NSX_CA_FILE`, and the exposure of unprotected plan variables. `readiness.sh` stops if it cannot change into the repository. The selftest check that re-running the generator changes nothing now actually compares the files, and every generated shell script is shellchecked. Variable-based credentials are wired for GitLab; the generated GitHub workflow still uses Vault.

**Upgrading:** an open import tranche written by an earlier release (`stacks/<stack>/import.tf`) keeps working and still puts the stack in import-only mode for every manager; finish and delete it as before. A tree that runs `tf.sh` by hand needs nothing: the first run re-initialises once. A plan saved by an earlier release has no record of its manager, so `apply` refuses it: plan again.

## 1.2.7

**NSX credentials can come from masked GitLab CI/CD variables, with nothing stored on the runner host.** `scripts/with-credentials.sh` now defaults to `--from auto`: Vault when `VAULT_ADDR` is set (unchanged), otherwise the environment, otherwise an error that names the variables to set. In the environment the first complete pair wins: `NSX_<SITE>_<SCOPE>_USERNAME` / `_PASSWORD`, then `NSX_<SITE>_...`, then `NSX_<SCOPE>_...`, then `NSX_USERNAME` / `NSX_PASSWORD`, where SITE is the manager key upper-cased (`hyd-gm01` becomes `HYD_GM01`) and SCOPE is `PLAN` or `APPLY`. The generated plan and apply jobs set `NSX_CRED_SCOPE`, so a read-only NSX account can sit in unprotected `NSX_PLAN_*` variables for merge request plans and the write account in protected `NSX_APPLY_*` variables. The GitLab state backend needs no secret: jobs use `CI_JOB_TOKEN`. Existing Vault setups need no change.

## 1.2.6

**On a GitLab merge request, the `managers` job failed with "downstream pipeline can not be created, the resulting pipeline would have been empty".** A child pipeline of a merge request pipeline is itself a merge request pipeline. Jobs with no `rules` default to `only: branches, tags`, which GitLab leaves out of one, so every generated plan job was filtered out even though `generated-pipeline.yml` was valid. The generated child pipeline now starts with `workflow: rules: - when: always`. After `scripts/update.sh`, push a new commit to the merge request to get a fresh pipeline.

## 1.2.5

**Git clone failed with `Problem with the SSL CA cert (path? access rights?)`.** Git was pointed at `CI_SERVER_TLS_CA_FILE` on a path the helper could not read. Registration now copies that file into the helper temp dir before fetch and sets `sslCAInfo` only for this GitLab URL. The bundle installed in the runner is chmod 644, and converge refuses to register if `/etc/gitlab-runner/certs/<GITLAB_HOST>.crt` is missing or not PEM. GitLab on another host: copy its `ca.crt` onto the runner machine and set `NSX_GITLAB_CA_FILE` in `deploy/gitlab/ci-network.env`, then converge.

## 1.2.4

**Jobs use the host proxy for the internet. The container config's only default is `NO_PROXY`.** `HTTP_PROXY` and `HTTPS_PROXY` are copied from the host (this shell, then the Docker daemon). If the host set only one, it is used for both. `NSX_HTTP_PROXY` and `NSX_HTTPS_PROXY` still override that.

`NO_PROXY` and `no_proxy` in the runner config are always the same default list: localhost, this host, GitLab, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. The host's own `NO_PROXY` is not copied into the container. `NSX_NO_PROXY` adds entries on top of that list. Git is no longer told to clear the proxy for the GitLab URL; private addresses stay direct because they are in `NO_PROXY`.

## 1.2.3

**Internal addresses stay off the proxy, in the runner config.** Whenever the runner is given a proxy, its `NO_PROXY` / `no_proxy` now always includes every private range (RFC 1918): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, plus this host and GitLab. Entries you already set are kept, and a range already listed is not added twice.

That list is part of the registered profile. `scripts/converge.sh` re-registers when it changes, so a later converge cannot put GitLab, NSX, or vCenter back through the corporate proxy. Public hosts (the Terraform registry, Docker Hub) still use the proxy.

## 1.2.2

**Jobs were still failing in a few seconds with exit code 1, all of them, the same way.** That message is what the runner prints when `git fetch` in the helper fails. The job script never starts, so every job looks identical.

The helper was sending the clone to the corporate proxy. `NO_PROXY` on this host lists GitLab's subnet as a CIDR, and the helper's git does not treat a CIDR as a bypass. Git also trusts only the CA file the runner injects, which replaces the system trust store, so a proxy that re-signs TLS fails the clone even when the runner itself stays connected.

Registration now adds a `pre_get_sources_script`. Before fetch it tells git to skip the proxy for this GitLab (an empty `http.<url>.proxy` overrides `HTTPS_PROXY` for that URL) and to trust `CI_SERVER_TLS_CA_FILE`. The profile hash includes that script, so `scripts/converge.sh` re-registers an existing runner.

`scripts/ci-image.sh` no longer clears the image entrypoint while checking `nsx-ci:1`. A tag that is really the Terraform image (`terraform sh` → exit 1) fails the check and is rebuilt.

## 1.2.1

**Jobs were failing in a few seconds with exit code 1, all of them, the same way.** Two separate causes, both fixed:

- The job image's entrypoint was winning. GitLab starts a job with `sh -c`. On the Terraform image that runs `terraform sh`, which exits 1 immediately (`Terraform has no command named "sh"`). Every job now sets an empty entrypoint, so the shell actually runs. This still matters if `nsx-ci:1` on the host is a leftover Terraform image.
- Git clones were trusting only the GitLab CA. The runner itself trusts that CA *and* the host trust store, so it stays connected through a TLS-inspecting proxy. Git in the job does not: `sslCAInfo` replaces the system store. The CA file installed in the runner is now the GitLab CA plus the host bundle, which is what the job's git is given. `scripts/converge.sh` refreshes it on an already-registered runner.

A provider download that fails because the proxy refused it (403, timeout, handshake) is reported as the existing warning (exit 42), not as a hard failure. A constraint that matches no release is still a hard failure.

## 1.2.0

**Pipeline jobs no longer download anything.** The first jobs on a real runner
failed twice over (`Terraform has no command named "sh"`, then `apk add` timing
out on a network that only allows Docker Hub). The pipeline now runs in one image
(`nsx-ci:1`: Python, Terraform, bash, curl, git) that `converge` builds on the
runner host from Docker Hub images alone.

- Fixed: every job failed with `Terraform has no command named "sh"`.
- Fixed: `data` failed on the shipped example data when PyYAML was missing (the
  fallback YAML parser mishandled `{ scope: x, tag: y }`).
- New: `scripts/converge.sh` (run by `update.sh`) builds the CI image, registers
  or repairs the runner, applies proxy / CA / pull-policy settings found on the
  host, restarts GitLab or the runner only when their configuration changed, and
  checks from inside a job container whether Terraform providers can be reached.
- New: the `terraform` validate job reports "providers unreachable" as a
  warning (exit 42), never silently and never as a hard failure. Plan and apply
  need providers; the converge report says what to set. For networks without
  access to registry.terraform.io, set the CI/CD variable `NSX_TF_NETWORK_MIRROR`
  (an internal mirror) or `NSX_TF_FS_MIRROR`.
- New: `deploy/gitlab/ci-network.env` (optional, never overwritten) for proxy
  settings: `NSX_HTTP_PROXY`, `NSX_HTTPS_PROXY`, `NSX_NO_PROXY`. Without it the
  proxy is taken from the shell, then from the Docker daemon.
- New: `update.sh` shows these release notes, and records the release a tree is at.
- Changed: `update.sh` runs `converge.sh` at the end (`--no-converge` skips it).
- First `update.sh` after this release rebuilds nothing you edited: files you
  changed stay as they are and are listed.

Needs on the host: Docker, and a route from Docker to Docker Hub (a proxy
configured for the Docker daemon is fine). The CI image is about 1.6 GB on disk.

## 1.1.0

- `scripts/update.sh`: preview and apply updates to an existing tree.
- `scripts/gitlab-https.sh`: HTTPS on 8443 with an internal CA and automatic renewal.
- Local GitLab: removed the `grafana` setting GitLab 17 rejects; the runner is on
  the host network so it registers against `127.0.0.1`.
