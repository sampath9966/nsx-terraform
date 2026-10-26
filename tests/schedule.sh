#!/usr/bin/env bash
# Scheduled rules: the schedule itself, its validation, what the time follower
# switches, the guard that holds it to on/off, the drift check that knows the
# schedules, expiry notices, and the conversion of a Local Manager's time windows.
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
mkdir -p data/groups data/policies data/services
cat >data/groups/apps.yaml <<'YAML'
groups:
  erp-db:
    display_name: erp-db
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|erp"}
  vendor-hosts:
    display_name: vendor-hosts
    owner: gm
    criteria:
      - conditions:
          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|vendor"}
YAML
cat >data/policies/erp.yaml <<'YAML'
policy:
  id: erp
  name: erp
  category: Application
  owner: lm
  sites: [lon1]
  scope: [erp-db]
  rule_management: standalone
rules:
  office-hours:
    sequence_number: 100
    action: ALLOW
    direction: IN_OUT
    source_groups: [erp-db]
    destination_groups: [erp-db]
    scope: [erp-db]
    schedule:
      timezone: Asia/Kolkata
      windows:
        - days: [MON, TUE, WED, THU, FRI]
          from: "09:00"
          to: "18:00"
      owner: erp-team
  night-maintenance:
    sequence_number: 200
    action: ALLOW
    direction: IN_OUT
    source_groups: [erp-db]
    destination_groups: [erp-db]
    scope: [erp-db]
    schedule:
      timezone: Asia/Kolkata
      windows:
        - days: [SAT]
          from: "22:00"
          to: "02:00"
      starts: 2026-11-01
      expires: 2026-12-31 18:00
      owner: erp-team
      ticket: CHG0012345
  always:
    sequence_number: 300
    action: ALLOW
    direction: IN_OUT
    source_groups: [erp-db]
    destination_groups: [erp-db]
    scope: [erp-db]
YAML
cat >data/policies/vendor.yaml <<'YAML'
policy:
  id: vendor
  name: vendor
  category: Application
  owner: gm
  scope: [vendor-hosts]
  rule_management: standalone
rules:
  vendor-window:
    sequence_number: 100
    action: ALLOW
    direction: IN_OUT
    source_groups: [vendor-hosts]
    destination_groups: [vendor-hosts]
    scope: [vendor-hosts]
    schedule:
      timezone: UTC
      windows:
        - from: "08:00"
          to: "10:00"
      owner: vendor-mgmt
YAML

echo "the schedule itself"
python3 - <<'PY'
import sys
from datetime import datetime, timezone
sys.path.insert(0, "scripts")
from nsxlib import schedules as s
office = {"timezone": "Asia/Kolkata", "windows": [{"days": ["MON", "TUE", "WED", "THU", "FRI"], "from": "09:00", "to": "18:00"}], "owner": "x"}
night = {"timezone": "Asia/Kolkata", "windows": [{"days": ["SAT"], "from": "22:00", "to": "02:00"}], "owner": "x",
         "starts": "2026-11-01", "expires": "2026-12-31 18:00"}
