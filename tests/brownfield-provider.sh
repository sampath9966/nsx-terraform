#!/usr/bin/env bash
# Brownfield adoption against the REAL vmware/nsxt provider, with a read-only
# mock NSX standing in for a Local Manager (tests/mock_nsx.py).
#
#   tests/brownfield-provider.sh        (or: tests/run.sh --provider)
#
# Needs Terraform >= 1.9 on PATH (or downloads 1.9.8) and access to
# registry.terraform.io for the provider. A few minutes.
#
# It proves, with the real provider rather than fixtures: a manager with no data
# is untouched; an adoption imports and changes nothing; a plan cannot cross to
# another manager; a deleted rule or policy is refused; an approved deletion is
# allowed; an object can be handed back without deleting it; a wrong import id
# and a would-be duplicate are refused; and that NSX receives no write at all.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch

if ! command -v terraform >/dev/null 2>&1; then
	echo "terraform not found: downloading 1.9.8 for this run"
	mkdir -p "$SCRATCH/bin"
	curl -sSfL -o "$SCRATCH/tf.zip" https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip &&
		python3 -c "import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$SCRATCH/tf.zip" "$SCRATCH/bin" &&
		chmod +x "$SCRATCH/bin/terraform" || {
		echo "cannot get terraform"
		exit 1
	}
	export PATH="$SCRATCH/bin:$PATH"
fi

T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1
cat >inventory/managers.yaml <<'INV'
managers:
  lon1:
    role: lm
    host: lon1.example.net
    site: lon1
    vcf_instance: vcf-a
    vault_path: secret/nsx/lon1
    tier: prod
  nyc1:
    role: lm
    host: nyc1.example.net
    site: nyc1
    vcf_instance: vcf-a
    vault_path: secret/nsx/nyc1
    tier: prod
