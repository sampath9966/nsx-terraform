#!/usr/bin/env bash
# Brownfield adoption: the importer, the plan guard, hand-back, and the
# per-manager safety of scripts/tf.sh. Offline: no Terraform, no network. The
# plan fixtures have the exact shape Terraform 1.9 writes with 'show -json'.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1

cat >inventory/managers.yaml <<'INV'
managers:
  gm1:
    role: gm
    host: gm.example.net
    site: global
    vcf_instance: vcf-a
    vault_path: secret/nsx/gm1
    tier: prod
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

# --- a live estate, as the policy API returns it ---------------------------------
python3 - <<'PY'
import json
D = "/infra/domains/default"; SV = "/infra/services"
cond = lambda v: {"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}
def g(i, expr, **kw): return dict({"id": i, "path": f"{D}/groups/{i}", "display_name": i, "expression": expr}, **kw)
groups = [
    g("App-Web", [cond("app|web")], tags=[{"scope": "owner", "tag": "team-a"}]),
    g("App-DB", [cond("app|db")]),
    g("App-All", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/App-Web", f"{D}/groups/App-DB"]}]),
    g("Jump", [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.1.1.10"]}]),
    g("Mac", [{"resource_type": "MACAddressExpression", "mac_addresses": ["00:50:56:aa:bb:cc"]}]),
    g("Nests-Mac", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/Mac"]}]),
    g("Other", [cond("app|other")]),
]
services = [
    {"id": "App-8443", "path": f"{SV}/App-8443", "display_name": "App 8443",
     "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "TCP-8443", "l4_protocol": "TCP", "destination_ports": ["8443"]}]},
    {"id": "HTTPS", "path": f"{SV}/HTTPS", "display_name": "HTTPS", "_system_owned": True, "service_entries": []},
    {"id": "GRE", "path": f"{SV}/GRE", "display_name": "GRE", "service_entries": [{"resource_type": "IPProtocolServiceEntry", "protocol_number": 47}]},
]
def r(p, i, src, dst, svc, seq, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{p}/rules/{i}", "display_name": i, "sequence_number": seq, "action": "ALLOW",
                 "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "source_groups": src, "destination_groups": dst,
                 "services": svc, "scope": [f"{D}/groups/App-All"], "profiles": ["ANY"]}, **kw)
def pol(i, rules, scope, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{i}", "display_name": i, "category": "Application", "sequence_number": 10,
                 "stateful": True, "scope": scope, "rules": rules}, **kw)
policies = [
    pol("legacy-app", [
        r("legacy-app", "web-to-db", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], [f"{SV}/App-8443"], 10,
          notes="CHG-1", tag="LBL", tags=[{"scope": "chg", "tag": "1"}]),
        r("legacy-app", "jump-https", [f"{D}/groups/Jump"], [f"{D}/groups/App-All"], [f"{SV}/HTTPS"], 20, profiles=["/infra/context-profiles/SSL"]),
        r("legacy-app", "inline", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], ["ANY"], 30,
          service_entries=[{"resource_type": "L4PortSetServiceEntry", "l4_protocol": "UDP", "destination_ports": ["161"]}]),
        r("legacy-app", "printers", [f"{D}/groups/App-Web"], [f"{D}/groups/Nests-Mac"], ["ANY"], 40),
        r("legacy-app", "gre", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], [f"{SV}/GRE"], 50),
    ], [f"{D}/groups/App-All"], comments="NetOps", tags=[{"scope": "owner", "tag": "netops"}]),
    pol("other-app", [r("other-app", "x", [f"{D}/groups/Other"], [f"{D}/groups/App-Web"], ["ANY"], 10)], [f"{D}/groups/App-All"]),
    pol("mac-scoped", [r("mac-scoped", "m", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], ["ANY"], 10)], [f"{D}/groups/Mac"]),
    pol("Default-Layer3", [], ["ANY"], _system_owned=True),
]
json.dump({"groups": groups, "services": services, "policies": policies, "domain": "default"}, open("reports/lon1-raw.json", "w"))
PY

imp() { python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json "$@" 2>&1; }