U = lambda t: datetime.fromisoformat(t).replace(tzinfo=timezone.utc)
cases = [
    (office, "2026-11-02T04:00", True),    # Monday 09:30 IST
    (office, "2026-11-02T03:00", False),   # Monday 08:30 IST
    (office, "2026-11-02T12:30", False),   # Monday 18:00 IST: the end is exclusive
    (office, "2026-11-07T05:00", False),   # Saturday
    (night, "2026-11-07T17:00", True),     # Saturday 22:30 IST
    (night, "2026-11-07T20:00", True),     # Sunday 01:30 IST: past midnight
    (night, "2026-11-07T21:00", False),    # Sunday 02:30 IST
    (night, "2026-11-08T17:00", False),    # Sunday 22:30 IST
    (night, "2026-10-31T17:00", False),    # Saturday, before it starts
    (night, "2027-01-02T17:00", False),    # Saturday, after it expires
    ({"timezone": "UTC", "owner": "x", "expires": "2026-11-05"}, "2026-11-04T23:59", True),
    ({"timezone": "UTC", "owner": "x", "expires": "2026-11-05"}, "2026-11-05T00:00", False),
    ({"timezone": "UTC", "owner": "x", "windows": [{"from": "00:00", "to": "00:00"}]}, "2026-11-04T12:00", True),
]
bad = [(c, t) for c, t, want in cases if s.active(c, U(t)) != want]
for c, t in bad:
    print("wrong at", t, c, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
check "windows, days, past midnight, starts and expires, in the schedule's own zone" test $? -eq 0
python3 - <<'PY'
import sys
sys.path.insert(0, "scripts")
from nsxlib import schedules as s
p = s.problems({"timezone": "Mars/Olympus", "owner": "x"})
q = s.problems({"timezone": "UTC", "windows": [{"days": ["FUNDAY"], "from": "9", "to": "25:00"}], "starts": "2026-12-01", "expires": "2026-11-01"})
ok = "unknown time zone" in p[0] and any("owner is required" in x for x in q) and any("FUNDAY" in x for x in q) \
    and any("from" in x and "HH:MM" in x for x in q) and any("to" in x and "HH:MM" in x for x in q) and any("not after starts" in x for x in q)
sys.exit(0 if ok else 1)
PY
check "a schedule that cannot be enforced says why" test $? -eq 0

echo "validation"
check "valid schedules validate" python3 scripts/validate-data.py
cp data/policies/erp.yaml "$SCRATCH/erp.yaml"
sed -i '0,/timezone: Asia\/Kolkata/s//timezone: Nowhere\/Land/' data/policies/erp.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "an unknown time zone is an error, naming the rule" grep -q "rules.office-hours.schedule: unknown time zone 'Nowhere/Land'" <<<"$out"
cp "$SCRATCH/erp.yaml" data/policies/erp.yaml
sed -i '0,/action: ALLOW/s//action: DROP/' data/policies/erp.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "a scheduled DROP is a warning: what it blocks is allowed outside its windows" grep -q "a scheduled DROP is off outside its windows" <<<"$out"
cp "$SCRATCH/erp.yaml" data/policies/erp.yaml

echo "what Terraform is given, and what the follower switches"
out="$(NSX_SCHEDULE_NOW=2026-11-07T17:00:00Z python3 scripts/schedule.py tfvars --stack local-security --site lon1)"
check "on Saturday night only the weekday rule is off; an unscheduled rule is never listed" python3 -c "import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d=={'scheduled_off':{'erp':['office-hours']}} else 1)" "$out"
out="$(NSX_SCHEDULE_NOW=2026-11-07T17:00:00Z python3 scripts/schedule.py tfvars --stack global-security --site gm1)"
check "a Global Manager's scheduled rule is evaluated the same way, in its own stack" python3 -c "import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d=={'scheduled_off':{'vendor':['vendor-window']}} else 1)" "$out"
out="$(NSX_SCHEDULE_NOW=2026-11-02T08:30:00Z python3 scripts/schedule.py tfvars --stack global-security --site gm1)"
check "...and on inside its window" python3 -c "import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d=={'scheduled_off':{}} else 1)" "$out"
python3 - "$SCRATCH/state.json" <<'PY'
import json, sys
def inst(key, disabled): return {"index_key": key, "attributes": {"disabled": disabled}}
json.dump({"version": 4, "resources": [{"module": 'module.policies["erp"]', "mode": "managed", "type": "nsxt_policy_security_policy_rule",
           "name": "this", "instances": [inst("office-hours", False), inst("night-maintenance", True), inst("always", False)]}]},
          open(sys.argv[1], "w"))
PY
out="$(NSX_SCHEDULE_NOW=2026-11-07T17:00:00Z python3 scripts/schedule.py switch --stack local-security --site lon1 --state "$SCRATCH/state.json")"
check "the follower switches exactly the rules whose state differs from the schedule" bash -c '[ "$(wc -l <<<"$1")" = 2 ] && grep -qx "module.policies\[\"erp\"\].nsxt_policy_security_policy_rule.this\[\"office-hours\"\]" <<<"$1" && grep -qx "module.policies\[\"erp\"\].nsxt_policy_security_policy_rule.this\[\"night-maintenance\"\]" <<<"$1"' _ "$out"
out="$(NSX_SCHEDULE_NOW=2026-11-02T04:00:00Z python3 scripts/schedule.py switch --stack local-security --site lon1 --state "$SCRATCH/state.json")"
check "...and nothing when state already agrees" test -z "$out"
check "every plan of a security stack is given the schedules; the rule's disabled follows them" bash -c 'grep -q "schedule.auto.tfvars.json" scripts/tf.sh && grep -q "contains(var.rules_off, each.key)" modules/dfw-policy/main.tf && grep -q "rules_off     = lookup(var.scheduled_off, each.key, \[\])" stacks/local-security/main.tf stacks/global-security/main.tf'
check "the Terraform input is never committed" grep -qx '\*.auto.tfvars.json' .gitignore

echo "plan-guard --schedule"
guard_plan() { # actions type changed-field
	python3 - "$@" <<'PY'
import json, sys
actions, kind, field = sys.argv[1].split(","), sys.argv[2], sys.argv[3]
before = {"disabled": False, "action": "ALLOW", "revision": 1}
after = dict(before, **({field: True} if field == "disabled" else {field: "DROP"}))
print(json.dumps({"resource_changes": [{"address": "module.policies[\"erp\"].x.this[\"r\"]", "mode": "managed", "type": kind,
       "change": {"actions": actions, "before": before, "after": after, "after_unknown": {"revision": True}}}]}))
PY
}
check "on/off of a rule is allowed" bash -c 'python3 scripts/plan-guard.py --site lon1 --stack local-security --schedule <<<"$1"' _ "$(guard_plan update nsxt_policy_security_policy_rule disabled)"
check "...anything else on a rule is refused" bash -c '! python3 scripts/plan-guard.py --site lon1 --stack local-security --schedule <<<"$1"' _ "$(guard_plan update nsxt_policy_security_policy_rule action)"
check "...as is a change to any other resource" bash -c '! python3 scripts/plan-guard.py --site lon1 --stack local-security --schedule <<<"$1"' _ "$(guard_plan update nsxt_policy_group disabled)"
check "...and a create or a delete" bash -c '! python3 scripts/plan-guard.py --site lon1 --stack local-security --schedule <<<"$1" && ! python3 scripts/plan-guard.py --site lon1 --stack local-security --schedule <<<"$2"' _ "$(guard_plan create nsxt_policy_security_policy_rule disabled)" "$(guard_plan delete nsxt_policy_security_policy_rule disabled)"
check "the follower plans only the rules to switch, without reading NSX, and passes the guard" bash -c 'grep -q "run plan -refresh=false -out=tfplan -input=false \"\${targets\[@\]}\"" scripts/tf.sh && grep -q "guard --schedule" scripts/tf.sh && grep -q "NSX not contacted" scripts/tf.sh'

echo "the change watch knows the schedules"
check "a high-severity drift issue says so in its title and label (tests/watch.sh: a rule on outside its window)" bash -c 'grep -q "\[HIGH\] " scripts/nsxlib/drift.py && grep -q "severity::high" scripts/nsxlib/drift.py'

echo "expiry"
out="$(NSX_SCHEDULE_NOW=2026-12-28T00:00:00Z python3 scripts/schedule.py report)"
check "a rule expiring within a week is reported" grep -q "^expiring  data/policies/erp.yaml night-maintenance  2026-12-31T18:00+05:30" <<<"$out"
out="$(NSX_SCHEDULE_NOW=2027-01-05T00:00:00Z python3 scripts/schedule.py report)"
check "...expired" grep -q "^expired " <<<"$out"
out="$(NSX_SCHEDULE_NOW=2027-01-20T00:00:00Z python3 scripts/schedule.py report)"
check "...and due for removal after the grace period" grep -q "^remove " <<<"$out"
gl_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 "$REPO/tests/fake_gitlab_api.py" "$gl_port" "$SCRATCH/gl.log" &
gl_pid=$!
trap 'kill $gl_pid 2>/dev/null; rm -rf "$SCRATCH"' EXIT
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$gl_port") 2>/dev/null && break; sleep 0.1; done
export CI_API_V4_URL="http://127.0.0.1:$gl_port/api/v4" CI_PROJECT_ID=7 NSX_BOT_TOKEN=T
out="$(NSX_SCHEDULE_NOW=2026-12-28T00:00:00Z python3 scripts/schedule.py notify)"
check "an expiring rule raises one nsx-schedule issue, naming its owner and ticket" python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];p=[x['body'] for x in l if x['method']=='POST'];sys.exit(0 if len(p)==1 and p[0]['labels']=='nsx-schedule' and 'erp-team' in p[0]['description'] and 'CHG0012345' in p[0]['description'] else 1)" "$SCRATCH/gl.log"
out="$(NSX_SCHEDULE_NOW=2026-12-29T00:00:00Z python3 scripts/schedule.py notify)"
check "...once" bash -c '[ "$(grep -c "\"method\": \"POST\"" "$1")" = 1 ] && grep -q "already in an issue" <<<"$2"' _ "$SCRATCH/gl.log" "$out"
NSX_SCHEDULE_NOW=2027-01-05T00:00:00Z python3 scripts/schedule.py notify >/dev/null
check "...and again when it has expired" bash -c '[ "$(grep -c "\"method\": \"POST\"" "$1")" = 2 ]' _ "$SCRATCH/gl.log"

