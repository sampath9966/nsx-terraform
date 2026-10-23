# NSX Terraform architecture

Architecture, conventions, and operating rules for this repository.

---

## 1. What this repository is

Terraform for **NSX administration across a multi-VCF estate**:

- **Multiple VCF instances**, each with its own SDDC Manager.
- **More than 10 NSX Local Managers (LMs)** — networking (T0/T1, segments) is
  managed per-LM.
- **NSX Global Manager(s) (GM)** in Federation, centrally owning the
  **distributed firewall (DFW)** policy across all sites.
- **Daily DFW rule changes** driven by static and dynamic groups, where dynamic
  membership resolves from **tags on VMs and on segments/subnets**.
- **Credentials fetched at run time from VCF via API** and held in Vault or in
  memory — never statically stored in this repository or in any tracked file.

Longer term this repository is intended to grow beyond NSX into managing the
VCF estate as a whole (workload domains, clusters, hosts). Section 13 covers
how to keep that from destabilizing the NSX layer.

### Current state — read before you act

**The scaffold exists; it has never touched a live manager.**
`scripts/bootstrap.sh` generates the whole structure below — modules, stacks,
schemas, tooling, CI, and worked example data — into whatever directory it is
run in. Everything it writes has been checked offline:

- `terraform fmt -check` is clean and all five stacks pass `terraform validate`
  against the real `vmware/nsxt` provider (3.12.0, resolved from `~> 3.9`).
- The data → module wiring evaluates: group and policy filtering by owner and
  site was confirmed with `terraform console`.
- `scripts/validate-data.py` passes on the example data and was tested against
  deliberately broken data.

What that verification does **not** cover, and what remains untrue until someone
does it:

- **No `terraform plan` has ever run against an NSX manager.** Provider schema
  validity is not API validity.
- **No `.terraform.lock.hcl` is committed.** Run `terraform init` in a stack and
  commit the lock file — an unpinned provider across 10+ managers means
  different sites realize different behaviour.
- **The state backend is still the placeholder local backend** (open decision
  1). `scripts/tf.sh` refuses to apply through it without `ALLOW_LOCAL_STATE=1`.
- **`inventory/managers.yaml` and everything under `data/` is example content**,
  shaped realistically but describing no real site. Replace it.

Consequences for you:

- Verify with `ls` before referencing any path.
- Section 16 lists every command that exists. Do not invent others.
- As real code lands, **replace** the speculative parts of this file with what
  was actually built. Prune what turned out not to apply.

The repository name `nsx-terrafrom` contains a typo for "terraform". Reproduce
it verbatim in remotes and CI config; renaming is the owner's call.

---

## 2. Ten things that will break this repository if ignored

These are the failure modes specific to an estate this size. Most of them are
irreversible or outage-causing, so they come before the pleasant parts.

1. **Never use `count` or list indices for firewall rules or groups.** Use
   `for_each` over a map with stable string keys. With `count`, inserting a
   rule in the middle shifts every index below it and Terraform destroys and
   recreates every downstream rule — on a DFW that is a live traffic outage.
2. **Never manage per-VM tags in Terraform at scale, or alongside another
   tagger.** `nsxt_policy_vm_tags` takes ownership of a VM's *entire* tag set,
   so it will fight VCF automation or a CMDB and lose slowly. `data/vm-tags/` is
   for bounded sets of VMs that nothing else tags; at estate scale, tags come
   from the provisioning system and this repository consumes them. Sections 7
   and `docs/TAGGING.md`.
3. **Never pass a secret through a Terraform data source.** The `vault_*` data
   sources write the fetched secret into state in plaintext. Credentials enter
   the process as environment variables set by the pipeline. See section 9.
4. **Never mix inline `rule` blocks with standalone rule resources on the same
   policy.** The provider docs are explicit: *"don't use this resource and
   resource `nsxt_policy_security_policy` to manage rules under a security
   policy at the same time."* Pick one per policy; see section 6.
5. **Never let GM and LM stacks manage the same object.** Federation makes
   GM-created objects read-only on the Local Managers. Two stacks pointed at
   one object produces permanent drift and failed applies.
6. **Never modify the default rule in a routine change.** Flipping the default
   from ALLOW to DROP, or deleting it, black-holes a datacenter. That change is
   restricted (section 11).
7. **Never run `apply` on your own initiative.** Produce a plan, show it, let a
   human decide. Same for `destroy`, `state rm`, and `state mv` — the state
   commands silently orphan live NSX objects.
8. **Never put daily DFW churn in the same state as T0s or transport zones.**
   Change cadence dictates state boundaries (section 4). A rule edit should
   never require refreshing the platform layer.
9. **Never stack 10+ provider aliases in one root module.** One provider
   instance addresses one manager. A root module spanning every LM has a plan
   time measured in tens of minutes and a blast radius of the whole estate.
10. **Always set `scope` ("Apply To") on policies and rules.** An unscoped DFW
    rule is pushed to every hypervisor in the span. Across 10+ managers that
    exhausts host-side rule capacity and makes every apply slower.

---

## 3. Provider

Verified against the current `vmware/nsxt` provider documentation.

```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.9"   # pin exactly; verify the floor before bumping
    }
  }
}
```

Pin the provider and **commit `.terraform.lock.hcl`**. An unpinned provider
across 10+ managers means different sites realize different behaviour.

### Provider configuration and environment variables