INV
mkdir -p reports
python3 - <<'PY'
import json
D = "/infra/domains/default"; SV = "/infra/services"
cond = lambda v: {"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}
def g(i, expr, **kw): return dict({"id": i, "path": f"{D}/groups/{i}", "display_name": i, "expression": expr}, **kw)
groups = [g("App-Web", [cond("app|web")], tags=[{"scope": "owner", "tag": "team-a"}]), g("App-DB", [cond("app|db")]),
          g("App-All", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/App-Web", f"{D}/groups/App-DB"]}]),
          g("Jump", [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.1.1.10"]}], description="jump hosts")]
services = [{"id": "App-8443", "path": f"{SV}/App-8443", "display_name": "App 8443",
             "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "TCP-8443", "l4_protocol": "TCP",
                                  "destination_ports": ["8443"], "source_ports": []}]},
            {"id": "HTTPS", "path": f"{SV}/HTTPS", "display_name": "HTTPS", "_system_owned": True,
             "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "HTTPS", "l4_protocol": "TCP", "destination_ports": ["443"]}]}]
def r(i, src, dst, svc, seq, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/legacy-app/rules/{i}", "display_name": i, "sequence_number": seq,
                 "action": "ALLOW", "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "disabled": False,
                 "sources_excluded": False, "destinations_excluded": False, "source_groups": src, "destination_groups": dst,
                 "services": svc, "scope": [f"{D}/groups/App-All"], "profiles": ["ANY"]}, **kw)
policies = [{"id": "legacy-app", "path": f"{D}/security-policies/legacy-app", "display_name": "legacy-app", "category": "Application",
             "sequence_number": 10, "stateful": True, "tcp_strict": True, "locked": False, "scope": [f"{D}/groups/App-All"],
             "comments": "NetOps", "tags": [{"scope": "owner", "tag": "netops"}],
             "rules": [r("web-to-db", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], [f"{SV}/App-8443"], 10,
                         notes="CHG-1", tag="LBL", tags=[{"scope": "chg", "tag": "one"}]),
                       r("jump-https", [f"{D}/groups/Jump"], [f"{D}/groups/App-All"], [f"{SV}/HTTPS"], 20,
                         profiles=["/infra/context-profiles/SSL"])]}]
json.dump({"groups": groups, "services": services, "policies": policies, "domain": "default"}, open("reports/lon1-raw.json", "w"))
PY

# The mock manager, with a certificate from its own CA, verified for real
# through NSX_CA_FILE_<SITE>: TLS verification is never switched off here.
for ca in site other; do
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SCRATCH/$ca-ca.key" -out "$SCRATCH/$ca-ca.pem" -days 1 \
		-subj "/CN=$ca CA" >/dev/null 2>&1
done
openssl req -newkey rsa:2048 -nodes -keyout "$SCRATCH/key.pem" -out "$SCRATCH/srv.csr" -subj "/CN=127.0.0.1" >/dev/null 2>&1
# A name for this machine other than "localhost", which Terraform would never
# send to a proxy: the proxy checks below need one.
PNAME="$(hostname)"
case "$(getent hosts "$PNAME" 2>/dev/null)" in 127.*) ;; *) PNAME="" ;; esac
printf 'subjectAltName=IP:127.0.0.1%s\n' "${PNAME:+,DNS:$PNAME}" >"$SCRATCH/ext.cnf"
openssl x509 -req -in "$SCRATCH/srv.csr" -CA "$SCRATCH/site-ca.pem" -CAkey "$SCRATCH/site-ca.key" -CAcreateserial \
	-out "$SCRATCH/cert.pem" -days 1 -extfile "$SCRATCH/ext.cnf" >/dev/null 2>&1
# Behind a TLS-inspecting proxy, provider downloads need that proxy's CA too:
# TEST_EXTRA_CA names it. Not needed on a normal network.
for ca in site other; do
	cat "$SCRATCH/$ca-ca.pem" ${TEST_EXTRA_CA:+"$TEST_EXTRA_CA"} >"$SCRATCH/trust-$ca.pem"
done
port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/mock_nsx.py" reports/lon1-raw.json "$SCRATCH/requests.log" "$port" "$SCRATCH/cert.pem" "$SCRATCH/key.pem" &
mock=$!
trap 'kill "$mock" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 1

printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
for s in lon1 nyc1; do printf 'path = "%s/%s.tfstate"\n' "$SCRATCH" "$s" >"envs/$s.backend.hcl"; done
export NSXT_MANAGER_HOST="127.0.0.1:$port" NSXT_USERNAME=u NSXT_PASSWORD=p
export NSX_CA_FILE_LON1="$SCRATCH/trust-site.pem" NSX_CA_FILE_NYC1="$SCRATCH/trust-site.pem"
unset SSL_CERT_FILE NSXT_ALLOW_UNVERIFIED_SSL
export TF_CLI_ARGS="-no-color" TF_PLUGIN_CACHE_DIR="$SCRATCH/plugins" ALLOW_LOCAL_STATE=1
mkdir -p "$TF_PLUGIN_CACHE_DIR"
tf() { scripts/tf.sh "$@" 2>&1; }
RULE='module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["web-to-db"]'

echo "trust"
python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy legacy-app >/dev/null
check "a manager signed by another CA is refused by the real provider" grep -q "x509: certificate signed by unknown authority" \
	<<<"$(NSX_CA_FILE_LON1="$SCRATCH/trust-other.pem" tf plan local-security lon1)"
rm -rf data/groups data/services data/policies stacks/local-security/import-*.tf data/.import-manifest.json
mkdir -p data/groups data/services data/policies

echo "a manager with no data"
out="$(tf plan local-security nyc1)"
check "is not touched: the plan changes nothing" grep -q "plan-guard: allowed" <<<"$out"
check "...and proposes nothing" bash -c '! grep -qE "to add|to change|to destroy" <<<"$1" || grep -q "0 to add, 0 to change, 0 to destroy" <<<"$1"' _ "$out"

echo "adopting one policy"
python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy legacy-app >/dev/null
out="$(tf plan local-security lon1)"
check "the real provider imports everything and changes nothing" grep -q "Plan: 8 to import, 0 to add, 0 to change, 0 to destroy" <<<"$out"
check "plan-guard accepts the pure import" grep -q "plan-guard: allowed" <<<"$out"
check "the plan cannot be applied to another manager" grep -q "was made for 'lon1', not 'nyc1'" <<<"$(APPROVE=yes tf apply local-security nyc1)"
check "the import applies" grep -q "Resources: 8 imported, 0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "another manager sharing the stack is untouched" grep -q "plan-guard: allowed" <<<"$(tf plan local-security nyc1)"
check "the next plan reports no changes" grep -q "No changes" <<<"$(tf plan local-security lon1)"
rm -f stacks/local-security/import-*.tf

echo "a proxy for the internet"
if [ -n "$PNAME" ]; then
	pport=$((port + 1))
	python3 "$REPO/tests/sni_reject_proxy.py" "$SCRATCH/proxy.log" "$pport" &
	proxy=$!
	trap 'kill "$mock" "$proxy" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
	sleep 1
	cp inventory/managers.yaml "$SCRATCH/managers.bak"
	sed -i "s/host: lon1.example.net/host: $PNAME:$port/" inventory/managers.yaml
	viaproxy() {
		env -u NSXT_MANAGER_HOST -u NSXT_USERNAME -u NSXT_PASSWORD -u no_proxy \
			HTTPS_PROXY="http://127.0.0.1:$pport" https_proxy="http://127.0.0.1:$pport" NO_PROXY=10.0.0.0/8,172.16.0.0/12 \
			NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p "$@" 2>&1
	}
	out="$(viaproxy NSXT_MANAGER_HOST="$PNAME:$port" NSXT_USERNAME=u NSXT_PASSWORD=p scripts/tf.sh plan local-security lon1)"
	check "an FQDN manager outside NO_PROXY goes to the proxy and fails as 'tls: unrecognized name'" \
		grep -q "tls: unrecognized name" <<<"$out"
	check "...because a CIDR in NO_PROXY never covers a name" grep -q "CONNECT $PNAME:$port" "$SCRATCH/proxy.log"
	: >"$SCRATCH/proxy.log"
	out="$(viaproxy scripts/with-credentials.sh lon1 --from env -- scripts/tf.sh plan local-security lon1)"
	check "with-credentials.sh sends the manager direct and the plan works" grep -q "No changes" <<<"$out"
	check "...and nothing reached the proxy" test ! -s "$SCRATCH/proxy.log"
	out="$(viaproxy NSX_MANAGER_VIA_PROXY=1 scripts/with-credentials.sh lon1 --from env -- scripts/tf.sh plan local-security lon1)"
	check "NSX_MANAGER_VIA_PROXY=1 keeps the proxy for the manager" grep -q "CONNECT $PNAME:$port" "$SCRATCH/proxy.log"
	cp "$SCRATCH/managers.bak" inventory/managers.yaml
else
	echo "  SKIP  no name for this machine resolves to 127.x (proxy checks need one)"
fi

echo "deletions"
cp data/policies/legacy-app.yaml "$SCRATCH/policy.bak"
python3 - <<'PY'
p = "data/policies/legacy-app.yaml"; s = open(p).read()
open(p, "w").write(s[: s.index("  web-to-db:")] + s[s.index("  jump-https:"):])
PY
out="$(tf plan local-security lon1)"
check "a rule deleted from the data is refused at plan" grep -q "plan-guard: REFUSED" <<<"$out"
check "...and at apply" grep -q "refusing to apply" <<<"$(APPROVE=yes tf apply local-security lon1)"
echo "lon1 local-security $RULE" >allow-destroy.txt
check "the same deletion approved in allow-destroy.txt is allowed" grep -q "plan-guard: allowed" <<<"$(tf plan local-security lon1)"
rm allow-destroy.txt

echo "handing back"
python3 scripts/hand-back.py --stack local-security --address "$RULE" >/dev/null
out="$(tf plan local-security lon1)"
check "the rule will no longer be managed, and is not destroyed" grep -q "will no longer be managed by Terraform, but will not be destroyed" <<<"$out"
check "plan-guard allows the hand-back" grep -q "plan-guard: allowed" <<<"$out"
check "the hand-back applies" grep -q "0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "and the next plan reports no changes" grep -q "No changes" <<<"$(tf plan local-security lon1)"
cp "$SCRATCH/policy.bak" data/policies/legacy-app.yaml
check "a hand-back while the rule is still in the data is refused" grep -q "Moved object still exists" <<<"$(tf plan local-security lon1)"
rm -f stacks/local-security/handback-*.tf
check "re-adding a handed-back rule without an import is refused by the provider, not overwritten" \
	grep -q "already exists" <<<"$(tf plan local-security lon1 >/dev/null; APPROVE=yes tf apply local-security lon1)"
mv data/policies/legacy-app.yaml "$SCRATCH/policy.moved"
check "deleting a whole policy is refused" grep -q "Instance cannot be destroyed" <<<"$(tf plan local-security lon1)"
mv "$SCRATCH/policy.moved" data/policies/legacy-app.yaml

echo "imports that would go wrong"
printf 'locals {\n  bad = { "Ghost" = "/infra/domains/default/groups/Ghost" }\n}\nimport {\n  for_each = var.site == "lon1" ? local.bad : {}\n  to       = module.base_groups.nsxt_policy_group.this[each.key]\n  id       = each.value\n}\n' >stacks/local-security/import-lon1-ghost.tf
printf 'groups:\n  Ghost:\n    display_name: Ghost\n    owner: lm\n    sites: [lon1]\n    criteria:\n      - conditions:\n          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|ghost"}\n' >data/groups/ghost.yaml
check "a wrong import id fails before anything is written" grep -q "Cannot import non-existent remote object" <<<"$(tf plan local-security lon1)"
printf 'groups:\n  Ghost:\n    display_name: Ghost\n    owner: lm\n    sites: [lon1]\n    criteria:\n      - conditions:\n          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|ghost"}\n  Extra:\n    display_name: Extra\n    owner: lm\n    sites: [lon1]\n    criteria:\n      - conditions:\n          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|x"}\n' >data/groups/ghost.yaml
printf 'import {\n  for_each = var.site == "lon1" ? { "App-Web" = "/infra/domains/default/groups/App-Web" } : {}\n  to       = module.base_groups.nsxt_policy_group.this[each.key]\n  id       = each.value\n}\n' >stacks/local-security/import-lon1-ghost.tf
check "a create during an import tranche is refused" grep -q "create during an import tranche" <<<"$(tf plan local-security lon1)"

echo "mirror mode: state follows the UI until cutover"
# A tree of its own, with no state yet: a manager still run from the UI. The
# mock serves $T/reports/lon1-raw.json and re-reads it when it changes, so
# editing that file is an engineer working in the UI.
UI="$T/reports/lon1-raw.json"
T2="$SCRATCH/tree2"
generate "$T2" --no-examples
cd "$T2" || exit 1
printf 'managers:\n  lon1:\n    role: lm\n    host: 127.0.0.1:%s\n    site: lon1\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/lon1\n    tier: prod\n    mode: mirror\n' "$port" >inventory/managers.yaml
printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
# The placeholder backend: tf.sh keeps this manager's state here.
STATE="$T2/.local-state/lon1-local-security.tfstate"
printf 'path = "%s"\n' "$STATE" >envs/lon1.backend.hcl
check "(setup) the tree is on the placeholder local backend" grep -q 'backend "local"' stacks/local-security/backend.tf
sync() { # what the mirror job does: read the manager, rewrite the copy
	env -u NSXT_MANAGER_HOST NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p scripts/with-credentials.sh lon1 --from env -- \
		python3 scripts/import-estate.py --site lon1 --dump-only "$SCRATCH/mirror-cap.json" >/dev/null 2>&1 &&
		python3 scripts/import-estate.py --site lon1 --from-dump "$SCRATCH/mirror-cap.json" --mirror 2>&1
}
observe() { APPROVE=yes NSX_CRED_SCOPE=plan scripts/sync-state.sh lon1 local-security 2>&1; } # the sync-state job: plans and applies
in_state() { python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["resources"]))' "$STATE" 2>/dev/null; }
ui() { python3 - "$UI" "$1" <<'PY'
import json, sys
path, what = sys.argv[1], sys.argv[2]
d = json.load(open(path)); D = "/infra/domains/default"
if what == "edit-and-add":
    for g in d["groups"]:
        if g["id"] == "App-DB":
            g["expression"][0]["value"] = "app|db-v2"
    d["policies"].append({"id": "new-app", "path": f"{D}/security-policies/new-app", "display_name": "new-app",
        "category": "Application", "sequence_number": 20, "stateful": True, "tcp_strict": True, "locked": False,
        "scope": [f"{D}/groups/App-All"],
        "rules": [{"id": "n1", "path": f"{D}/security-policies/new-app/rules/n1", "display_name": "n1", "sequence_number": 10,
                   "action": "ALLOW", "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": False, "disabled": False,
                   "sources_excluded": False, "destinations_excluded": False, "source_groups": [f"{D}/groups/App-Web"],
                   "destination_groups": [f"{D}/groups/App-DB"], "services": ["ANY"], "scope": [f"{D}/groups/App-All"],
                   "profiles": ["ANY"]}]})
elif what == "delete":
    d["policies"] = [p for p in d["policies"] if p["id"] != "new-app"]
json.dump(d, open(path, "w"))
PY
}
cp "$UI" "$SCRATCH/ui.orig"