echo "the pipeline"
python3 - .gitlab-ci.yml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["schedule"]
ok = len(j["rules"]) == 1 and "$SCHEDULE_FOLLOW" in j["rules"][0]["if"] and '"schedule"' in j["rules"][0]["if"] and "$CI_DEFAULT_BRANCH" in j["rules"][0]["if"]
ok = ok and j["variables"]["NSX_CRED_SCOPE"] == "apply" and j["script"] == ["scripts/schedule-job.sh"] and j["interruptible"] is False
for job in ("data", "terraform", "matrix", "managers"):
    ok = ok and any("$SCHEDULE_FOLLOW" in r.get("if", "") and r.get("when") == "never" for r in d[job]["rules"])
sys.exit(0 if ok else 1)
PY
check "SCHEDULE_FOLLOW runs only the schedule job, on the default branch, with the apply credential" test $? -eq 0
check "the follower skips managers in mirror mode" grep -q "is in mirror mode, still run from the UI: nothing is switched" scripts/tf.sh

echo "converting a Local Manager's time windows"
mkdir -p reports
python3 - <<'PY'
import json
D = "/infra/domains/default"
def rule(p, i, name, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{p}/rules/{i}", "display_name": name, "sequence_number": 10, "action": "ALLOW",
                 "source_groups": ["ANY"], "destination_groups": ["ANY"], "services": ["ANY"], "scope": ["ANY"]}, **kw)
