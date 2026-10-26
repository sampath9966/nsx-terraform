#!/usr/bin/env bash
# Governance: zero-trust guardrails on every merge request, no silent undoing
# of a change made in NSX, and plans summarised in firewall terms.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1
cat >inventory/managers.yaml <<'INV'
managers:
  gm1:
    role: gm
    host: gm.example.internal
    site: global
    vcf_instance: vcf-a
    vault_path: secret/nsx/gm1
    tier: prod
  lon1:
    role: lm
    host: lon1.example.internal
    site: lon1
    vcf_instance: vcf-a
    vault_path: secret/nsx/lon1
    tier: prod
INV
mkdir -p data/groups data/policies
cat >data/groups/apps.yaml <<'YAML'
groups:
  web-prod:
    display_name: web-prod
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "env|prod"}
  web-dev:
    display_name: web-dev
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "env|dev"}
  legacy:
    display_name: legacy
    owner: lm
    sites: [lon1]
    why_static: test
    criteria:
      - ip_addresses: [10.1.1.1]
YAML
rule() { # key action src dst services [extra yaml lines]
	printf '  %s:\n    sequence_number: %s\n    action: %s\n    direction: IN_OUT\n    source_groups: [%s]\n    destination_groups: [%s]\n    services: [%s]\n    scope: [web-prod]\n%s' \
		"$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"
}
write_policy() { # name, then rules on stdin
	{ printf 'policy:\n  id: %s\n  name: %s\n  category: Application\n  owner: lm\n  sites: [lon1]\n  scope: [web-prod]\n  rule_management: standalone\nrules:\n' "$1" "$1"; cat; } >"data/policies/$1.yaml"
}