echo "importer: one policy at a time"
out="$(imp --policy legacy-app)"
check "the tranche writes its own files" bash -c 'test -f data/groups/imported-lon1-legacy-app.yaml && test -f data/policies/legacy-app.yaml && test -f stacks/local-security/import-lon1-legacy-app.tf'
G="$(cat data/groups/imported-lon1-legacy-app.yaml)"
check "only the groups the policy needs, nested ones included" bash -c 'for k in App-Web App-DB App-All Jump; do grep -q "^  $k:" <<<"$1" || exit 1; done; ! grep -q "^  Other:" <<<"$1"' _ "$G"
check "groups keep their tags" grep -q "tag: team-a" <<<"$G"
S="$(cat data/services/imported-lon1-legacy-app.yaml)"
check "custom services keep their entry names" grep -q "display_name: TCP-8443" <<<"$S"
check "a site-local service is scoped to its site" grep -q "sites: \[lon1\]" <<<"$S"
check "predefined services are referenced, not copied" grep -q "HTTPS: HTTPS" <<<"$S"
P="$(cat data/policies/legacy-app.yaml)"
check "rules keep notes, log label, context profiles and tags" bash -c 'grep -q "notes: CHG-1" <<<"$1" && grep -q "log_label: LBL" <<<"$1" && grep -q "/infra/context-profiles/SSL" <<<"$1" && grep -q "tag: \"1\"\|tag: 1" <<<"$1"' _ "$P"
check "the policy keeps its comments and tags" bash -c 'grep -q "comments: NetOps" <<<"$1" && grep -q "tag: netops" <<<"$1"' _ "$P"
I="$(cat stacks/local-security/import-lon1-legacy-app.tf)"
check "import blocks are gated on the site" bash -c '[ "$(grep -c "var.site == \"lon1\"" <<<"$1")" -eq 5 ]' _ "$I"
check "custom services are imported, not created" grep -q "module.services.nsxt_policy_service.this\[each.key\]" <<<"$I"
check "rules are imported into their policy" grep -q "each.value.policy" <<<"$I"

echo "importer: never lossy"
check "a MAC-based group is not adopted, and says why" grep -q "group Mac: membership by MACAddressExpression" <<<"$out"
check "a group nesting it is not adopted" grep -q "group Nests-Mac: nests Mac" <<<"$out"
check "a service with other entry types is not adopted" grep -q "service GRE: service entries of type IPProtocolServiceEntry" <<<"$out"
check "a rule with inline service entries stays in the UI" grep -q "rule legacy-app/inline: inline service entries" <<<"$out"
check "rules using unadoptable objects stay in the UI" bash -c 'grep -q "rule legacy-app/printers: uses Nests-Mac" <<<"$1" && grep -q "rule legacy-app/gre: uses GRE" <<<"$1"' _ "$out"
check "the rest of the policy is still adopted" bash -c 'grep -q "^  web-to-db:" <<<"$1" && grep -q "^  jump-https:" <<<"$1" && ! grep -q "^  inline:" <<<"$1"' _ "$P"
check "a requested policy whose Apply To is unadoptable is refused, nothing written" bash -c '! out="$(python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy mac-scoped 2>&1)" && grep -q "Nothing was written" <<<"$out" && ! test -f data/policies/mac-scoped.yaml'
check "the result validates" bash -c 'python3 scripts/validate-data.py >/dev/null 2>&1 || python3 scripts/validate-data.py 2>&1 | grep -q "0 error"'

echo "importer: the second piece"
out2="$(imp --policy other-app)"
check "objects already in data/ are not adopted again" bash -c 'grep -q "MANAGED   group App-Web" <<<"$1" && grep -q "MANAGED   group App-All" <<<"$1"' _ "$out2"
check "only the new group is in the second tranche" bash -c 'grep -q "^  Other:" data/groups/imported-lon1-other-app.yaml && ! grep -q "^  App-Web:" data/groups/imported-lon1-other-app.yaml'
check "re-running a finished tranche writes nothing" bash -c '! grep -q "  wrote " <<<"$(python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy legacy-app 2>&1)"'
check "an unknown policy is an error" bash -c '! python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy nope >/dev/null 2>&1'
check "a system-owned policy is refused" bash -c '! python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy Default-Layer3 >/dev/null 2>&1'