| Argument | Env var | Notes |
|---|---|---|
| `host` | `NSXT_MANAGER_HOST` | Manager FQDN. Required. |
| `username` | `NSXT_USERNAME` | Required (unless cert auth). |
| `password` | `NSXT_PASSWORD` | Required (unless cert auth). |
| `allow_unverified_ssl` | `NSXT_ALLOW_UNVERIFIED_SSL` | Lab only. Never `true` in committed config for a production manager. |
| `client_auth_cert` | `NSXT_CLIENT_AUTH_CERT` | Preferred over passwords where VCF can issue certs. |
| `client_auth_key` | `NSXT_CLIENT_AUTH_KEY` | |
| `session_auth` | `NSXT_SESSION_AUTH` | Keep enabled — avoids re-auth per request, materially faster on large plans. |
| `max_retries` | `NSXT_MAX_RETRIES` | Default 4. Raise for GM. |
| `retry_min_delay` | `NSXT_RETRY_MIN_DELAY` | ms, default 0. |
| `retry_max_delay` | `NSXT_RETRY_MAX_DELAY` | ms, default 500. Raise for GM. |
| `global_manager` | *(no env var)* | `true` for a GM endpoint. Default `false`. |

**Never write credential arguments into `.tf` files.** Configure the provider
as an empty block and let the environment supply everything:

```hcl
provider "nsxt" {
  # host / username / password come from NSXT_* env vars set by the pipeline
  # from Vault. Nothing sensitive is ever written here.
  max_retries     = 6
  retry_max_delay = 5000
}
```

### Global Manager specifics

Set `global_manager = true` **only** in the GM stacks. The provider docs
recommend raising retry values against a GM because Federation realization is
slower — a policy accepted by the GM API is not yet realized at every site, and
under-tuned retries surface that as spurious errors. Start at `max_retries = 6`
and `retry_max_delay = 5000`.

Also lower parallelism against a single manager. The NSX API is the bottleneck
and the default of 10 causes throttling on large plans:

```bash
terraform apply -parallelism=5 tfplan
```

### Use the policy API, always

Use `nsxt_policy_*` resources exclusively. Do not introduce the legacy manager
resources (`nsxt_logical_switch`, `nsxt_firewall_section`, …) — they target the
imperative API, are not Federation-aware, and cannot be mixed coherently with
policy objects.

---

## 4. Repository structure

Created by `scripts/bootstrap.sh`. Re-running it is safe: it never deletes, and
it keeps any file you have edited unless `--force` is given.

```
inventory/
  managers.yaml            # single registry of every GM and LM: site, region,
                           # VCF instance, endpoint, vault path, tier
data/
  groups/                  # group definitions (static + dynamic), per domain/app
  policies/                # DFW policies and rules, per application
  services/                # reusable service definitions
  network/                 # per-site segments and T1s        (local-network)
  platform/                # per-site T0s and below           (platform)
  vm-tags/                 # per-site VM tag assignments      (local-tags)
  schema/                  # JSON Schema for everything in data/, enforced in CI
                           # plus tag-scopes.yaml, the tag vocabulary
modules/
  dfw-policy/              # parent policy + rules from data
  group/                   # group with tag criteria
  service/                 # custom L4/ICMP services
  segment/
  vm-tags/                 # VM tags, where Terraform is the only tagger
  tier1/
  tier0/
stacks/
  global-security/         # GM: federated DFW. One state.
  local-security/          # per-LM: local-only DFW. One state per LM.
  local-tags/              # per-LM: VM tags. One state per LM.
  local-network/           # per-LM: segments, T1s. One state per LM.
  platform/                # per-LM: T0, transport zones, edge clusters.
envs/
  <site>.backend.hcl       # partial backend config, one per manager
scripts/                   # bootstrap, validation, CI matrix, credentials
docs/STRUCTURE.md          # what each directory is for
.github/workflows/
```

`data/network/` and `data/platform/` are keyed by site: the stack loads
`data/<kind>/${var.site}.yaml`, and a site with no file plans clean and manages
nothing.

### Why the state is split this way

State boundaries follow **change cadence and blast radius**, not just topology:

| Stack | Cadence | Blast radius | Who approves |
|---|---|---|---|
| `global-security` | daily | all sites | security review |
| `local-security` | weekly | one site | site owner |
| `local-tags` | daily | the VMs listed | site owner |
| `local-network` | weekly | one site | network owner |
| `platform` | rarely | one site, total | change advisory |

A daily DFW rule edit must never require Terraform to refresh transport zones.
Refresh cost is per-state, and the platform layer is the slowest and the most
dangerous thing in the estate.

`local-tags` is split from `local-security` on the same grounds: tagging churns
daily and its blast radius is the listed VMs, so sharing a state would make
every tag edit refresh every policy. The two need no Terraform dependency — NSX
evaluates dynamic membership server-side, so a tag lands and group membership
follows without `local-security` running.

### Addressing 10+ managers without alias sprawl

One root module per stack, instantiated **once per manager** by the pipeline
using partial backend config — not 10+ aliased providers in a single root.

```bash
terraform init -backend-config=envs/${SITE}.backend.hcl
terraform plan -out=tfplan
```

CI iterates a matrix generated from `inventory/managers.yaml`, so adding an
eleventh LM is a data change, not a code change. Sites are independent: one
site's failure does not block the others.

If the DRY-ness of that becomes painful, Terragrunt is the reasonable
alternative — but it is an added tool and an added failure mode. Prefer the
matrix until it demonstrably hurts. **This is an open decision (section 14).**

---

## 5. Federation: the GM/LM ownership boundary

This is the single most important architectural rule in the repository, because
Federation enforces it at the API level: **objects created on the Global
Manager are read-only on the Local Managers.**

Write the split down explicitly and never blur it:

| Object | Owner |
|---|---|
| DFW policies in Infrastructure / Environment / Application categories | **GM** (`global-security`) |
| Global groups spanning multiple sites | **GM** |
| Emergency-category quarantine policy | **GM** (see section 11) |
| Site-local DFW exceptions | **LM** (`local-security`) |
| Segments, T1 gateways | **LM** (`local-network`) |
| T0, transport zones, edge clusters | **LM** (`platform`) |