echo "guardrails"
write_policy app <<YAML
$(rule ok 100 ALLOW web-dev web-dev HTTPS)
$(rule any-any 200 ALLOW ANY ANY ANY)
$(rule cross-env 300 ALLOW web-dev web-prod HTTPS)
$(rule any-svc 400 ALLOW web-dev web-dev ANY)
$(rule addresses 500 ALLOW 10.9.9.9 web-dev HTTPS)
$(rule quiet-drop 600 DROP ANY ANY ANY "    logged: false
")
YAML
printf 'predefined_ids:\n  HTTPS: HTTPS\n' >data/services/predefined.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "an ALLOW any to any on any service is refused, naming the NIST control" grep -q "ERROR .*rules.any-any: guardrail any-any-any (SP 800-207 tenet 3; 800-53 AC-3, AC-6)" <<<"$out"
check "an ALLOW from non-production to production is refused" grep -q "ERROR .*rules.cross-env: guardrail prod-nonprod .*(dev -> prod)" <<<"$out"
check "any service, an address, a quiet drop, no final deny: warnings" bash -c 'grep -q "warning .*rules.any-svc: guardrail any-service" <<<"$1" && grep -q "warning .*rules.addresses: guardrail ip-literals" <<<"$1" && grep -q "warning .*rules.quiet-drop: guardrail deny-not-logged" <<<"$1"' _ "$out"
check "a static group is a warning; a compliant rule raises nothing" bash -c 'grep -q "group legacy: guardrail static-membership" <<<"$1" && ! grep -q "rules.ok:" <<<"$1"' _ "$out"
cat >>data/policies/app.yaml <<'YAML'
  last:
    sequence_number: 900
    action: DROP
    direction: IN_OUT
    scope: [web-prod]
YAML
check "...and a policy ending in a DROP satisfies no-default-deny" bash -c '! python3 scripts/validate-data.py 2>&1 | grep -q "no-default-deny"'

echo "exceptions: owned, tracked, ending"
python3 - <<'PY'
t = open("data/policies/app.yaml").read()
t = t.replace("  any-any:\n", "  any-any:\n    exception:\n      guardrails: [any-any-any]\n      owner: net-team\n      ticket: CHG1\n      expires: 2099-01-01\n", 1)
t = t.replace("  cross-env:\n", "  cross-env:\n    exception:\n      guardrails: [prod-nonprod]\n      owner: net-team\n      ticket: CHG2\n      expires: 2020-01-01\n", 1)
open("data/policies/app.yaml", "w").write(t)
PY
out="$(python3 scripts/validate-data.py 2>&1)"
check "a current exception lets the rule off that guardrail" bash -c '! grep -q "rules.any-any: guardrail any-any-any" <<<"$1"' _ "$out"
check "an expired one does not, and is itself an error" bash -c 'grep -q "rules.cross-env.exception expired on 2020-01-01" <<<"$1" && grep -q "rules.cross-env: guardrail prod-nonprod" <<<"$1"' _ "$out"
sed -i 's/      ticket: CHG1//' data/policies/app.yaml
check "an exception without its ticket is an error" bash -c 'python3 scripts/validate-data.py 2>&1 | grep -q "rules.any-any.exception: needs ticket"'

echo "levels: admins decide, per manager too"
cat >data/guardrails.yaml <<'YAML'
guardrails:
  any-service: {level: enforce}
  ip-literals: {level: off}
sites:
  lon1:
    any-service: {level: warn}
YAML
out="$(python3 scripts/validate-data.py 2>&1)"
check "a guardrail turned off, even written bare (YAML's false), is not checked" bash -c '! grep -q "ip-literals" <<<"$1"' _ "$out"
check "a manager's own level wins: any-service is a warning on lon1 though enforced elsewhere" grep -q "warning .*rules.any-svc: guardrail any-service" <<<"$out"
printf 'guardrails:\n  made-up: {level: enforce}\n  any-source: {level: maybe}\n' >data/guardrails.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "an unknown guardrail or level is an error" bash -c 'grep -q "unknown guardrail .made-up." <<<"$1" && grep -q "any-source: level .maybe. is not enforce, warn or off" <<<"$1"' _ "$out"
rm data/guardrails.yaml

echo "rules adopted from NSX: findings, never a failed pipeline"
cp data/policies/app.yaml data/policies/adopted.yaml
sed -i 's/^  id: app$/  id: adopted/; s/^  name: app$/  name: adopted/; /exception:/,/expires:/d' data/policies/adopted.yaml
python3 -c "import json;json.dump({'version':1,'imported':['data/policies/adopted.yaml'],'sources':[]},open('data/.import-manifest.json','w'))"
out="$(python3 scripts/validate-data.py 2>&1)"
check "the same violations in an adopted file are counted as findings, not errors" bash -c '! grep -q "ERROR .*adopted.yaml.*guardrail" <<<"$1" && grep -q "guardrails: [0-9]* finding(s) in rules adopted from NSX, a backlog, never a failed pipeline: " <<<"$1"' _ "$out"
check "--findings lists them" bash -c 'python3 scripts/validate-data.py --findings 2>&1 | grep -q "^finding  data/policies/adopted.yaml: rules.any-any: guardrail any-any-any"'
rm data/policies/adopted.yaml data/.import-manifest.json

echo "the DFW exclusion list"
mkdir -p data/exclude-list
printf 'members:\n  legacy:\n    why: an appliance the DFW breaks\n' >data/exclude-list/lon1.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "a group excluded from the DFW without an exception is refused" grep -q "ERROR .*data/exclude-list/lon1.yaml: members.legacy: guardrail exclusion-list" <<<"$out"
printf 'members:\n  legacy:\n    why: an appliance the DFW breaks\n    exception:\n      guardrails: [exclusion-list]\n      owner: net-team\n      ticket: CHG9\n      expires: 2099-01-01\n' >data/exclude-list/lon1.yaml
check "...accepted with one, owned, tracked and ending" bash -c '! python3 scripts/validate-data.py 2>&1 | grep -q "exclude-list/lon1.yaml"'
printf 'members:\n  nope:\n    why: x\n' >data/exclude-list/lon1.yaml
check "a member that is no group in data/ is an error" bash -c 'python3 scripts/validate-data.py 2>&1 | grep -q "members.nope: no group .nope. in data/"'
rm -r data/exclude-list

echo "no silent undoing of a change made in NSX"
plan_json() { # field-in-plan-after, extra drift: what the plan sets the rule's action to
	python3 - "$1" <<'PY'
import json, sys
A = 'module.policies["app"].nsxt_policy_security_policy_rule.this["ok"]'
old = {"action": "ALLOW", "disabled": False, "revision": 1, "path": "/infra/x"}
nsx = dict(old, action="DROP", revision=2)  # changed in the UI
after = dict(nsx, action=sys.argv[1])
print(json.dumps({"resource_drift": [{"address": A, "change": {"actions": ["update"], "before": old, "after": nsx}}],
                  "resource_changes": [{"address": A, "mode": "managed", "type": "nsxt_policy_security_policy_rule",
                                        "change": {"actions": ["update"], "before": nsx, "after": after}}]}))
PY
}
out="$(plan_json ALLOW | python3 scripts/plan-guard.py --site lon1 --stack local-security 2>&1)"
check "a plan putting back what someone changed in NSX is refused, saying what and how to decide" bash -c 'grep -q "would undo a change made in NSX outside this repository: action: NSX has \"DROP\", the plan sets it back to \"ALLOW\"" <<<"$1" && grep -q "scripts/accept-drift.py" <<<"$1" && grep -q "allow-revert.txt" <<<"$1"' _ "$out"
printf 'lon1 local-security module.policies["app"].nsxt_policy_security_policy_rule.this["ok"]\n' >allow-revert.txt
check "...allowed once the revert is approved in allow-revert.txt, in the merge request" bash -c 'python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1"' _ "$(plan_json ALLOW)"
rm allow-revert.txt
check "a merge request that changes the field itself is not a silent revert" bash -c 'python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1"' _ "$(plan_json REJECT)"

echo "hybrid: cut over in slices"
printf '# nsx-mirror: lon1\npolicy:\n  id: still\n  name: still\n  category: Application\n  owner: lm\n  sites: [lon1]\n  scope: [ANY]\n  rule_management: standalone\nrules: {}\n' >data/policies/still.yaml
hybrid_plan() { # policy action [importing]
	python3 - "$@" <<'PY'
import json, sys
c = {"address": f'module.policies["{sys.argv[1]}"].nsxt_policy_security_policy_rule.this["r"]', "mode": "managed",
     "type": "nsxt_policy_security_policy_rule", "change": {"actions": [sys.argv[2]], "before": {"a": 1}, "after": {"a": 2}}}
if len(sys.argv) > 3:
    c["change"]["importing"] = {"id": "x"}
print(json.dumps({"resource_changes": [c]}))
PY
}
check "a change to a policy still mirrored from the UI is refused" bash -c '! NSX_MODE=hybrid python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1" 2>&1 | grep -q "allowed" && NSX_MODE=hybrid python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1" 2>&1 | grep -q "still mirrored from the UI"' _ "$(hybrid_plan still update)"
check "...its import is allowed" bash -c 'NSX_MODE=hybrid python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1"' _ "$(hybrid_plan still no-op import)"
check "...and a change to a policy cut over is allowed, a mirror's import file being no tranche to it" bash -c 'mkdir -p stacks/local-security && printf "import {\n}\n" >stacks/local-security/import-lon1-mirror.tf && NSX_MODE=hybrid python3 scripts/plan-guard.py --site lon1 --stack local-security <<<"$1"; r=$?; rm -f stacks/local-security/import-lon1-mirror.tf; exit $r' _ "$(hybrid_plan app update)"
rm data/policies/still.yaml

echo "plans in firewall terms"
python3 - >"$SCRATCH/plan.json" <<'PY'
import json
G = "module.base_groups.nsxt_policy_group.this"
R = 'module.policies["app"].nsxt_policy_security_policy_rule.this'
gp = lambda k: f"/infra/domains/default/groups/{k}"
print(json.dumps({
  "prior_state": {"values": {"root_module": {"child_modules": [{"resources": [
      {"address": f'{G}["web-prod"]', "type": "nsxt_policy_group", "index": "web-prod", "values": {"path": gp("web-prod")}},
      {"address": f'{G}["web-dev"]', "type": "nsxt_policy_group", "index": "web-dev", "values": {"path": gp("web-dev")}}]}]}}},
  "resource_changes": [
    {"address": f'{R}["ok"]', "mode": "managed", "type": "nsxt_policy_security_policy_rule", "change": {"actions": ["update"],
     "before": {"action": "ALLOW", "destination_groups": [gp("web-dev")], "services": ["/infra/services/HTTPS"]},
     "after": {"action": "DROP", "destination_groups": [gp("web-dev"), gp("web-prod")], "services": ["/infra/services/HTTPS"]}}},
    {"address": f'{R}["new"]', "mode": "managed", "type": "nsxt_policy_security_policy_rule", "change": {"actions": ["create"], "before": None,
     "after": {"action": "ALLOW", "source_groups": [gp("web-dev")], "destination_groups": [gp("web-prod")], "services": ["/infra/services/HTTPS"], "scope": [gp("web-prod")]}}},
    {"address": f'{R}["gone"]', "mode": "managed", "type": "nsxt_policy_security_policy_rule", "change": {"actions": ["delete"], "before": {}, "after": None}},
    {"address": f'{G}["web-dev"]', "mode": "managed", "type": "nsxt_policy_group", "change": {"actions": ["no-op"], "importing": {"id": "x"}, "before": {}, "after": {}}}]}))
PY
out="$(python3 scripts/plan-summary.py --stack local-security --site lon1 "$SCRATCH/plan.json")"
check "a changed rule reads as its fields, groups by name" grep -q "| changed | \`rule app/ok\` | action ALLOW → DROP; destination_groups +web-prod |" <<<"$out"
check "an added rule reads as what it allows" grep -q "| added | \`rule app/new\` | ALLOW web-dev → web-prod on HTTPS, applied to web-prod |" <<<"$out"
check "a deletion stands out, with the approval it needs" bash -c 'grep -q "| \*\*deleted\*\* | .rule app/gone." <<<"$1" && grep -q "1 deletion(s)" <<<"$1"' _ "$out"
check "imports are counted as changing nothing" grep -q "1 object(s) imported (no change in NSX)" <<<"$out"
check "the merge request comment puts the summary above the raw plan" bash -c 'grep -q "tf.sh summary" .gitlab-ci.yml scripts/*.py 2>/dev/null || grep -q "summary_file" scripts/post-plan-comment.sh'

cd / || exit 1
finish govern
