#!/usr/bin/env bash
# The change watch (scripts/drift.py watch): drift found by comparing what NSX
# holds with data/, without Terraform. What the importer wrote compares equal to
# the manager it read; a change made in the UI does not; and what is not drift
# (another tool's objects, a pending apply, the pipeline's own changes) is not
# raised.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1
cat >inventory/managers.yaml <<'INV'
managers:
  lon1:
    role: lm
    host: lon1.example.internal
    site: lon1
    vcf_instance: vcf-a
    vault_path: secret/nsx/lon1
    tier: prod
INV
mkdir -p reports data/groups data/policies data/services
python3 - <<'PY'
import json, time
D = "/infra/domains/default"; SV = "/infra/services"
old = 1500000000000
U = lambda n: f"0b7c{n:04d}-1111-4222-8333-444455556666"
cond = lambda v: [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}]
def g(i, name, expr, **kw): return dict({"id": i, "path": f"{D}/groups/{i}", "display_name": name, "expression": expr,
                                          "_last_modified_time": old, "_last_modified_user": "admin"}, **kw)
def rule(p, i, name, seq, src, dst, svc=("ANY",), **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{p}/rules/{i}", "display_name": name, "sequence_number": seq, "action": "ALLOW",
                 "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "disabled": False, "source_groups": list(src),
                 "destination_groups": list(dst), "services": list(svc), "scope": ["ANY"], "profiles": ["ANY"],
                 "_last_modified_time": old, "_last_modified_user": "admin"}, **kw)