Rules for keeping the boundary intact:

- A group referenced by a GM policy must be **created on the GM**. Referencing
  an LM-local group from a GM policy does not work across the span.
- GM objects carry a **span** determined by their `domain`. On a GM the `domain`
  argument accepts a domain ID **or a site ID**; it defaults to `default`. Set
  it explicitly in every GM resource — an accidental default-domain object has
  estate-wide span.
- GM and LM policies coexist within the same categories. **Confirm the exact
  precedence between GM and LM sections for your NSX version before relying on
  cross-boundary rule ordering** — do not assume it from this document.
- If an object must move from LM to GM ownership, that is a delete-and-recreate
  across two states, with a traffic impact window. Treat it as a restricted
  change, never a routine one.

---

## 6. DFW policies and rules

### A policy is reused, never recreated

A new rule for policy X goes **into policy X**. It never justifies a second
policy X.

This sounds obvious and is the most common way these repositories go wrong: two
data files describe the same policy, so NSX ends up with two policies of the
same name and different `nsx_id`s, in the same category, with overlapping
sequence numbers. Traffic then matches whichever won the ordering, and the rule
someone added appears to do nothing.

Three mechanisms enforce it, so it does not rest on anybody remembering:

1. **Look it up first.** `scripts/add-rule.py --policy <id-or-name>` searches
   every file in `data/policies/`, appends to the one that already holds the
   policy, and allocates the next free sequence number. A policy it cannot find
   is an error listing what does exist — creating one requires an explicit
   `--create-policy`, because a new policy means a new category placement, a new
   ordering and a new blast radius.
2. **Duplicates fail validation.** `make validate` errors when two data files
   declare the same policy name, category, owner and span, even under different
   ids, and names the file that already has it.
3. **The resource cannot be destroyed by a routine change.** The parent policy
   carries `prevent_destroy = true`. Nothing in an ordinary data edit can drop a
   policy and rebuild it — including the silent replacements, since changing
   `category` or `domain` forces a new policy and would take every rule with it.
   Retiring a policy means removing that line in a reviewed commit: deliberate
   friction, because policy deletion is not routine.

The same principle is what makes import work — an imported policy keeps its real
`nsx_id`, so Terraform writes new rules into the policy you already run rather
than building a parallel one.

### Use the parent-policy + standalone-rule pattern

For any policy with **daily churn**, use:

- `nsxt_policy_parent_security_policy` — the policy container, and
- `nsxt_policy_security_policy_rule` — one resource per rule.

This is what makes daily rule changes safe: a single rule can be added or
removed without Terraform touching the rest of the policy. The alternative,
`nsxt_policy_security_policy` with inline `rule` blocks, rewrites the whole
policy on every change.

**The provider forbids mixing them on the same policy** — *"don't use this
resource and resource `nsxt_policy_security_policy` to manage rules under a
security policy at the same time."* Choose per policy and record the choice in
the policy's data file. Inline blocks remain fine for small, static policies
that change once a quarter.

### Sequence numbers

- Start at 100, increment by 100. Gaps let a rule be inserted between two
  existing rules without renumbering anything.
- Never 0 — the provider docs call out that sequence numbers should start at 1
  rather than 0 to avoid confusion.
- Sequence numbers live in the rule's data file and are **allocated, not
  guessed**. CI rejects duplicates within a policy.

### Always set `scope`

`scope` is NSX's "Apply To". Without it, a rule is distributed to every
hypervisor in the policy's span — across a multi-site Federation that is a very
large number of hosts, and host rule capacity is finite.

Scope every policy to the group of workloads it protects. This is a hard
convention, not an optimization.

### Rule shape

```hcl
resource "nsxt_policy_security_policy_rule" "this" {
  for_each = local.rules            # map keyed by stable rule id — never count

  display_name     = each.value.name
  policy_path      = nsxt_policy_parent_security_policy.this.path
  sequence_number  = each.value.sequence_number

  action           = each.value.action        # ALLOW | DROP | REJECT | JUMP_TO_APPLICATION
  direction        = each.value.direction     # IN | OUT | IN_OUT
  ip_version       = "IPV4_IPV6"
  disabled         = try(each.value.disabled, false)
  logged           = try(each.value.logged, true)

  source_groups      = each.value.source_groups
  destination_groups = each.value.destination_groups
  services           = each.value.services
  scope              = each.value.scope       # mandatory — see above
}
```

### Set `nsx_id` explicitly

Give resources a deterministic `nsx_id` derived from the data key. Without it,
NSX generates one, and a later `display_name` change can turn into a
destroy-and-recreate. With it, renames are metadata-only.

---

## 7. Groups, tags, and membership

### The tag ownership decision — read this before writing any tagging code

`nsxt_policy_vm_tags` **takes ownership of a VM's entire tag set.** The provider
docs state that deleting the resource *"will remove all tags from the Virtual
Machine"*. There is no per-tag ownership model.

In an estate with VCF automation, vSphere tag sync, backup tooling, and a CMDB,
that guarantees a fight: whichever system writes last wins, and Terraform will
report drift forever.

**Therefore: Terraform does not tag VMs at scale in this repository.**

Beyond correctness, this is a scale decision: a `nsxt_policy_vm_tags` resource
per VM across 10+ managers means tens of thousands of state entries and refresh
times that make daily changes impossible.

That leaves two supported arrangements. **`docs/TAGGING.md` is the full
treatment**; the summary is:

| | Variant A — *default* | Variant B |
|---|---|---|
| Who tags | VCF/vRA automation, CMDB sync, provisioning | this repository |
| Where | the source of truth | `data/vm-tags/<site>.yaml` |
| Applied by | that system | `stacks/local-tags` |
| Good for | the estate | bounded exception sets |
| Ceiling | none | a few hundred VMs |

- **Variant A**: tags are applied at the source of truth, and Terraform owns
  groups and policies which *consume* them through dynamic criteria. This
  repository still owns the vocabulary those tags must use.
- **Variant B**: for VMs that nothing else tags — hand-built servers,
  appliances, workloads not onboarded to a CMDB, and quarantine. Engineers tag
  through `make tag-vm`, review it as a data change, and never open the NSX UI.

**Neither variant requires the NSX UI.** The choice is which system is the
source of truth, not whether tagging is automated.

The boundary is enforced, not documented: every scope in
`data/schema/tag-scopes.yaml` records the system that owns it, and
`make validate` **errors** if `data/vm-tags/` writes a scope whose owner is not
`terraform`. Moving a scope across that line is a reviewed change, and the
review question is the right one — *are we certain nothing else tags these VMs?*

Mixing is per **VM**, never per tag: a VM is wholly Terraform-tagged or it is
not. The resource has no per-tag ownership, so there is no half.

Segment tags are different — segments are Terraform-owned infrastructure, so
tagging them inline in the `nsxt_policy_segment` resource is correct and
expected.

### Tag scope vocabulary is a controlled interface

Group criteria match on `scope|value`, so **a tag scope is an API contract
between the tagging system and this repository.** Renaming a scope silently
empties every group that matches it, which silently drops traffic.

Maintain the closed vocabulary in `data/schema/tag-scopes.yaml`. Suggested
starting set:

| Scope | Example value | Meaning |
|---|---|---|
| `env` | `prod`, `nonprod` | environment |
| `app` | `payments` | application identity |
| `tier` | `web`, `app`, `db` | role within the app |
| `zone` | `dmz`, `internal` | trust zone |
| `owner` | `team-x` | accountable team |
| `compliance` | `pci` | regulatory scope |
| `quarantine` | `active` | incident response |

Adding a scope is a reviewed change. Renaming or removing one is **restricted**
(section 11) and requires proving no group criteria reference it.

### Dynamic groups

Verified criteria syntax — note the `scope|value` format:

```hcl
resource "nsxt_policy_group" "app_web" {
  display_name = "prod-payments-web"
  domain       = var.domain          # explicit on GM: domain ID or site ID

  criteria {
    condition {
      key         = "Tag"
      member_type = "VirtualMachine"
      operator    = "EQUALS"
      value       = "app|payments"   # scope|value
    }
    condition {
      key         = "Tag"
      member_type = "VirtualMachine"
      operator    = "EQUALS"
      value       = "tier|web"
    }
  }
}
```

Conditions within one `criteria` block are ANDed. Multiple `criteria` blocks
are joined by an explicit `conjunction` of `AND` or `OR`.

- Operators: `EQUALS`, `NOTEQUALS`, `CONTAINS`, `STARTSWITH`, `ENDSWITH`, `IN`,
  `NOTIN`, `MATCHES`.
- Member types include `VirtualMachine`, `Segment`, `SegmentPort`,
  `LogicalPort`, `LogicalSwitch`, `IPSet`, `IPAddress`, `Group`, `DVPG`,
  `DVPort`, `TransportNode`, `BareMetalServer`, plus Kubernetes/Antrea types.
- Prefer `EQUALS` over `CONTAINS` / `STARTSWITH`. Substring matching on tags is
  how a group silently acquires unintended members — `app|payments` should not
  also match `app|payments-test`.

**Subnet-based membership**: match `member_type = "Segment"` on a segment tag,
rather than hardcoding CIDRs. The segment is Terraform-owned, so its tags are
reliable; a CIDR in a group is a duplicated fact that will drift from the
segment's actual definition.

### Static groups

Use static membership (explicit paths or IP addresses) only where dynamic
criteria genuinely cannot express the set — physical appliances, external
partner ranges, third-party endpoints. Every static group carries a comment
explaining why it is static and what would let it become dynamic. Static
membership is a maintenance liability: nothing updates it when the estate
changes.

---

## 8. Rules as data

Daily DFW changes are **data edits, not HCL edits.** A rule change should touch
one YAML file and no Terraform code.

```yaml
# data/policies/payments.yaml
policy:
  id: prod-payments                  # deterministic nsx_id; never changes
  name: prod-payments                # display_name; renaming is metadata-only
  category: Application
  owner: gm                          # gm | lm — which side of the boundary
  scope: [prod-payments-all]         # mandatory Apply To
  rule_management: standalone        # standalone | inline — never both

rules:
  web-from-lb:
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [prod-lb]
    destination_groups: [prod-payments-web]
    services: [https]
    scope: [prod-payments-web]
    logged: true
```

Rules for this layer:

- **Map keys are the stable identity.** `web-from-lb` is the Terraform address.
  Renaming a key destroys and recreates the rule; changing a *value* updates it
  in place. Never renumber keys.
- **`owner` decides which stack picks the policy up.** `gm` goes to
  `global-security`; `lm` requires a `sites` list and goes to `local-security`
  at those sites only.
- **CI validates against JSON Schema** in `data/schema/` before any plan runs —
  `make schema-validate`, which also checks what a schema cannot express:
  sequence numbers unique per policy, every referenced group and service
  defined, `scope` non-empty, tag scopes in the vocabulary, no raw policy path
  or credential pasted into a data file, and no GM policy referencing a
  site-local group.
- **Group and service references are by logical name**, resolved to policy paths
  in the module. Never paste raw policy paths into data files.