U = "0b7c0099-1111-4222-8333-444455556666"
dump = {"groups": [], "services": [], "domain": "default", "policies": [
    {"id": "pay", "path": f"{D}/security-policies/pay", "display_name": "pay", "rules": [
        rule("pay", U, "Vendor Night", scheduler_path="/infra/firewall-schedulers/night"),
        rule("pay", "local", "local", scheduler_path="/infra/firewall-schedulers/local"),
        rule("pay", "odd", "odd", scheduler_path="/infra/firewall-schedulers/odd"),
        rule("pay", "plain", "plain")]},
    {"id": "windowed", "path": f"{D}/security-policies/windowed", "display_name": "windowed", "scheduler_path": "/infra/firewall-schedulers/once",
     "rules": [rule("windowed", "a", "a"), rule("windowed", "b", "b")]}]}
sch = {"results": [
    {"id": "night", "path": "/infra/firewall-schedulers/night", "display_name": "night", "recurring": True, "days": ["SATURDAY", "SUNDAY"],
     "start_time": "22:00", "end_time": "02:00", "time_zone": "UTC", "start_date": "2026-11-01", "end_date": "2026-12-31"},
    {"id": "local", "path": "/infra/firewall-schedulers/local", "display_name": "local", "recurring": True, "days": ["MONDAY"],
     "start_time": "09:00", "end_time": "17:00", "time_zone": "LOCAL"},
    {"id": "odd", "path": "/infra/firewall-schedulers/odd", "display_name": "odd", "recurring": True, "days": ["MONDAY"],
     "start_time": "09:00", "end_time": "17:00", "time_zone": "UTC", "interval_minutes": 5},
    {"id": "once", "path": "/infra/firewall-schedulers/once", "display_name": "once", "recurring": False,
     "start_date": "2026-11-10", "start_time": "20:00", "end_date": "2026-11-11", "end_time": "04:00", "time_zone": "UTC"}]}
