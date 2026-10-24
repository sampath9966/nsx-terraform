#!/usr/bin/env bash
# Applies with the REAL vmware/nsxt provider, against a writable mock NSX
# (tests/mock_nsx_rw.py) that behaves as NSX does where it matters here.
#
#   tests/apply-provider.sh        (or: tests/run.sh --provider)
#
# Needs Terraform >= 1.9 on PATH (or downloads 1.9.8) and access to
# registry.terraform.io for the provider. A few minutes.
#
# tests/brownfield-provider.sh proves that adoption never writes. This proves
# what happens when changes are written: a new estate applies and then plans
# clean; a rule inserted between two others is one addition; a group or service
# that rules use can be renamed, because the rules are moved off it before NSX
# is asked to delete it; a UI edit is put back; a rule added in the UI inside a
# managed policy, which no plan can see, is found by the drift check; an
# interrupted apply leaves state and NSX agreeing and finishes on the next run;
# transient 503s are retried; and the rendered plan carries no colour codes.
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

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SCRATCH/ca.key" -out "$SCRATCH/ca.pem" -days 1 -subj "/CN=test CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$SCRATCH/key.pem" -out "$SCRATCH/srv.csr" -subj "/CN=127.0.0.1" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\n' >"$SCRATCH/ext.cnf"
openssl x509 -req -in "$SCRATCH/srv.csr" -CA "$SCRATCH/ca.pem" -CAkey "$SCRATCH/ca.key" -CAcreateserial \
	-out "$SCRATCH/cert.pem" -days 1 -extfile "$SCRATCH/ext.cnf" >/dev/null 2>&1
cat "$SCRATCH/ca.pem" ${TEST_EXTRA_CA:+"$TEST_EXTRA_CA"} >"$SCRATCH/trust.pem"
NSX="$SCRATCH/nsx.json" LOG="$SCRATCH/requests.log" CTL="$SCRATCH/control.json"
echo '{}' >"$CTL"
port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/mock_nsx_rw.py" "$NSX" "$LOG" "$port" "$SCRATCH/cert.pem" "$SCRATCH/key.pem" "$CTL" &
mock=$!
trap 'kill "$mock" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 1

printf 'managers:\n  lon1:\n    role: lm\n    host: 127.0.0.1:%s\n    site: lon1\n    vcf_instance: vcf-a\n    vault_path: secret/nsx/lon1\n    tier: prod\n' "$port" >inventory/managers.yaml
: >envs/lon1.backend.hcl
cat >data/groups/app.yaml <<'YAML'
groups:
  app-all:
    display_name: app-all
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - { key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "env|prod" }
  app-web:
    display_name: app-web
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - { key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "tier|web" }
  app-db:
    display_name: app-db
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - { key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "tier|db" }
YAML
cat >data/services/app.yaml <<'YAML'
predefined:
  https: HTTPS
custom:
  app-port:
    display_name: app-port
    owner: lm
    sites: [lon1]
    l4_port_set:
      - protocol: TCP
        destination_ports: ["8443"]
YAML
cat >data/policies/app.yaml <<'YAML'
policy:
  id: app
  name: app
  category: Application
  owner: lm
  sites: [lon1]
  sequence_number: 1000
  rule_management: standalone
  scope: [app-all]
rules:
  web-to-db:
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [app-web]
    destination_groups: [app-db]
    services: [app-port]
    scope: [app-db]
  https-in:
    sequence_number: 300
    action: ALLOW
    direction: IN
    source_groups: [ANY]
    destination_groups: [app-web]
    services: [https]
    scope: [app-web]
  deny-rest:
    sequence_number: 9000
    action: DROP
    direction: IN_OUT
    source_groups: [ANY]
    destination_groups: [app-all]
    scope: [app-all]
YAML
check "(setup) the data validates" python3 scripts/validate-data.py

export NSXT_MANAGER_HOST="127.0.0.1:$port" NSXT_USERNAME=u NSXT_PASSWORD=p NSX_CA_FILE_LON1="$SCRATCH/trust.pem"
unset SSL_CERT_FILE NSXT_ALLOW_UNVERIFIED_SSL
export TF_PLUGIN_CACHE_DIR="$SCRATCH/plugins" ALLOW_LOCAL_STATE=1
mkdir -p "$TF_PLUGIN_CACHE_DIR"
# Plain text to match on. The rendered plan below is checked without this, as CI renders it.
tf() { TF_CLI_ARGS=-no-color scripts/tf.sh "$@" 2>&1; }
apply() { APPROVE=yes TF_CLI_ARGS=-no-color scripts/tf.sh apply local-security lon1 2>&1; }
faults() { echo "$1" >"$CTL"; }
nsx() { # nsx '<python statement on d, the objects by path>': an engineer in the UI
	python3 - "$NSX" "$1" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); exec(sys.argv[2]); json.dump(d, open(f, "w"), indent=1)