groups = [g("web", "web", cond("app|web")), g("db", "db", cond("app|db")),
          g(U(1), "#UI Group", [{"resource_type": "IPAddressExpression", "ip_addresses": [f"10.0.0.{n}" for n in range(1, 9)]}]),
          g("vms", "vms", [{"resource_type": "ExternalIDExpression", "member_type": "VirtualMachine", "external_ids": ["502e-1", "502e-2"]}]),
          g("nest", "nest", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/web", f"{D}/groups/db"]}]),
          g("tkg", "tkg", cond("app|tkg"), _protection="REQUIRE_OVERRIDE", _create_user="wcp")]
services = [{"id": "app-8443", "path": f"{SV}/app-8443", "display_name": "app-8443", "_last_modified_time": old,
             "service_entries": [{"resource_type": "L4PortSetServiceEntry", "l4_protocol": "TCP", "destination_ports": ["8443"]}]},
            {"id": "HTTPS", "path": f"{SV}/HTTPS", "display_name": "HTTPS", "_system_owned": True,
             "service_entries": [{"resource_type": "L4PortSetServiceEntry", "l4_protocol": "TCP", "destination_ports": ["443"]}]}]
policies = [{"id": "app", "path": f"{D}/security-policies/app", "display_name": "app", "category": "Application", "sequence_number": 10,
             "stateful": True, "tcp_strict": True, "locked": False, "scope": ["ANY"], "_last_modified_time": old, "rules": [
                 rule("app", "r1", "r1", 100, [f"{D}/groups/web"], [f"{D}/groups/db"], [f"{SV}/app-8443", f"{SV}/HTTPS"]),
                 rule("app", U(20), "Allow UI", 200, [f"{D}/groups/{U(1)}", f"{D}/groups/tkg"], ["10.9.9.9", "13.1.1.1 - 13.1.1.9"]),
                 rule("app", "r3", "r3", 300, [f"{D}/groups/nest"], ["ANY"], disabled=True, notes="n", tag="lbl"),
                 rule("app", "odd", "odd", 400, ["ANY"], ["ANY"], scheduler_path="/infra/firewall-schedulers/x")]},
            {"id": "ncp", "path": f"{D}/security-policies/ncp", "display_name": "ncp", "category": "Application", "sequence_number": 20,
             "scope": ["ANY"], "_protection": "REQUIRE_OVERRIDE", "rules": [rule("ncp", "n1", "n1", 100, ["ANY"], ["ANY"])]}]
json.dump({"groups": groups, "services": services, "policies": policies, "domain": "default", "domains": ["default"],
           "exclude_list": [f"{D}/groups/web"]}, open("reports/lon1.json", "w"))
PY
python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1.json --mirror >/dev/null 2>&1
check "(setup) the copy validates" python3 scripts/validate-data.py
watch() { python3 scripts/drift.py watch --site lon1 --from-dump reports/lon1.json --report-only 2>&1; }

echo "what the importer wrote compares equal to what it read"
out="$(watch)"
check "groups (tags, addresses, VMs, nested), services, the policy and its rules: no difference" bash -c '! grep -q "changed\|deleted" <<<"$1"' _ "$out"
check "what stays in the UI (a rule with a time window) is raised as created outside Git, once" bash -c 'grep -q "created outside Git  *rule app/odd" <<<"$1" && [ "$(grep -c "created outside Git" <<<"$1")" = 1 ]' _ "$out"
check "another tool's objects are not drift" bash -c '! grep -q "tkg\|ncp" <<<"$1"' _ "$out"

echo "a change made in the UI is found, and says what changed"
cp reports/lon1.json "$SCRATCH/lon1.json"
python3 - <<'PY'
import json
d = json.load(open("reports/lon1.json"))
pol = d["policies"][0]
pol["rules"][0].update(action="DROP", _last_modified_user="carol", _last_modified_time=1900000000000)
pol["rules"][0]["destination_groups"].append("/infra/domains/default/groups/web")
pol["sequence_number"] = 11
d["groups"][0]["expression"][0]["value"] = "app|web2"
d["groups"] = [x for x in d["groups"] if x["id"] != "db" or True]
d["groups"].append({"id": "new-g", "path": "/infra/domains/default/groups/new-g", "display_name": "new-g",
                    "expression": [], "_last_modified_user": "dave", "_last_modified_time": 1900000000000})
d["services"] = [s for s in d["services"] if s["id"] != "app-8443"] + [dict(next(s for s in d["services"] if s["id"] == "app-8443"))]
d["services"][-1]["service_entries"][0]["destination_ports"] = ["9443"]
pol["rules"] = [r for r in pol["rules"] if r["id"] != "r3"]
json.dump(d, open("reports/lon1.json", "w"))
PY
out="$(watch)"
check "a rule changed: action and destinations, by whom" bash -c 'grep -q "changed  *rule app/r1  action ALLOW → DROP; destination_groups +web  carol" <<<"$1"' _ "$out"
check "a policy's sequence, a group's criteria, a service's ports" bash -c 'grep -q "changed  *policy app  sequence_number 10 → 11" <<<"$1" && grep -q "changed  *group web  criteria changed" <<<"$1" && grep -q "changed  *service app-8443" <<<"$1"' _ "$out"
check "a group created in the UI is created outside Git" grep -q "created outside Git  *group new-g" <<<"$out"
check "a rule deleted in the UI is found by the full read" grep -q "deleted  *rule app/r3" <<<"$out"
cp "$SCRATCH/lon1.json" reports/lon1.json

python3 - <<'PY'
import json
d = json.load(open("reports/lon1.json"))
d["exclude_list"] = ["/infra/domains/default/groups/vms"]
json.dump(d, open("reports/lon1.json", "w"))
PY
out="$(watch)"
check "a group added to the DFW exclusion list outside Git is raised, high: it bypasses the firewall" bash -c 'grep -q "created outside Git  *exclusion vms  now bypasses the DFW entirely" <<<"$1" && grep -q "deleted  *exclusion web" <<<"$1"' _ "$out"
cp "$SCRATCH/lon1.json" reports/lon1.json

echo "what is not drift"
python3 - <<'PY'
import json
d = json.load(open("reports/lon1.json"))
d["policies"][0]["rules"][0].update(action="DROP", _last_modified_user="svc-terraform", _last_modified_time=1900000000000)
json.dump(d, open("reports/lon1.json", "w"))
PY
check "a change by a pipeline account (NSX_PIPELINE_USERS) is not drift" bash -c '! NSX_PIPELINE_USERS=svc-terraform python3 scripts/drift.py watch --site lon1 --from-dump reports/lon1.json --report-only 2>&1 | grep -q "rule app/r1"'
cp "$SCRATCH/lon1.json" reports/lon1.json
git_quiet init -q . && git_quiet add -A && git_quiet commit -q -m base
python3 - <<'PY'
import json
d = json.load(open("reports/lon1.json"))
d["policies"][0]["rules"][0].update(_last_modified_time=1600000000000)  # NSX last changed long before the commit
json.dump(d, open("reports/lon1.json", "w"))
PY
sed -i '0,/action: ALLOW/s//action: DROP/' data/policies/app.yaml
git_quiet commit -qam "a merged change, not applied yet"
check "a difference whose data/ file was committed after NSX last changed is a pending apply, not drift" bash -c '! python3 scripts/drift.py watch --site lon1 --from-dump reports/lon1.json --report-only 2>&1 | grep -q "rule app/r1"'
git_quiet checkout -q HEAD~1 -- data/policies/app.yaml
cp "$SCRATCH/lon1.json" reports/lon1.json

echo "scheduled rules"
python3 - <<'PY'
import re
t = open("data/policies/app.yaml").read()
t = t.replace("  r1:\n", "  r1:\n    schedule:\n      timezone: UTC\n      windows:\n        - from: \"08:00\"\n          to: \"10:00\"\n      owner: team\n", 1)
open("data/policies/app.yaml", "w").write(t)
PY
check "(setup) the schedule validates" python3 scripts/validate-data.py
out="$(NSX_SCHEDULE_NOW=2026-11-02T12:00:00Z watch)"
check "a scheduled rule on in NSX outside its window is high severity" bash -c 'grep -q "changed  *rule app/r1  disabled True → False" <<<"$1"' _ "$out"
python3 - <<'PY'
import json, os, sys
os.environ["NSX_SCHEDULE_NOW"] = "2026-11-02T12:00:00Z"
sys.path.insert(0, "scripts")
from nsxlib import drift as w
d = json.load(open("reports/lon1.json"))
objs = [dict(p, resource_type="SecurityPolicy") for p in d["policies"]] + [dict(r, resource_type="Rule") for p in d["policies"] for r in p["rules"]]
items = [i for i in w.compare("lon1", "lm", objs, False) if i["key"] == "rule app/r1"]
sys.exit(0 if items and items[0]["severity"] == "high" else 1)
PY
check "...marked high" test $? -eq 0
out="$(NSX_SCHEDULE_NOW=2026-11-02T09:00:00Z watch)"
check "...and inside its window, on as NSX has it, no difference" bash -c '! grep -q "rule app/r1" <<<"$1"' _ "$out"

echo "the pipeline"
python3 - .gitlab-ci.yml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["watch"]
ok = len(j["rules"]) == 1 and "$WATCH_SITE" in j["rules"][0]["if"] and '"schedule"' in j["rules"][0]["if"] and '"trigger"' in j["rules"][0]["if"]
ok = ok and j["variables"]["NSX_CRED_SCOPE"] == "plan" and j["script"] == ["scripts/watch-job.sh"]
for job in ("data", "terraform", "matrix", "managers"):
    ok = ok and any("$WATCH_SITE" in r.get("if", "") and r.get("when") == "never" for r in d[job]["rules"])
sys.exit(0 if ok else 1)
PY
check "WATCH_SITE runs only the watch job, from a schedule, Run pipeline or a trigger (a log alert), read-only" test $? -eq 0
check "a mirror skips its full read when nothing changed since its last copy" bash -c 'grep -q "drift.py changed --site \"\$site\" --since" scripts/mirror.sh && grep -q "MIRROR_FULL" scripts/mirror.sh'

cd / || exit 1
finish watch