- A schema violation fails the PR. This is the cheapest place to catch a
  malformed rule, and the only place before it reaches a live firewall.

---

## 9. Credentials: VCF → Vault → environment

The requirement is that nothing is statically stored. The pattern that actually
achieves this:

```
SDDC Manager API  →  pipeline step  →  Vault  →  env vars  →  terraform
   (credentials)      (short-lived)              (NSXT_*)      (in memory)
```

1. The pipeline authenticates to SDDC Manager and retrieves the NSX manager
   credentials for the target site via the VCF credentials API.
2. Credentials are written to / read from Vault at a per-manager path recorded
   in `inventory/managers.yaml` (the **path**, never the secret).
3. The pipeline exports `NSXT_MANAGER_HOST`, `NSXT_USERNAME`, `NSXT_PASSWORD`
   into the Terraform process environment.
4. Terraform reads them implicitly. They appear in no file, no variable, and no
   resource attribute.

### Course corrections that matter here

- **Do not use the `vault` Terraform provider's data sources for this.** A
  `data "vault_kv_secret_v2"` writes the retrieved secret into Terraform state
  in plaintext. It looks like the clean solution and it is the opposite of one.
  Fetch outside Terraform.
- **Do not pass credentials as `TF_VAR_*` into provider arguments.** Even marked
  `sensitive = true`, values reaching resource attributes land in state and in
  saved plan files. `sensitive` only redacts CLI output.
- **State is sensitive regardless.** Even with perfect credential hygiene, NSX
  state contains your full security posture. Require: remote backend, encryption
  at rest, state locking, access restricted to the pipeline identity, and no
  local `terraform.tfstate` ever committed.
- **Saved plan files are sensitive too.** `tfplan` contains resource data.
  Treat it as a secret artifact with short retention; never attach it raw to a
  PR comment — post the rendered human-readable summary instead.
- **Prefer short-lived credentials.** Vault dynamic secrets or a rotated VCF
  service account beats a long-lived password in a KV store. Where VCF can issue
  client certificates, `client_auth_cert` is stronger than any password path.
- **Least privilege per stack.** The plan-time identity should be read-only; only
  the apply identity needs write. This is what makes it safe to run plans
  automatically on every PR.

### `.gitignore` must include

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars          # except *.example.tfvars
tfplan
*.tfplan
crash.log
```

`.terraform.lock.hcl` **is** committed — it is the provider pin, not a secret.

---

## 10. Daily workflow

### Adding or changing a DFW rule (the routine case)

```bash
# 1. Edit the data file — not HCL
$EDITOR data/policies/payments.yaml

# 2. Local validation (no credentials, no network)
make validate                 # = schema-validate + fmt-check

# 3. Open a PR. CI plans against the GM with read-only credentials
#    and posts the rendered plan summary.

# 4. Review the plan — see the checklist below.

# 5. Merge. Apply runs against the plan artifact, in a change window.
```

### Plan review checklist — apply this every time

Before approving any DFW plan, confirm:

- [ ] The resource **count delta** matches the intent. An unexpected count is
      the signature of an index/`for_each` key problem — stop and investigate.
- [ ] **No unexpected destroys.** A destroy on a rule you did not touch means
      keys shifted. Never approve through this.
- [ ] **No change to the default rule** and no change to Emergency category.
- [ ] Every new or changed rule has a **non-empty `scope`**.
- [ ] Group criteria changes are checked for **membership blast radius** — a
      criteria edit can silently add or drop hundreds of VMs. Query effective
      membership in NSX before approving, not after.
- [ ] Sequence numbers do not collide and preserve intended ordering.
- [ ] The change touches **one site's state** unless it is deliberately global.

### Manual commands, when a human asks for them

```bash
# Through the wrapper — resolves host and domain from the inventory, keeps one
# state per stack per manager, and enforces the guardrails below.
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
scripts/tf.sh show local-security lon1
APPROVE=yes scripts/with-credentials.sh lon1 -- scripts/tf.sh apply local-security lon1

# The same thing by hand.
cd stacks/local-security
terraform init -backend-config=../../envs/${SITE}.backend.hcl
terraform plan -out=tfplan -parallelism=5
terraform apply -parallelism=5 tfplan
```

Always `plan -out` then `apply <file>`. Never a bare `terraform apply` — it
re-plans at apply time and can execute something nobody reviewed. `scripts/tf.sh
apply` enforces this: it refuses without a saved plan, refuses without
`APPROVE=yes`, and refuses to apply through the placeholder local backend.

**`-target` is not a workflow.** If plans are slow enough that targeting is
tempting, the stack is too big — split it (section 4).

---

## 11. Change classes

| Class | Examples | Path |
|---|---|---|
| **Routine** | Add/remove a rule in an existing app policy; add a member to a static group | Data PR, one reviewer, standard window |
| **Elevated** | New policy or category; new/changed group criteria; new segment; new tag scope | Data + code PR, security review, membership impact assessed |
| **Restricted** | Default rule; Emergency category; tag scope rename or removal; GM↔LM ownership move; T0 / transport zone / edge; anything in `platform` | Change advisory, named approver, rollback plan, out-of-hours |

Automation may prepare any class of change. It may only *apply* changes
when a human has explicitly approved that specific plan — and never restricted
ones.

### Emergency / quarantine path

Keep a standing GM policy in the **Emergency** category, containing a deny rule
sourced from a group whose criteria match `quarantine|active`. Incident response
then means applying one tag to a VM — no Terraform run, no PR, no plan.

Terraform owns the *mechanism*; operators use it without Terraform in the loop.
This is deliberate: incident response must not depend on a pipeline being
healthy. This is the one place `nsxt_policy_vm_tags` may legitimately be used
from automation.

---

## 12. Brownfield import and drift

The estate exists already. This repository will not start from an empty NSX.

**`docs/IMPORT.md` is the step-by-step walkthrough.** The short version:

```bash
# 1. capture (read-only; reports/ is gitignored)
scripts/with-credentials.sh lon1 -- scripts/import-estate.py \
    --site lon1 --dump-only reports/lon1-raw.json