check "the mirror reads the whole manager through the same trust as plans" grep -q "mirror of lon1 regenerated" <<<"$(sync)"
out="$(tf plan local-security lon1)"
check "the real provider plans the whole copy as a pure import" grep -q "Plan: 8 to import, 0 to add, 0 to change, 0 to destroy" <<<"$out"
check "the write credential is refused for a manager in mirror mode" grep -q "only with the read-only credential" <<<"$(APPROVE=yes NSX_CRED_SCOPE=apply tf apply local-security lon1)"
check "...and nothing reached state" bash -c '[ ! -s "$1" ] || [ "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))[\"resources\"]))" "$1")" = 0 ]' _ "$STATE"
check "the sync-state apply (read-only) imports everything into state" grep -q "Resources: 8 imported, 0 added, 0 changed, 0 destroyed" <<<"$(observe)"
check "...the state file holds it" grep -q "legacy-app" <<<"$(in_state)"
check "...after which the plan reports no changes" grep -q "No changes" <<<"$(tf plan local-security lon1)"

ui edit-and-add
out="$(tf plan local-security lon1)"
check "a UI change not yet synced: the stale copy is refused, never pushed onto NSX" bash -c 'grep -q "plan-guard: REFUSED" <<<"$1" && grep -q "changed in the UI after the last sync" <<<"$1"' _ "$out"
check "...and the sync-state apply refuses it too" grep -q "refusing to apply" <<<"$(observe)"
sync >/dev/null
out="$(tf plan local-security lon1)"
check "after the sync: the edit needs nothing, the new policy is imported" grep -q "Plan: 2 to import, 0 to add, 0 to change, 0 to destroy" <<<"$out"
check "...the sync-state apply records it" grep -q "Resources: 2 imported, 0 added, 0 changed, 0 destroyed" <<<"$(observe)"
check "...and state now holds the edited group and the new policy" bash -c 'grep -q "app|db-v2" <<<"$1" && grep -q "new-app" <<<"$1"' _ "$(in_state)"

