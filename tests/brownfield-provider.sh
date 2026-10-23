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

# The mock manager.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SCRATCH/key.pem" -out "$SCRATCH/cert.pem" -days 1 \
	-subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/mock_nsx.py" reports/lon1-raw.json "$SCRATCH/requests.log" "$port" "$SCRATCH/cert.pem" "$SCRATCH/key.pem" &
mock=$!
trap 'kill "$mock" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 1

printf 'terraform {\n  backend "local" {}\n}\n' >stacks/local-security/backend_override.tf
for s in lon1 nyc1; do printf 'path = "%s/%s.tfstate"\n' "$SCRATCH" "$s" >"envs/$s.backend.hcl"; done
export NSXT_MANAGER_HOST="127.0.0.1:$port" NSXT_USERNAME=u NSXT_PASSWORD=p NSXT_ALLOW_UNVERIFIED_SSL=true
export TF_CLI_ARGS="-no-color" TF_PLUGIN_CACHE_DIR="$SCRATCH/plugins" ALLOW_LOCAL_STATE=1
mkdir -p "$TF_PLUGIN_CACHE_DIR"
tf() { scripts/tf.sh "$@" 2>&1; }
RULE='module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["web-to-db"]'

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

writes="$(grep WRITE "$SCRATCH/requests.log" | grep -vc "/api/session/create" || true)"
check "NSX received no write at all (login sessions aside)" test "$writes" -eq 0

finish brownfield-provider