PY
	sleep 1
}
P=/infra/domains/default/security-policies/app

echo "a new estate"
out="$(tf plan local-security lon1)"
check "everything is created: 3 groups, 1 service, the policy and its 3 rules" grep -q "Plan: 8 to add, 0 to change, 0 to destroy" <<<"$out"
scripts/tf.sh show local-security lon1 >"$SCRATCH/plan.txt" 2>/dev/null
check "the rendered plan has no colour codes, and its summary starts the line" bash -c '! grep -q $'"'"'\x1b'"'"' "$1" && grep -q "^Plan: 8 to add" "$1"' _ "$SCRATCH/plan.txt"
check "it applies" grep -q "Apply complete! Resources: 8 added, 0 changed, 0 destroyed" <<<"$(apply)"
check "the next plan changes nothing" grep -q "No changes" <<<"$(tf plan local-security lon1)"

echo "a rule added to a policy that ends in a catch-all deny"
out="$(python3 scripts/add-rule.py --policy app --rule web-to-web --source app-web --destination app-web --service https --scope app-web 2>&1)"
check "is placed before the deny, where it can match" bash -c 'grep -q "at sequence 400" <<<"$1" && grep -q "before the catch-all deny .deny-rest." <<<"$1"' _ "$out"
out="$(tf plan local-security lon1)"
check "is one addition, nothing else touched" grep -q "Plan: 1 to add, 0 to change, 0 to destroy" <<<"$out"
check "...and applies" grep -q "Resources: 1 added, 0 changed, 0 destroyed" <<<"$(apply)"

# NSX refuses to delete a group or service a rule still uses. The rules must be
# moved off it first, in the same apply; otherwise that apply fails half-way and
# every retry fails the same way.
rename() { # rename <old> <new> <address of the old one>
	sed -i "s/\b$1\b/$2/g" data/groups/app.yaml data/services/app.yaml data/policies/app.yaml
	echo "lon1 local-security $3" >allow-destroy.txt
	: >"$LOG"
}
order_ok() { # order_ok <deleted path>: the delete comes after every rule update
	python3 - "$LOG" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
rules = [i for i, l in enumerate(lines) if l.startswith("PATCH ") and "/rules/" in l]
gone = [i for i, l in enumerate(lines) if l.startswith("DELETE ") and l.split()[1].split("?")[0].endswith(sys.argv[2])]
sys.exit(0 if rules and gone and min(gone) > max(rules) else 1)
PY
}
echo "renaming a group that rules use (approved in allow-destroy.txt)"
rename app-db app-database 'module.base_groups.nsxt_policy_group.this["app-db"]'
out="$(tf plan local-security lon1)"
check "plans as one new group, the rule moved to it, and the old one deleted" grep -q "Plan: 1 to add, 1 to change, 1 to destroy" <<<"$out"
out="$(apply)"
check "applies" grep -q "Apply complete! Resources: 1 added, 1 changed, 1 destroyed" <<<"$out"
check "...NSX was asked to delete the old group only after the rule left it" order_ok "/groups/app-db"
check "...and the next plan changes nothing" grep -q "No changes" <<<"$(tf plan local-security lon1)"
echo "renaming a service that a rule uses"
rename app-port app-port-v2 'module.services.nsxt_policy_service.this["app-port"]'
out="$(apply_after_plan() { tf plan local-security lon1 >/dev/null; apply; }; apply_after_plan)"
check "applies, the rule moved before the old service is deleted" bash -c 'grep -q "Resources: 1 added, 1 changed, 1 destroyed" <<<"$1"' _ "$out"
check "...in that order" order_ok "/services/app-port"
rm -f allow-destroy.txt

echo "a change made in the UI"
nsx "r = d['$P/rules/web-to-db']; r['action'] = 'DROP'; r['_revision'] += 1"
out="$(tf plan local-security lon1)"
check "the plan puts it back" bash -c 'grep -q "Plan: 0 to add, 1 to change, 0 to destroy" <<<"$1" && grep -q "action .*= \"DROP\" -> \"ALLOW\"" <<<"$1"' _ "$out"
check "...and does" grep -q "Resources: 0 added, 1 changed" <<<"$(apply)"

