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
observe() { APPROVE=yes NSX_CRED_SCOPE=plan tf apply local-security lon1; } # the sync-state job
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

out="$(NSX_MODE_LON1=managed tf plan local-security lon1)"
check "cutover (NSX_MODE_LON1=managed, or mode: managed): Terraform already holds it all" grep -q "No changes" <<<"$out"
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

writes="$(grep WRITE "$SCRATCH/requests.log" | grep -vc "/api/session/create" || true)"
check "NSX received no write at all (login sessions aside)" test "$writes" -eq 0

finish brownfield-provider