ui delete
sync >/dev/null
out="$(tf plan local-security lon1)"
check "a policy deleted in the UI: nothing to do in NSX" grep -q "0 import, 0 create, 0 update, 0 destroy/replace" <<<"$out"
observe >/dev/null
check "...and it is gone from state" bash -c '! grep -q "new-app" <<<"$1" && grep -q "legacy-app" <<<"$1"' _ "$(in_state)"

echo "cutover: the copy becomes the configuration engineers edit"
git_quiet init -q -b main .
git_quiet add -A
git_quiet commit -qm "lon1 in mirror mode, in step"
git init -q --bare "$SCRATCH/t2-remote.git"
gl_port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/fake_gitlab_api.py" "$gl_port" "$SCRATCH/t2-gl.log" &
gl=$!
sleep 1
cut() { env -u NSXT_MANAGER_HOST -u NSXT_USERNAME -u NSXT_PASSWORD NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p \
	NSX_ADOPT_REMOTE="$SCRATCH/t2-remote.git" NSX_ADOPT_TOKEN=T CI_API_V4_URL="http://127.0.0.1:$gl_port/api/v4" \
	CI_PROJECT_ID=7 CI_DEFAULT_BRANCH=main CUTOVER_SITE=lon1 scripts/cutover.sh 2>&1; }
ui edit-and-add
out="$(cut)"
check "a UI change not yet synced stops the cutover, and nothing is pushed" bash -c 'grep -q "lon1 changed in the UI since the last sync" <<<"$1" && ! git -C "$2" rev-parse -q --verify refs/heads/cutover/lon1' _ "$out" "$SCRATCH/t2-remote.git"
check "...leaving the checkout as it was" bash -c '[ -z "$(git status --porcelain)" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = main ]'
ui delete
out="$(cut)"
check "in step: the cutover plans every stack of the manager, and each changes nothing" bash -c 'grep -q "plan-guard lon1/local-security, normal: 0 import, 0 create, 0 update, 0 destroy/replace, 0 hand back" <<<"$1" && ! grep -q "^error" <<<"$1"' _ "$out"
check "...and opens the merge request that is the cutover" bash -c 'grep -q "\"title\": \"Cut lon1 over to managed\"" "$1" && grep -q "merge request: " <<<"$2"' _ "$SCRATCH/t2-gl.log" "$out"
B="$SCRATCH/t2-remote.git"
check "...the branch: mode managed, no import blocks, no mirror marks, the groups file renamed" bash -c 'git -C "$1" show cutover/lon1:inventory/managers.yaml | grep -q "^    mode: managed" && ! git -C "$1" show cutover/lon1:stacks/local-security/import-lon1-mirror.tf >/dev/null 2>&1 && ! git -C "$1" grep -q "nsx-mirror:" cutover/lon1 -- data && git -C "$1" show cutover/lon1:data/groups/imported-lon1.yaml | head -1 | grep -q "managed by this repository since"' _ "$B"
check "...and the files still validate" bash -c 'd="$(mktemp -d)" && git -C "$1" archive cutover/lon1 | tar -x -C "$d" && cd "$d" && python3 scripts/validate-data.py >/dev/null' _ "$B"
git_quiet fetch -q "$B" cutover/lon1
git_quiet checkout -q -B cutover FETCH_HEAD
out="$(tf plan local-security lon1)"
check "merged: the manager plans as managed, with nothing to do" bash -c 'grep -q "No changes" <<<"$1" && grep -q "lon1/local-security, normal" <<<"$1"' _ "$out"
# An engineer edits an imported rule and adds a new one, in the files.
python3 - <<'PY'
import re
f = "data/policies/legacy-app.yaml"; t = open(f).read()
t = t.replace("action: ALLOW", "action: DROP", 1)
open(f, "w").write(t)
PY
python3 scripts/add-rule.py --policy legacy-app --rule new-web-rule --source App-Web --destination App-DB --service HTTPS --scope App-All >/dev/null 2>&1 ||
	printf '  new-web-rule:\n    sequence_number: 900\n    action: ALLOW\n    direction: IN_OUT\n    source_groups: [App-Web]\n    destination_groups: [App-DB]\n    services: [HTTPS]\n    scope: [App-All]\n    logged: true\n' >>data/policies/legacy-app.yaml
out="$(tf plan local-security lon1)"
check "after cutover, editing an imported rule and adding one plan as exactly that" bash -c 'grep -q "Plan: 1 to add, 1 to change, 0 to destroy" <<<"$1" && grep -q "plan-guard: allowed" <<<"$1"' _ "$out"
git_quiet checkout -q -- data
# Someone changes the managed manager in the UI: a drift issue, with who and when.
python3 - "$UI" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
for g in d["groups"]:
    if g["id"] == "App-Web":
        g["expression"][0]["value"] = "app|web-ui-edit"
        g["_last_modified_user"] = "carol"; g["_last_modified_time"] = int(time.time() * 1000)