echo "importer: reading a large estate"
check "capture follows the API cursor across pages" python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("imp", "scripts/import-estate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []
def fake(host, path, user, password, insecure):
    calls.append(path)
    if path.endswith("/groups"): return {"results": [{"id": "a"}], "cursor": "c1"}
    if "cursor=c1" in path: return {"results": [{"id": "b"}], "cursor": "c2"}
    if "cursor=c2" in path: return {"results": [{"id": "c"}]}
    return {"results": []}
m.api_get = fake
estate = m.fetch_estate("h", "u", "p", "/policy/api/v1/infra", "default", False)
sys.exit(0 if [g["id"] for g in estate["groups"]] == ["a", "b", "c"] else 1)
PY

echo "plan-guard"
plan() { # plan <file> <json for resource_changes>
	printf '{"format_version":"1.2","terraform_version":"1.9.8","resource_changes":%s}\n' "$2" >"$1"
}
rc_() { local f="$1" s="$2"; shift 2; python3 scripts/plan-guard.py --site "$s" --stack local-security "$f" >/dev/null 2>&1; echo $?; }
A='module.policies[\"p\"].nsxt_policy_security_policy_rule.this[\"r\"]'
plan "$SCRATCH/import.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"no-op\"],\"importing\":{\"id\":\"x\"}}}]"
plan "$SCRATCH/import-update.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"update\"],\"importing\":{\"id\":\"x\"}}}]"
plan "$SCRATCH/import-create.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"no-op\"],\"importing\":{\"id\":\"x\"}}},{\"address\":\"b.c\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\"]}}]"
plan "$SCRATCH/create-update.json" "[{\"address\":\"a.b\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\"]}},{\"address\":\"c.d\",\"mode\":\"managed\",\"change\":{\"actions\":[\"update\"]}},{\"address\":\"data.x.y\",\"mode\":\"data\",\"change\":{\"actions\":[\"read\"]}}]"
plan "$SCRATCH/delete.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"delete\"]}}]"
plan "$SCRATCH/replace.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"delete\",\"create\"]}}]"
plan "$SCRATCH/cbd.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\",\"delete\"]}}]"
plan "$SCRATCH/forget.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"forget\"]}}]"
rm -f stacks/local-security/import-*.tf
check "a pure import is allowed" test "$(rc_ "$SCRATCH/import.json" lon1)" -eq 0
check "an import that would update the live object is refused" test "$(rc_ "$SCRATCH/import-update.json" lon1)" -eq 2
check "a create during an import tranche is refused" test "$(rc_ "$SCRATCH/import-create.json" lon1)" -eq 2
check "creates and updates are allowed outside a tranche" test "$(rc_ "$SCRATCH/create-update.json" lon1)" -eq 0
check "a destroy is refused" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 2
check "a replace is refused" test "$(rc_ "$SCRATCH/replace.json" lon1)" -eq 2
check "a create-before-destroy replace is refused" test "$(rc_ "$SCRATCH/cbd.json" lon1)" -eq 2
check "handing an object back (forget) is allowed" test "$(rc_ "$SCRATCH/forget.json" lon1)" -eq 0
printf '# approved in review\nlon1 local-security %s\n' "module.policies[\"p\"].nsxt_policy_security_policy_rule.this[\"r\"]" >allow-destroy.txt
check "a destroy approved in allow-destroy.txt is allowed" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 0
check "the approval does not extend to another manager" test "$(rc_ "$SCRATCH/delete.json" nyc1)" -eq 2
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/forget.json" 2>&1)"
check "an approval that matches nothing is reported as stale" grep -q "which this plan does not destroy" <<<"$out"
echo "lon1 local-security" >>allow-destroy.txt
check "a malformed approval line is an error" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 1
rm -f allow-destroy.txt
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/delete.json" 2>&1)"
check "a refusal prints the approval line to paste" grep -q "^  lon1 local-security module.policies" <<<"$out"
printf 'import {\n  to = a.b\n  id = "x"\n}\n' >stacks/local-security/import-lon1-t.tf
check "this manager's open tranche file makes the stack import-only" test "$(rc_ "$SCRATCH/create-update.json" lon1)" -eq 2
check "another manager's tranche file does not" test "$(rc_ "$SCRATCH/create-update.json" nyc1)" -eq 0
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/import.json" 2>&1; python3 scripts/plan-guard.py --site lon1 --stack local-security <(plan /dev/stdout '[]') 2>&1)"
check "an applied tranche's leftover file is pointed out" grep -q "imports nothing new, so that tranche is applied" <<<"$out"
rm -f stacks/local-security/import-lon1-t.tf
check "input that is not a plan is an error" bash -c '! echo nope | python3 scripts/plan-guard.py --site lon1 --stack local-security >/dev/null 2>&1'

echo "tf.sh: one manager's state and plan never reach another"
mkdir -p "$SCRATCH/fake"
cat >"$SCRATCH/fake/terraform" <<'STUB'
#!/usr/bin/env bash
# Records what tf.sh asks of it; plays a plan that changes nothing.
echo "$*" >>"$FAKE_LOG"
case "$1" in
init) mkdir -p .terraform ;;
plan) : >tfplan ;;
show) [ "${2:-}" = -json ] && echo '{"format_version":"1.2","resource_changes":[]}' ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/fake/terraform"
for s in lon1 nyc1; do printf 'path = "%s.tfstate"\n' "$s" >"envs/$s.backend.hcl"; done
export FAKE_LOG="$SCRATCH/fake.log"
tf() { env PATH="$SCRATCH/fake:$PATH" scripts/tf.sh "$@" 2>&1; }
: >"$FAKE_LOG"
tf plan local-security lon1 >/dev/null
tf plan local-security nyc1 >/dev/null
check "planning a second manager re-initialises for its own backend" grep -q "init .*envs/nyc1.backend.hcl" "$FAKE_LOG"
: >"$FAKE_LOG"
tf plan local-security nyc1 >/dev/null
check "the same manager again does not re-initialise" bash -c '! grep -q "^init" "$1"' _ "$FAKE_LOG"
check "the saved plan records its manager" test "$(cat stacks/local-security/tfplan.site)" = nyc1
out="$(APPROVE=yes tf apply local-security lon1)"
check "a plan made for one manager is refused for another" grep -q "was made for 'nyc1', not 'lon1'" <<<"$out"
check "...before anything is applied" bash -c '! grep -q "^apply" "$1"' _ "$FAKE_LOG"
rm -f stacks/local-security/tfplan.site
check "a plan with no record of its manager is refused" grep -q "was made for 'an unknown manager'" <<<"$(APPROVE=yes tf apply local-security nyc1)"
tf plan local-security nyc1 >/dev/null
# The test tree is on the placeholder local backend, which tf.sh only applies to
# when told it is a lab.
out="$(APPROVE=yes ALLOW_LOCAL_STATE=1 tf apply local-security nyc1)"
check "the right plan for the right manager applies" grep -q "^apply" "$FAKE_LOG"
check "the plan and its record are removed after apply" bash -c '! test -e stacks/local-security/tfplan && ! test -e stacks/local-security/tfplan.site'
check "the child pipeline carries the record with the plan" grep -q "tfplan.site" <<<"$(python3 scripts/gitlab-child-pipeline.py)"