json.dump(dump, open("reports/lon1-raw.json", "w")); json.dump(sch, open("reports/lon1-sch.json", "w"))
PY
out="$(python3 scripts/schedule.py convert --site lon1 --from-dump reports/lon1-raw.json --schedulers reports/lon1-sch.json 2>&1)"
R="$(cat reports/time-windows-lon1.md 2>/dev/null)"
check "a recurring window becomes windows, starts and an expiry the day after its end date" bash -c 'grep -q "## data/policies/pay.yaml, rule Vendor-Night (Vendor Night)" <<<"$1" && grep -q "days: \[SAT, SUN\]" <<<"$1" && grep -q "from: \"22:00\"" <<<"$1" && grep -q "expires: 2027-01-01" <<<"$1"' _ "$R"
check "a window set on a policy is converted for each of its rules; a one-off one by starts and expires" bash -c 'grep -q "windowed.yaml, rule a" <<<"$1" && grep -q "windowed.yaml, rule b" <<<"$1" && grep -q "starts: \"2026-11-10 20:00\"" <<<"$1"' _ "$R"
check "a window in the manager's local time is not guessed: it asks for --timezone" bash -c 'grep -q "NOT CONVERTED  data/policies/pay.yaml, rule local: .*--timezone" <<<"$1"' _ "$out"
check "a window with a field this does not know is not converted, and says which" grep -q "rule odd: its time window odd carries interval_minutes" <<<"$out"
check "owner is left for a person to fill in" grep -q "owner: \"TODO" <<<"$R"
out="$(python3 scripts/schedule.py convert --site lon1 --from-dump reports/lon1-raw.json --schedulers reports/lon1-sch.json --timezone Asia/Kolkata 2>&1)"
check "...and with --timezone it is converted in that zone" bash -c 'grep -q "timezone: Asia/Kolkata" reports/time-windows-lon1.md && ! grep -q "rule local:" <<<"$1"' _ "$out"
check "a converted block, owner filled in, validates" python3 - <<'PY'
import re, sys
sys.path.insert(0, "scripts")
from nsxlib import schedules as s
import yaml
text = open("reports/time-windows-lon1.md").read()
blocks = [yaml.safe_load(b) for b in re.findall(r"```yaml\n(.*?)```", text, re.S)]
bad = [p for b in blocks for p in s.problems(dict(b["schedule"], owner="team"))]
sys.exit(0 if blocks and not bad else 1)
PY

cd / || exit 1
finish schedule