echo "a rule added in the UI inside a managed policy"
nsx "import copy; r = copy.deepcopy(d['$P/rules/https-in']); r.update(id='backdoor', path='$P/rules/backdoor', display_name='backdoor', relative_path='backdoor', sequence_number=1, source_groups=['ANY'], destination_groups=['ANY'], services=['ANY'], rule_id=99999, _last_modified_user='mallory'); d[r['path']] = r"
check "no plan can see it: Terraform only knows the rules it was given" grep -q "No changes" <<<"$(tf plan local-security lon1)"
out="$(scripts/drift.sh local-security lon1 2>&1)"; rc=$?
check "the drift check finds it, says what it allows and who added it, and exits 2" bash -c '[ "$2" = 2 ] && grep -q "UNMANAGED RULE app/backdoor: ALLOW ANY -> ANY on ANY" <<<"$1" && grep -q "mallory" <<<"$1"' _ "$out" "$rc"
nsx "d.pop('$P/rules/backdoor')"
out="$(scripts/drift.sh local-security lon1 2>&1)"; rc=$?
check "...and once it is gone, the drift check is clean" bash -c '[ "$2" = 0 ] && grep -q "no unmanaged rules" <<<"$1"' _ "$out" "$rc"

echo "transient errors from the manager"
for i in 1 2 3 4 5 6; do
	python3 scripts/add-rule.py --policy app --rule "extra-$i" --source app-web --destination app-database --service https --scope app-database >/dev/null 2>&1
done
tf plan local-security lon1 >/dev/null
faults '{"write_fail_rate": 0.2, "fail_codes": [503]}'
out="$(apply)"
faults '{}'
check "an apply through 20% of writes failing with 503 completes: the provider retries" grep -q "Resources: 6 added" <<<"$out"
check "...and the next plan changes nothing" grep -q "No changes" <<<"$(tf plan local-security lon1)"

echo "an apply interrupted part-way (a cancelled job)"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
	python3 scripts/add-rule.py --policy app --rule "late-$i" --source app-web --destination app-database --service https --scope app-database >/dev/null 2>&1
done
tf plan local-security lon1 >/dev/null
faults '{"latency_ms": 400}'
(apply >"$SCRATCH/interrupted.log") &
job=$!
descendant() { # descendant <pid> <command name>: the first process of that name under pid
	ps -e -o pid=,ppid=,comm= | python3 -c '
import sys
root, name = sys.argv[1], sys.argv[2]
rows = [l.split(None, 2) for l in sys.stdin if l.strip()]
kids = {}
for pid, ppid, comm in rows: kids.setdefault(ppid, []).append((pid, comm.strip()))
todo = [root]
while todo:
    for pid, comm in kids.get(todo.pop(), []):
        if comm == name: print(pid); sys.exit(0)
        todo.append(pid)' "$1" "$2"
}
for _ in $(seq 1 60); do
	[ "$(grep -c '^PATCH .*/rules/late-' "$LOG" 2>/dev/null)" -ge 3 ] && break
	sleep 0.5
done
tfpid="$(descendant "$job" terraform)"
[ -n "$tfpid" ] && kill -TERM "$tfpid"
wait "$job"
faults '{}'
python3 - "$NSX" "$T/.local-state/lon1-local-security.tfstate" >"$SCRATCH/counts" <<'PY'
import json, sys
nsx = json.load(open(sys.argv[1])); state = json.load(open(sys.argv[2]))
live = sorted(k.rsplit("/", 1)[1] for k in nsx if "/rules/late-" in k)
held = sorted(i["index_key"] for r in state["resources"] if r["type"] == "nsxt_policy_security_policy_rule"
              for i in r["instances"] if str(i["index_key"]).startswith("late-"))
print(len(live), len(held), "same" if live == held else "differ")
PY
read -r live _ same <"$SCRATCH/counts"
check "stopped part-way: some of the 12 rules written, not all" bash -c '[ "$1" -gt 0 ] && [ "$1" -lt 12 ]' _ "$live"
check "...and state holds exactly the rules NSX holds" test "$same" = same
out="$(tf plan local-security lon1)"
check "the next plan creates only the rest" grep -q "Plan: $((12 - live)) to add, 0 to change, 0 to destroy" <<<"$out"
check "...which applies" grep -q "Resources: $((12 - live)) added" <<<"$(apply)"
check "...and then nothing is left to do" grep -q "No changes" <<<"$(tf plan local-security lon1)"

kill "$mock" 2>/dev/null
finish apply-provider