echo "hand-back"
A2='module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["web-to-db"]'
python3 scripts/hand-back.py --stack local-security --address "$A2" >/dev/null 2>&1
H="$(cat stacks/local-security/handback-legacy_app_web_to_db.tf 2>/dev/null)"
check "it moves the instance to a stand-alone address" grep -qF "from = $A2" <<<"$H"
check "...and forgets it without destroying" bash -c 'grep -q "nsxt_policy_security_policy_rule.handback_legacy_app_web_to_db" <<<"$1" && grep -q "destroy = false" <<<"$1"' _ "$H"
check "it will not overwrite an existing hand-back" bash -c '! python3 scripts/hand-back.py --stack local-security --address "$1" >/dev/null 2>&1' _ "$A2"
check "a non-NSX address is refused" bash -c '! python3 scripts/hand-back.py --stack local-security --address "random_id.x" >/dev/null 2>&1'
check "an unknown stack is refused" bash -c '! python3 scripts/hand-back.py --stack nope --address "$1" >/dev/null 2>&1' _ "$A2"

echo "validator"
mkdir -p "$SCRATCH/v" && cp -r data inventory scripts "$SCRATCH/v/" 2>/dev/null
cat >"$SCRATCH/v/data/services/extra.yaml" <<'YAML'
custom:
  Everywhere:
    display_name: Everywhere
    owner: lm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["1"]
YAML
check "a site-local service without sites is an error" grep -q "lists no sites, so it is created on EVERY" <<<"$(cd "$SCRATCH/v" && python3 scripts/validate-data.py 2>&1)"
sed -i 's#rules:#rules:#' "$SCRATCH/v/data/policies/legacy-app.yaml"
check "context profiles may be referenced by path" bash -c '! (cd "$1" && python3 scripts/validate-data.py 2>&1) | grep -q "context-profiles"' _ "$SCRATCH/v"
sed -i 's#scope: \[App-All\]#scope: [/infra/domains/default/groups/App-All]#' "$SCRATCH/v/data/policies/legacy-app.yaml"
check "any other raw path is still an error" grep -q "raw policy path" <<<"$(cd "$SCRATCH/v" && python3 scripts/validate-data.py 2>&1)"

finish brownfield