# 2. convert to data files + import blocks
scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json

# 3. verify, then import one tranche
make validate
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
```

The principle is **adopt, never recreate**. `scripts/import-estate.py` reads
groups, policies, rules and services from the manager and writes them out as
data plus Terraform `import` blocks, adopting each object's real `nsx_id`
verbatim — mixed case and underscores included, because the key must match or
the import misses and Terraform builds a duplicate beside the original. The
naming convention in section 15 governs objects created from here on; the
validator reads `data/.import-manifest.json` and knows the difference.

Import in tranches: one policy or one site at a time. A tranche is done when
`terraform plan` reports **no changes** — not when it applies cleanly. A
*create* in an import plan means Terraform did not recognise something that
exists; stop rather than apply, or you get the duplicate the whole exercise is
meant to avoid.

The import id format has varied across provider versions. The converter emits
`path` by default and can emit `domain-id` or `id`; a wrong choice fails at plan
time before anything reaches state, so confirm it on the pilot.

### Imported data is yours, and nothing overwrites it

Enforced, not just documented:

- `bootstrap.sh --force` refreshes its own output — modules, stacks, scripts, CI
  — and **never** touches `data/`, `inventory/` or `envs/`. `--force-data` is
  needed for those, and it still refuses outright for any file recorded in
  `data/.import-manifest.json`.
- Re-running the importer over an existing file writes `<name>.new` beside it
  and leaves yours alone.
- Drift detection is strictly read-only (below).

### Drift

Administrators will make UI changes, especially during incidents. Expect it.

- Run a **scheduled plan** per stack and report drift; do not auto-revert. An
  auto-revert during an active incident undoes the fix someone applied to stop
  an outage. `scripts/drift.sh` does exactly this and no more: a refresh-only
  plan, a report in `reports/`, exit code 2 when something diverged. It never
  reverts, and it never writes back into `data/` — a tool that rewrote your data
  files on a drift signal would silently overwrite the estate you imported.
- Treat detected drift as a ticket: either bring the change into code or revert
  it deliberately.
- Use `lifecycle.ignore_changes` sparingly and always with a comment naming the
  system that owns the ignored field. An unexplained `ignore_changes` becomes
  permanent invisible divergence.
- Never resolve drift with `state rm`. That orphans a live object that nothing
  then manages.

---

## 13. Growing into VCF-wide management

When this repository expands to VCF itself (workload domains, clusters, hosts),
keep it a **separate stack tier with its own state and its own pipeline**:

- The `vmware/vcf` provider targets SDDC Manager and is a different lifecycle
  entirely — host commissioning is not a daily activity and must never share a
  state file or an apply cadence with DFW rules.
- **NSX modules must not depend on VCF modules.** Pass what is needed
  (endpoints, IDs) through `inventory/managers.yaml` as data, not through
  cross-stack `terraform_remote_state` reads. Remote state coupling would make a
  daily firewall change depend on the availability and correctness of the
  platform state.
- Adding a workload domain should mean adding an entry to
  `inventory/managers.yaml`, after which the existing CI matrix picks it up.
  If it means editing Terraform code, the abstraction is wrong.

---

## 14. Open decisions

These need the owner's call. Do not assume an answer — ask.

1. **State backend** — which backend, where, and how is encryption and locking
   configured per site? *Unresolved.* `stacks/*/backend.tf` defaults to a
   placeholder `backend "local"` so the stacks initialise for offline
   validation; `scripts/tf.sh` blocks apply through it.

   `scripts/bootstrap.sh --force --backend gitlab|s3|azure|local` writes the
   chosen one; then fill in `envs/*.backend.hcl`. `http` is GitLab-managed
   Terraform state, which supplies locking, encryption at rest and version
   history with no object store to run — the least-effort option for a GitLab
   estate. `docs/SETUP.md` section 2.1 covers each.

   Three requirements, and the third is the one that gets skipped: encryption at
   rest, access limited to the pipeline identity, and **locking**. Up to ~50
   states across a 10-manager estate, planned in parallel by CI, means an
   unlocked backend will eventually be written by two runs at once. Filesystem
   state has no locking; state committed to a git repository has no locking
   *and* is plaintext in permanent history — `.gitignore` blocks `*.tfstate`.
   `make validate` errors on a credential in `envs/*.hcl` and on an `address`
   with no `lock_address`.
2. **Vault layout** — auth method for the pipeline, mount and path convention,
   static KV vs dynamic secrets. *Unresolved.* `scripts/with-credentials.sh`
   assumes KV v2 at the full path recorded per manager in the inventory.
3. **Terragrunt vs CI matrix** for multi-manager instantiation (section 4).
   *Provisionally: CI matrix*, generated by `scripts/ci-matrix.py`. Revisit only
   if the duplication demonstrably hurts.
4. **Category ownership** — does the GM own Environment *and* Application
   categories, or is Application delegated per site?
5. **Tagging source of truth** — which system authoritatively tags VMs, and does
   it already emit the scope vocabulary in section 7?
6. **Import scope and sequencing** — which site is the pilot, and is the whole
   DFW in scope or only new applications?
7. **Number of Global Managers** — one GM with standby, or several federations?
   This changes the `global-security` stack from one state to several.

---

## 15. Conventions

- **Naming**: `<env>-<site>-<app>-<role>`, lowercase, hyphen-separated, e.g.
  `prod-lon1-payments-web`. Terraform identifiers use `snake_case`. Name
  resources for role, not type — `nsxt_policy_group.app_web`, not `group_1`.
  Federated objects drop the site element — they span every site, so
  `prod-payments-web` is the whole name.
- **Modules**: each has `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`,
  `README.md`. Every variable gets a `description` and a `type`. Defaults only
  where a genuinely safe default exists — never for anything security-relevant.
- **Formatting**: `terraform fmt -recursive` before every commit.
- **Commits**: imperative subjects — "Add payments DFW policy". Reference the
  change ticket for elevated and restricted changes.
- **Branch and PR names**: `PR<epoch>`, where `<epoch>` is Unix seconds at the
  moment the branch is created — e.g. `PR1785271876`. The pull request carries
  the same name as its branch. Take the value once, when you create the branch,
  and reuse it for the PR; do not regenerate it later, or the two stop matching.

  ```bash
  BRANCH="PR$(date +%s)"
  git switch -c "$BRANCH"
  ```

  The name is an identifier, not a description — what the change does belongs in
  the commit subjects and the PR body.
- **PRs**: open as drafts until ready. One site or one application per PR — a PR
  spanning multiple sites cannot be rolled back cleanly.
- **Attribution**: every commit is authored *and* committed by the repository
  owner. No co-author trailers for tooling, and no generated-by footers in pull
  request bodies. `GIT_AUTHOR_*` and `GIT_COMMITTER_*` outrank `git config` and
  hosted environments do set them, so check the history rather than the config.
  This should print nothing — the owner is the only identity in the history,
  bar `GitHub <noreply@github.com>` on commits created through the web UI:

  ```bash
  git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u \
    | grep -vE 'sampath|^GitHub <noreply@github\.com>$'
  ```

## 16. Tooling

Every command below has been run. If you introduce more — `tflint`,
`tfsec`/`checkov`, another validator — document the exact invocation here **in
the same commit**. The value of this document is that nothing in it is
aspirational.

### Scaffolding

```bash
scripts/bootstrap.sh                  # interactive menu: basic / advanced / update
scripts/bootstrap.sh --interactive    # force the menu even with other flags
scripts/bootstrap.sh --no-interactive # never prompt; flags and defaults only
scripts/bootstrap.sh --dir PATH       # scaffold somewhere else
scripts/bootstrap.sh --dry-run        # report what would be written
scripts/bootstrap.sh --force          # refresh regenerated files only
scripts/bootstrap.sh --force-data     # also overwrite estate data (see below)
scripts/bootstrap.sh --confirm TEXT   # the overwrite phrase, for a pipeline
scripts/bootstrap.sh --no-examples    # structure and tooling, no example data
scripts/bootstrap.sh --backend TYPE   # gitlab | s3 | azure | local (aliases ok)
scripts/bootstrap.sh --vcs KIND       # gitlab (default) | gitlab-docker |
                                     #   github | git | none
scripts/bootstrap.sh --ci PLATFORM   # gitlab | github | both | none
scripts/bootstrap.sh --git-remote URL # attach 'origin'; implies --vcs git
scripts/bootstrap.sh --git-init       # also 'git init' if not already a repo
```

Run bare with a terminal it asks: basic (best practices assumed, three
questions), advanced (every option), or update an existing tree. Any flag
suppresses the menu, so scripts and CI are unaffected; without a terminal it
behaves exactly as it always did.

Self-contained: no network, no dependency on the repository it came from, bash
and coreutils only. Idempotent — an unchanged file is left alone, an edited one
is kept and reported (exit 2) unless `--force`. It never deletes anything.

**Nothing existing is overwritten without a flag AND a typed phrase.** With no
flag, a file whose content differs is kept and reported and the run exits 2.
With `--force` or `--force-data`, the first file that would actually be
overwritten stops the run and asks for `wipe everything & start fresh`, typed in
full; answering covers the rest of the run, anything else aborts with nothing
changed. Without a terminal it aborts rather than proceeding — a pipeline passes
`--confirm` or `BOOTSTRAP_CONFIRM` deliberately. A flag in shell history should
not be able to revert a tree somebody has spent months editing.

**`--force` cannot touch your estate.** It refreshes this script's own output —
modules, stacks, scripts, schemas, CI, docs — and leaves `data/`, `inventory/`
and `envs/` alone. Overwriting those needs `--force-data`, which still refuses
outright for anything recorded in `data/.import-manifest.json`. Imported estate
is never overwritten by this script, by any flag or phrase.

### Make targets

```bash
make help              # list targets
make preflight         # which required tools are present
make ready             # production readiness: exits 1 while anything blocks
make selftest          # prove the generator and validators, offline
make validate          # schema-validate + fmt-check. Offline, no credentials.
make schema-validate   # data/ and inventory/ only
make fmt               # terraform fmt -recursive .
make fmt-check         # fail if anything is unformatted
make matrix            # print the CI matrix from inventory/managers.yaml
make add-rule POLICY=prod-payments RULE=allow-x ARGS='--source a --destination b --scope b'
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make tags SITE=lon1                        # what is tagged from Terraform at this site
make import SITE=lon1 POLICY=legacy-app    # adopt one policy and what it needs (DUMP=file to convert offline)
make hand-back STACK=local-security ADDRESS='<address>'  # stop managing one object, without deleting it
make drift STACK=local-security SITE=lon1  # report drift; never reverts, never writes data/
make init  STACK=global-security SITE=gm1
make plan  STACK=global-security SITE=gm1
make show  STACK=global-security SITE=gm1
make apply STACK=global-security SITE=gm1   # needs APPROVE=yes
make clean             # remove local plan files and caches; never touches state
```

### Scripts

| Command | Does |
|---|---|
| `scripts/validate-data.py [--strict] [--quiet]` | Evaluates `data/schema/*.json` against every data file, then the semantic checks a schema cannot express. Exit 1 on error; `--strict` also fails on warnings. |
| `scripts/ci-matrix.py [--stack S] [--format json\|github\|lines]` | The run matrix from the inventory. |
| `scripts/ci-matrix.py --export SITE` | Shell exports (`NSX_HOST`, `NSX_VAULT_PATH`, …) for one manager. Paths, never secrets. |
| `scripts/tf.sh init\|plan\|show\|apply STACK SITE` | Terraform for one stack against one manager. `-parallelism=5`; override with `PARALLELISM`. |
| `scripts/with-credentials.sh SITE [--from vault\|vcf] -- CMD` | Fetches credentials, exports `NSXT_*`, execs `CMD`. Nothing written to disk. |
| `scripts/preflight.sh` | Reports missing tools. Read-only. |
| `scripts/selftest.sh [--quick]` | Proves what can be proved offline: the generator, every validator against planted defects, terraform fmt and validate, pipeline shape (no apply on a merge request, every apply manual), determinism, the overwrite guard, and that readiness refuses a fresh tree. 34 checks. Exits 1 on the first failure. |
| `scripts/readiness.sh [--quiet]` | Answers "is this ready for production": placeholder backend, missing lock files, example data still in place, no remote, state tracked in git, validation failing. Exits 1 while anything blocks. Also prints what it *cannot* check — branch protection, CI variables, and whether a plan has ever run against a manager. |
| `scripts/add-rule.py --policy P --rule R --scope G ...` | Adds a rule to the **existing** policy P, found by id or display name. Refuses if P does not exist unless `--create-policy`. `--dry-run` prints the block. |
| `scripts/tag-vm.py --site S --vm V --set SCOPE=VALUE` | Tags a VM as a data edit on `data/vm-tags/<site>.yaml`. Also `--unset SCOPE`, `--remove`, `--list`, `--dry-run`. Refuses any scope not owned by `terraform` in the vocabulary, and refuses to leave a VM with an empty tag set. |
| `scripts/import-estate.py --site S [--from-dump F]` | Adopts a live estate: data files, Terraform import blocks, and the import manifest. `--dump-only` captures without converting. Never overwrites — writes `<name>.new` instead. |
| `scripts/drift.sh STACK SITE` | Refresh-only plan, report to `reports/`. Exit 2 on drift. Never reverts, never writes `data/`. |
| `scripts/enable-gitops.sh [--remote URL\|--local-gitlab]` | Puts an existing tree under version control and turns on the review pipeline. The migration path for anything set up without it. Refuses to commit if state or plan files are present. |
| `scripts/gitlab-setup.sh --url U --token T --project G/N` | Makes a GitLab project ready: creates it (and the group), pushes, sets the CI variables with the apply token protected, protects the default branch, and creates the apply environments. Idempotent. Works against any GitLab; `gitlab-up.sh` calls it. `--dry-run` reports without changing anything. |
| `scripts/gitlab-up.sh [--status\|--password\|--down\|--destroy]` | Brings up GitLab CE and a runner in Docker, creates the project, pushes, registers the runner, prints the initial root password. For teams without a GitLab. Not a production deployment. |
| `scripts/gitlab-child-pipeline.py` | Emits the per-manager plan/apply jobs for GitLab from the inventory. Plans only on a merge request; plans plus **manual** applies on the default branch. |
| `scripts/post-plan-comment.sh STACK SITE FILE` | Posts a rendered plan onto the merge request. Never posts the plan file itself. No-op outside an MR or without `CI_API_TOKEN`. |
| `scripts/ci_matrix_lib.py` | The matrix itself, importable. `ci-matrix.py` and `gitlab-child-pipeline.py` both read it, so GitHub and GitLab cannot drift apart. |

`scripts/validate-data.py` and `scripts/ci-matrix.py` need only Python 3.9+;
PyYAML is used when importable and `scripts/yamlcompat.py` parses the committed
subset when it is not.

### Review pipeline

The pipeline that gets written follows the host, and **GitLab is the default**:
it is the only one this script can set up end to end — server, project, runner,
variables and approval gate. GitHub gets complete workflows but the secrets and
environment protection are the owner's to configure. `--vcs none` writes no
pipeline at all and leaves the manual `make plan` / `make apply` path, which
`scripts/tf.sh` still guards. The answer is recorded in `.nsx-bootstrap.conf` so
a re-run does not change the shape of the tree.


```bash
scripts/enable-gitops.sh --remote git@gitlab.example.com:net/nsx.git
scripts/enable-gitops.sh --local-gitlab      # stand GitLab up in Docker
scripts/gitlab-up.sh --status                # where it is, whether it is up
scripts/gitlab-up.sh --password              # the initial root password
python3 scripts/gitlab-child-pipeline.py     # the per-manager jobs, as YAML
```

A rule edit becomes a merge request, a plan per manager posted onto it, an
approval, a merge, and a **manual** apply of the plan that was approved — the
apply never re-plans. `docs/GITOPS.md` is the full flow, including the branch
protection and CI variables it depends on, which live on the git host rather
than in this repository.

### CI

- `.github/workflows/validate.yml` — every PR: `validate-data.py`, `fmt -check`,
  and `terraform validate` per stack. No credentials, no manager access.
- `.github/workflows/plan.yml` — every PR: plans each manager from the matrix in
  parallel with **read-only** credentials, and posts the rendered summary to the
  job summary. Never attaches the plan file. Requires `VAULT_ADDR` and
  `VAULT_PLAN_TOKEN` secrets, which are not yet configured.