json.dump(d, open(sys.argv[1], "w"))
PY
out="$(env -u NSXT_MANAGER_HOST -u NSXT_USERNAME -u NSXT_PASSWORD NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p NSX_ADOPT_TOKEN=T \
	CI_API_V4_URL="http://127.0.0.1:$gl_port/api/v4" CI_PROJECT_ID=7 CI_JOB_URL=http://gitlab.test/jobs/9 \
	scripts/with-credentials.sh lon1 -- scripts/drift-job.sh --one lon1 local-security 2>&1)"
check "drift on a managed manager raises an issue, with who changed it, from NSX" python3 - "$SCRATCH/t2-gl.log" <<'PY'
import json, sys
p = [json.loads(x)["body"] for x in open(sys.argv[1]) if '"/api/v4/projects/7/issues"' in x and '"POST"' in x]
d = p[-1]["description"] if p else ""
ok = len(p) == 1 and p[0]["labels"] == "nsx-drift,site:lon1" and 'base_groups.nsxt_policy_group.this["App-Web"]' in d and "| carol |" in d
ok = ok and "the next apply of this manager reverts it" in d and "http://gitlab.test/jobs/9" in d
sys.exit(0 if ok else 1)
PY
out="$(env -u NSXT_MANAGER_HOST -u NSXT_USERNAME -u NSXT_PASSWORD NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p NSX_ADOPT_TOKEN=T \
	CI_API_V4_URL="http://127.0.0.1:$gl_port/api/v4" CI_PROJECT_ID=7 \
	scripts/with-credentials.sh lon1 -- scripts/drift-job.sh --one lon1 local-security 2>&1)"
check "...once: the next check finds it already raised" grep -q "already in an nsx-drift issue" <<<"$out"
kill "$gl" 2>/dev/null
cp "$SCRATCH/ui.orig" "$UI"
cd "$T" || exit 1

echo "federation: an LM rule using the Global Manager's group and service"
# The GM's objects come from its own copy; the LM's rule refers to them under
# /global-infra, as NSX shows it. The LM stack must take the rule over with no
# change, never manage the GM's objects, and stay quiet on the next plan.
T3="$SCRATCH/tree3"
generate "$T3" --no-examples
cd "$T3" || exit 1
printf 'managers:\n  gm1:\n    role: gm\n    host: gm.example.net\n    site: global\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/gm1\n    tier: prod\n  lon1:\n    role: lm\n    host: 127.0.0.1:%s\n    site: lon1\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/lon1\n    tier: prod\n' "$port" >inventory/managers.yaml
printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
printf 'path = "%s/fed.tfstate"\n' "$SCRATCH" >envs/lon1.backend.hcl
mkdir -p reports
python3 - "$UI" <<'PY'
import json, sys
GD = "/global-infra/domains/default"; LD = "/infra/domains/default"
gm = {"domain": "default",
      "groups": [{"id": "G-Web", "path": f"{GD}/groups/G-Web", "display_name": "G-Web",
                  "expression": [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": "app|gweb"}]}],
      "services": [{"id": "G-Svc", "path": "/global-infra/services/G-Svc", "display_name": "G-Svc",
                    "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "t9443", "l4_protocol": "TCP", "destination_ports": ["9443"]}]}],
      "policies": []}
json.dump(gm, open("reports/gm1.json", "w"))
d = json.load(open(sys.argv[1]))
d["policies"].append({"id": "fed-app", "path": f"{LD}/security-policies/fed-app", "display_name": "fed-app", "category": "Application",
    "sequence_number": 30, "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"],
    "rules": [{"id": "f1", "path": f"{LD}/security-policies/fed-app/rules/f1", "display_name": "f1", "sequence_number": 100,
               "action": "ALLOW", "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "disabled": False,
               "sources_excluded": False, "destinations_excluded": False, "source_groups": [f"{GD}/groups/G-Web"],
               "destination_groups": [f"{LD}/groups/App-DB"], "services": ["/global-infra/services/G-Svc"],
               "scope": ["ANY"], "profiles": ["ANY"]}]})
json.dump(d, open(sys.argv[1], "w"))
PY
python3 scripts/import-estate.py --site gm1 --role gm --from-dump reports/gm1.json --mirror >/dev/null 2>&1
out="$(env -u NSXT_MANAGER_HOST NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p scripts/with-credentials.sh lon1 --from env -- \
	python3 scripts/import-estate.py --site lon1 --dump-only "$SCRATCH/fed-cap.json" >/dev/null 2>&1 &&
	python3 scripts/import-estate.py --site lon1 --from-dump "$SCRATCH/fed-cap.json" --mirror 2>&1)"
check "(setup) the LM copy takes the rule that uses the GM's group and service" bash -c 'grep -q "source_groups: \[G-Web\]" data/policies/fed-app.yaml && grep -q "services: \[G-Svc\]" data/policies/fed-app.yaml' _
check "(setup) the copy validates" python3 scripts/validate-data.py
out="$(tf plan local-security lon1)"
check "the real provider plans the LM, global references included, as a pure import" grep -q "Plan: 10 to import, 0 to add, 0 to change, 0 to destroy" <<<"$out"
check "...and the LM stack manages none of the GM's objects" bash -c '! grep -q "G-Web\"\]\|G-Svc\"\]" <<<"$1"' _ "$out"
check "it applies as imports only" grep -q "Resources: 10 imported, 0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "...and the next plan is quiet: no drift between the GM's objects and the LM's rule" grep -q "No changes" <<<"$(tf plan local-security lon1)"
check "...nor the one after (no loop)" grep -q "No changes" <<<"$(tf plan local-security lon1)"
cp "$SCRATCH/ui.orig" "$UI"
cd "$T" || exit 1

echo "estate shapes: VM members, IP addresses in rules, a location domain's global group, ids as NSX allows them"
# What a real estate holds and the first mirror of hyd-gm01 left in the UI: a
# group of VMs picked one by one (ExternalIDExpression), rules with addresses
# written in them, and a rule using a Global Manager group from a location
# domain (WL-Mum). Taken over with no change, and no drift afterwards.
T4="$SCRATCH/tree4"
generate "$T4" --no-examples
cd "$T4" || exit 1
printf 'managers:\n  gm1:\n    role: gm\n    host: gm.example.net\n    site: global\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/gm1\n    tier: prod\n  lon1:\n    role: lm\n    host: 127.0.0.1:%s\n    site: lon1\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/lon1\n    tier: prod\n' "$port" >inventory/managers.yaml
printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
printf 'path = "%s/shapes.tfstate"\n' "$SCRATCH" >envs/lon1.backend.hcl
mkdir -p reports
python3 - "$UI" <<'PY'
import json, sys
WD = "/global-infra/domains/WL-Mum"; LD = "/infra/domains/default"
gm = {"domain": "default", "domains": ["default", "WL-Mum"],
      "groups": [{"id": "M-App", "path": f"{WD}/groups/M-App", "display_name": "M-App",
                  "expression": [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": "app|mum"}]}],
      "services": [], "policies": []}
json.dump(gm, open("reports/gm1.json", "w"))
d = json.load(open(sys.argv[1]))
d["groups"].append({"id": "_Exchange-GW_VM's", "path": f"{LD}/groups/_Exchange-GW_VM's", "display_name": "_Exchange-GW_VM's",
                    "expression": [{"resource_type": "ExternalIDExpression", "member_type": "VirtualMachine",
                                    "external_ids": ["502e6f1a-0000-0000-0000-000000000001", "502e6f1a-0000-0000-0000-000000000002"]}]})
def rule(i, seq, src, dst):
    return {"id": i, "path": f"{LD}/security-policies/_Shapes App/rules/{i}", "display_name": i, "sequence_number": seq,
            "action": "ALLOW", "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "disabled": False,
            "sources_excluded": False, "destinations_excluded": False, "source_groups": src, "destination_groups": dst,
            "services": ["ANY"], "scope": ["ANY"], "profiles": ["ANY"]}
d["policies"].append({"id": "_Shapes App", "path": f"{LD}/security-policies/_Shapes App", "display_name": "_Shapes App",
    "category": "Application", "sequence_number": 40, "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"],
    "rules": [rule("vm-members", 100, [f"{LD}/groups/_Exchange-GW_VM's"], [f"{LD}/groups/App-DB"]),
              rule("addresses", 200, ["172.19.20.57", "10.1.0.0/16"], ["172.17.9.10-172.17.9.20", "13.126.23.128 - 13.126.23.135", f"{LD}/groups/App-DB"]),
              rule("location-group", 300, [f"{WD}/groups/M-App"], [f"{LD}/groups/App-DB"])]})
# Made in the UI: UUID ids, keyed here by display name. And a group a principal
# identity made (vSphere with Tanzu): used by name, never managed.
U = lambda n: f"0b7c{n:04d}-1111-4222-8333-444455556666"
d["groups"].append({"id": U(1), "path": f"{LD}/groups/{U(1)}", "display_name": "#UI Group",
                    "expression": [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": "app|ui"}]})
d["groups"].append({"id": "tkg-ns", "path": f"{LD}/groups/tkg-ns", "display_name": "tkg-ns", "_protection": "REQUIRE_OVERRIDE",
                    "_create_user": "wcp-cluster-user", "expression": [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": "app|tkg"}]})
ui = rule("x", 100, [f"{LD}/groups/{U(1)}", f"{LD}/groups/tkg-ns"], [f"{LD}/groups/App-DB"])
ui.update(id=U(20), display_name="Allow UI", path=f"{LD}/security-policies/{U(10)}/rules/{U(20)}")
d["policies"].append({"id": U(10), "path": f"{LD}/security-policies/{U(10)}", "display_name": "UI Policy",
    "category": "Application", "sequence_number": 41, "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"], "rules": [ui]})
json.dump(d, open(sys.argv[1], "w"))
PY
python3 scripts/import-estate.py --site gm1 --role gm --from-dump reports/gm1.json --mirror >/dev/null 2>&1
out="$(env -u NSXT_MANAGER_HOST NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p scripts/with-credentials.sh lon1 --from env -- \
	python3 scripts/import-estate.py --site lon1 --dump-only "$SCRATCH/shapes-cap.json" >/dev/null 2>&1 &&
	python3 scripts/import-estate.py --site lon1 --from-dump "$SCRATCH/shapes-cap.json" --mirror 2>&1)"
check "(setup) the copy takes all three rules, and leaves nothing of them in the UI" bash -c '! grep -q "NOT ADOPTED" <<<"$1" && grep -q "^  location-group:" "data/policies/_Shapes App.yaml" && grep -q "external_ids" data/groups/imported-lon1-mirror.yaml' _ "$out"
check "(setup) the copy validates" python3 scripts/validate-data.py
out="$(tf plan local-security lon1)"
check "the real provider plans VM members, addresses and the location group as a pure import" bash -c 'grep -qE "Plan: [0-9]+ to import, 0 to add, 0 to change, 0 to destroy" <<<"$1" && grep -q "plan-guard: allowed" <<<"$1"' _ "$out"
check "...the location group by its domain's path" grep -q '/global-infra/domains/WL-Mum/groups/M-App' <<<"$out"
check "...the UI-made policy, rule and group by their UUIDs, under readable keys" bash -c 'grep -q "module.policies\[\"UI-Policy\"\].nsxt_policy_security_policy_rule.this\[\"Allow-UI\"\]" <<<"$1" && grep -q "0b7c0020-1111-4222-8333-444455556666" <<<"$1" && grep -q "nsxt_policy_group.this\[\"UI-Group\"\]" <<<"$1"' _ "$out"
check "...and the group vSphere with Tanzu owns is used by its path, never imported" bash -c 'grep -q "/infra/domains/default/groups/tkg-ns" <<<"$1" && ! grep -q "this\[\"tkg-ns\"\]" <<<"$1"' _ "$out"
check "it applies as imports only" grep -qE "Resources: [0-9]+ imported, 0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "...and the next plan is quiet: external ids and addresses read back as written" grep -q "No changes" <<<"$(tf plan local-security lon1)"
check "...nor the one after (no loop)" grep -q "No changes" <<<"$(tf plan local-security lon1)"
cp "$SCRATCH/ui.orig" "$UI"
cd "$T" || exit 1

echo "a production-shaped manager, end to end, as the pipeline runs it (no PyYAML)"
# Every shape the audit found in real estates, through the same steps as the
# pipeline: mirror, validate with the built-in YAML reader (the CI image may
# lack PyYAML), terraform fmt -check, plan (pure import), apply, then no changes.
T5="$SCRATCH/tree5"
generate "$T5" --no-examples
cd "$T5" || exit 1
printf 'managers:\n  lon1:\n    role: lm\n    host: 127.0.0.1:%s\n    site: lon1\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/lon1\n    tier: prod\n' "$port" >inventory/managers.yaml
printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
printf 'path = "%s/prod.tfstate"\n' "$SCRATCH" >envs/lon1.backend.hcl
cp "$UI" "$SCRATCH/ui.before-prod"
python3 - "$UI" <<'PY'
import json, sys
D = "/infra/domains/default"; SV = "/infra/services"
def g(i, expr, **kw): return dict({"id": i, "path": f"{D}/groups/{i}", "display_name": i, "expression": expr}, **kw)
cond = lambda k, m, o, v, **kw: dict({"resource_type": "Condition", "key": k, "member_type": m, "operator": o, "value": v}, **kw)
groups = [
    g("Azure-AD-IP's", [cond("Tag", "VirtualMachine", "EQUALS", "unlisted-scope|x")], description='line one\nline "two"'),
    g("Name-Prefix", [cond("Name", "VirtualMachine", "STARTSWITH", "web-")]),
    g("Empty-Placeholder", []),
    g("IP-Only", [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.20.0.0/24"]}], group_type=["IPAddress"]),
    g("MAC-Hosts", [{"resource_type": "MACAddressExpression", "mac_addresses": ["00:50:56:aa:bb:cc"]}]),
    g("Pods", [cond("Tag", "Pod", "EQUALS", "app|x")]),
    g("Not-Scope", [cond("Tag", "VirtualMachine", "EQUALS", "env|prod", scope_operator="NOTEQUALS")]),
]
svc = lambda i, entries: {"id": i, "path": f"{SV}/{i}", "display_name": i, "service_entries": entries}
services = [
    svc("gm_UDP_49152–65535", [{"resource_type": "L4PortSetServiceEntry", "display_name": "u", "l4_protocol": "UDP", "destination_ports": ["49152-65535"], "source_ports": []}]),
    svc("GRE-Tunnel", [{"resource_type": "IPProtocolServiceEntry", "display_name": "gre", "protocol_number": 47}]),
    svc("FTP-ALG", [{"resource_type": "ALGTypeServiceEntry", "display_name": "ftp", "alg": "FTP", "destination_ports": ["21"], "source_ports": []}]),
    svc("IGMP-Any", [{"resource_type": "IGMPTypeServiceEntry", "display_name": "igmp"}]),
]
d = json.load(open(sys.argv[1]))
d["groups"] += groups
d["services"] += services
# A federated Local Manager also lists the Global Manager's HTTPS: same display name.
d["services"].append({"id": "HTTPS", "path": "/global-infra/services/HTTPS", "display_name": "HTTPS", "_system_owned": True,
                      "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "HTTPS", "l4_protocol": "TCP", "destination_ports": ["443"]}]})
def rule(p, i, seq, src, dst, svcs):
    return {"id": i, "path": f"{D}/security-policies/{p}/rules/{i}", "display_name": i, "sequence_number": seq, "action": "ALLOW",
            "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": False, "disabled": False, "sources_excluded": False,
            "destinations_excluded": False, "source_groups": src, "destination_groups": dst, "services": svcs, "scope": ["ANY"], "profiles": ["ANY"]}
def pol(i, rules, desc=None):
    out = {"id": i, "path": f"{D}/security-policies/{i}", "display_name": "CSS", "category": "Application", "sequence_number": 0,
           "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"], "rules": rules}
    if desc: out["description"] = desc
    return out
G = lambda i: f"{D}/groups/{i}"
d["policies"] += [
    pol("CSS", [rule("CSS", "zero", 0, [G("Azure-AD-IP's")], [G("Name-Prefix")], [f"{SV}/HTTPS"]),
                rule("CSS", "same-a", 470, [G("IP-Only")], [G("MAC-Hosts")], [f"{SV}/gm_UDP_49152–65535", f"{SV}/GRE-Tunnel"]),
                rule("CSS", "same-b", 470, [G("Empty-Placeholder")], ["ANY"], [f"{SV}/FTP-ALG", f"{SV}/IGMP-Any"]),
                rule("CSS", "pods", 900, [G("Pods")], ["ANY"], ["ANY"])], desc='quoted "text"\nand a line'),
    pol("CSS-LbTAAIz-d", [rule("CSS-LbTAAIz-d", "r1", 10, [G("Not-Scope")], ["ANY"], ["ANY"]),
                          rule("CSS-LbTAAIz-d", "r2", 20, [G("Name-Prefix")], ["ANY"], [f"{SV}/HTTPS"]),
                          dict(rule("CSS-LbTAAIz-d", "inline", 30, [G("Name-Prefix")], ["ANY"], ["ANY"]),
                               service_entries=[{"resource_type": "L4PortSetServiceEntry", "display_name": "t8080", "l4_protocol": "TCP",
                                                 "destination_ports": ["8080", "8443"], "source_ports": []},
                                                {"resource_type": "ICMPTypeServiceEntry", "display_name": "echo", "protocol": "ICMPv4",
                                                 "icmp_type": 8}])]),
    pol("Empty-Placeholder-Pol", []),
]
json.dump(d, open(sys.argv[1], "w"))
PY
out="$(env -u NSXT_MANAGER_HOST NSX_LON1_USERNAME=u NSX_LON1_PASSWORD=p scripts/with-credentials.sh lon1 --from env -- \
	python3 scripts/import-estate.py --site lon1 --dump-only "$SCRATCH/prod-cap.json" >/dev/null 2>&1 &&
	python3 scripts/import-estate.py --site lon1 --from-dump "$SCRATCH/prod-cap.json" --mirror 2>&1)"
check "every shape NSX allows is taken, except what cannot be represented, each with its reason" bash -c '
	grep -q "NOT ADOPTED  group Pods: a condition with member_type Pod" <<<"$1" &&
	grep -q "NOT ADOPTED  group Not-Scope: a condition with scope_operator NOTEQUALS" <<<"$1" &&
	grep -q "NOT ADOPTED  rule CSS/pods: uses Pods" <<<"$1" && grep -q "NOT ADOPTED  rule CSS-LbTAAIz-d/r1: uses Not-Scope" <<<"$1" &&
	! grep -qE "NOT ADOPTED  (group|service) (Azure|Name-Prefix|Empty|IP-Only|MAC|gm_UDP|GRE|FTP|IGMP)" <<<"$1"' _ "$out"
check "...system services by id, not by name" grep -q "^predefined_ids:" data/services/imported-lon1-mirror.yaml
check "...and a policy NSX numbered with duplicates keeps them, marked" grep -q "allow_duplicate_sequence: true" data/policies/CSS.yaml
v="$(NSX_YAML_FALLBACK=1 python3 scripts/validate-data.py 2>&1)"
check "the copy validates with the built-in YAML reader, as on a CI image without PyYAML" bash -c '! grep -q "^ERROR" <<<"$1" && grep -q "0 error(s)" <<<"$1"' _ "$v"
check "...an unlisted tag scope in an adopted group is a warning, not an error" grep -q "^warning .*tag scope .unlisted-scope." <<<"$v"
check "terraform fmt -check passes on everything the mirror wrote" bash -c 'terraform fmt -check -recursive stacks >/dev/null'
out="$(tf plan local-security lon1)"
check "the real provider plans it as a pure import: two HTTPS, empty and IP-only groups, MAC, ALG, IGMP, GRE, sequence 0" bash -c 'grep -qE "Plan: [0-9]+ to import, 0 to add, 0 to change, 0 to destroy" <<<"$1" && grep -q "plan-guard: allowed" <<<"$1"' _ "$out"
check "...and it applies as imports only" grep -qE "Resources: [0-9]+ imported, 0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "...after which the plan is empty: everything read back as written" grep -q "No changes" <<<"$(tf plan local-security lon1)"
check "...a rule with ports written in it and an empty policy among them" bash -c 'grep -q "^  inline:" "data/policies/CSS-LbTAAIz-d.yaml" && test -f "data/policies/Empty-Placeholder-Pol.yaml"'

# The same ids in a second domain: a group and a policy with the ids of ones in
# default, managed side by side under <id>@<domain> keys with their NSX ids.
python3 - "$UI" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); O = "/infra/domains/other"
d["groups"].append({"id": "Name-Prefix", "path": f"{O}/groups/Name-Prefix", "display_name": "Name-Prefix",
                    "expression": [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": "app|other"}]})
d["policies"].append({"id": "CSS", "path": f"{O}/security-policies/CSS", "display_name": "CSS", "category": "Application", "sequence_number": 5,
    "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"],
    "rules": [{"id": "o1", "path": f"{O}/security-policies/CSS/rules/o1", "display_name": "o1", "sequence_number": 10, "action": "ALLOW",
               "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": False, "disabled": False, "sources_excluded": False,
               "destinations_excluded": False, "source_groups": [f"{O}/groups/Name-Prefix"], "destination_groups": ["ANY"],
               "services": ["ANY"], "scope": ["ANY"], "profiles": ["ANY"]}]})
json.dump(d, open(sys.argv[1], "w"))
PY
python3 - <<'PY'
import json
open("data/groups/other-domain.yaml", "w").write(
    "groups:\n  Name-Prefix@other:\n    display_name: Name-Prefix\n    nsx_id: Name-Prefix\n    domain: other\n    owner: lm\n"
    "    sites: [lon1]\n    criteria:\n      - conditions:\n          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: \"app|other\"}\n")
open("data/policies/CSS@other.yaml", "w").write(
    "policy:\n  id: CSS\n  name: CSS\n  category: Application\n  owner: lm\n  domain: other\n  sites: [lon1]\n  sequence_number: 5\n"
    "  rule_management: standalone\n  scope: [ANY]\nrules:\n  o1:\n    name: o1\n    sequence_number: 10\n    action: ALLOW\n"
    "    direction: IN_OUT\n    source_groups: [Name-Prefix@other]\n    logged: false\n    scope: [ANY]\n")
m = json.load(open("data/.import-manifest.json"))
m["imported"] += ["data/groups/other-domain.yaml", "data/policies/CSS@other.yaml"]
json.dump(m, open("data/.import-manifest.json", "w"), indent=2)
O = "/infra/domains/other"
open("stacks/local-security/import-lon1-other.tf", "w").write(f'''import {{
  to = module.base_groups.nsxt_policy_group.this["Name-Prefix@other"]
  id = "{O}/groups/Name-Prefix"
}}

import {{
  to = module.policies["CSS@other"].nsxt_policy_parent_security_policy.this
  id = "{O}/security-policies/CSS"
}}

import {{
  to = module.policies["CSS@other"].nsxt_policy_security_policy_rule.this["o1"]
  id = "{O}/security-policies/CSS/rules/o1"
}}
''')
PY
check "(setup) the second domain's copies validate beside the first ones" bash -c 'NSX_YAML_FALLBACK=1 python3 scripts/validate-data.py 2>&1 | grep -q "0 error(s)"'
out="$(tf plan local-security lon1)"
check "the real provider imports the same ids from another domain, by their NSX ids, beside the default ones" bash -c 'grep -q "Plan: 3 to import, 0 to add, 0 to change, 0 to destroy" <<<"$1" && grep -q "/infra/domains/other/groups/Name-Prefix" <<<"$1"' _ "$out"
check "...it applies as imports only" grep -q "Resources: 3 imported, 0 added, 0 changed, 0 destroyed" <<<"$(APPROVE=yes tf apply local-security lon1)"
check "...and the next plan is empty: both copies of each id read back as written" grep -q "No changes" <<<"$(tf plan local-security lon1)"
cp "$SCRATCH/ui.before-prod" "$UI"
cd "$T" || exit 1

writes="$(grep WRITE "$SCRATCH/requests.log" | grep -vc "/api/session/create" || true)"
check "NSX received no write at all (login sessions aside)" test "$writes" -eq 0

finish brownfield-provider
