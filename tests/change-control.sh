#!/usr/bin/env bash
# Change control (NSX_APPLY_MODE=approval): scripts/change-control.py and
# scripts/approve-apply.sh against a stand-in for the GitLab API, and the
# pipeline that wires them. Offline: no GitLab, no NSX, no Terraform.
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
    vcf_instance: v
    vault_path: secret/gm1
    tier: prod
  lon1:
    role: lm
    host: lon1.example.net
    site: lon1
    vcf_instance: v
    vault_path: secret/lon1
    tier: prod
    stacks: [local-security, local-network]
  par1:
    role: lm
    host: par1.example.net
    site: par1
    vcf_instance: v
    vault_path: secret/par1
    tier: prod
    stacks: [local-security]
  nyc1:
    role: lm
    host: nyc1.example.net
    site: nyc1
    vcf_instance: v
    vault_path: secret/nyc1
    tier: prod
    mode: mirror
INV

# History on the default branch: base, then two merges.
git init -q -b main && git_quiet add -A && git_quiet commit -m base
git_quiet commit --allow-empty -m "merge !11" && A="$(git rev-parse HEAD)"
git_quiet commit --allow-empty -m "merge !12" && B="$(git rev-parse HEAD)"

mr() { # mr iid title author merger
	printf '{"iid": %s, "title": "%s", "state": "merged", "target_branch": "main", "author": {"username": "%s"}, "merge_user": {"username": "%s"}, "web_url": "http://gitlab.test/mr/%s"}' "$1" "$2" "$3" "$4" "$1"
}
cat >"$SCRATCH/seed.json" <<SEED
{"members": [
  {"username": "alice", "access_level": 40}, {"username": "bob", "access_level": 40},
  {"username": "dave", "access_level": 40}, {"username": "carol", "access_level": 30},
  {"username": "erin", "access_level": 30}, {"username": "project_7_bot_x1", "access_level": 40}],
 "commit_mrs": {"$A": [$(mr 11 "Allow web to db" dave alice)], "$B": [$(mr 12 "Tag the new VMs" erin erin)]},
 "mr_approvals": {"12": ["bob"]},
 "pipeline_jobs": {"100": [{"id": 900, "name": "approve and apply", "status": "manual"}]}}
SEED
port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/fake_gitlab_cc.py" "$port" SECRET-BOT-TOKEN "$SCRATCH/seed.json" &
api=$!
trap 'kill "$api" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 1
st() { curl -s "http://127.0.0.1:$port/__state"; }
q() { st | python3 -c "import json,sys; s=json.load(sys.stdin); print($1)"; }
emoji() { curl -s -X POST "http://127.0.0.1:$port/__emoji/$1/$2" >/dev/null; }
export CI_API_V4_URL="http://127.0.0.1:$port/api/v4" CI_PROJECT_ID=7 NSX_BOT_TOKEN=SECRET-BOT-TOKEN \
	CI_DEFAULT_BRANCH=main CI_PIPELINE_URL=http://gitlab.test/pipelines/100 CI_JOB_URL=http://gitlab.test/jobs/900
cc() { CI_PIPELINE_ID="${PIPE:-100}" CI_COMMIT_SHA="${HEAD_SHA:-$B}" python3 scripts/change-control.py "$@" 2>&1; }
plans() { # plans <gm1 global-security> <lon1 local-security> <lon1 local-network> <par1 local-security>, each "change" or "none"
	local i=0 target
	for target in "global-security gm1" "local-security lon1" "local-network lon1" "local-security par1"; do
		i=$((i + 1))
		set -- "$@"
		local what="${!i}" stack="${target% *}" site="${target#* }"
		if [ "$what" = change ]; then
			printf 'Terraform will perform the following actions:\n  # x will be created\nPlan: 1 to add, 0 to change, 0 to destroy.\n' >"plan-$stack-$site.txt"
		else
			printf 'No changes. Your infrastructure matches the configuration.\n' >"plan-$stack-$site.txt"
		fi
		mkdir -p "plans/$site/$stack" && printf 'plan for %s/%s\n' "$site" "$stack" >"plans/$site/$stack/tfplan" && echo "$site" >"plans/$site/$stack/tfplan.site"
	done
	printf 'Plan: 9 to add, 0 to change, 0 to destroy.\n' >plan-local-security-nyc1.txt
}

echo "nothing to approve"
plans none none none none
out="$(cc open)"
check "plans that change nothing raise no change request" bash -c 'grep -q "Nothing to approve" <<<"$1" && grep -qx "CHANGE_ISSUE=" change.env' _ "$out"
check "...and the approve job has nothing to do, and passes" bash -c 'CHANGE_ISSUE= scripts/approve-apply.sh >/dev/null 2>&1'
check "a mirror manager's plan is not change-controlled" test "$(q 'len(s["issues"])')" = 0

echo "a change request"
plans change change none change
out="$(cc open)"
check "the change request is raised" bash -c 'grep -q "change request: http://gitlab.test/issues/1" <<<"$1" && grep -qx "CHANGE_ISSUE=1" change.env' _ "$out"
D="$(q 's["issues"][0]["description"]')"
check "...listing every manager's plan, a mirror manager left out" bash -c 'grep -q "| gm1 | global-security | Plan: 1 to add" <<<"$1" && grep -q "| lon1 | local-network | No changes. |" <<<"$1" && ! grep -q nyc1 <<<"$1"' _ "$D"
check "...the merge request in it, its author and who reviewed it" grep -q "| \[!12\](http://gitlab.test/mr/12) | Tag the new VMs | @erin | @bob |" <<<"$D"
check "...the full plans" grep -q "<summary>lon1 / local-security: Plan: 1 to add" <<<"$D"
check "...and how many approvals it needs" grep -q "It needs \*\*2\*\* approval(s)" <<<"$D"
check "...labelled as waiting" test "$(q 's["issues"][0]["labels"]')" = "['nsx-change', 'nsx-awaiting-approval']"

echo "approvals"
export CHANGE_ISSUE=1
out="$(cc gate)"; rc=$?
check "no approvals: refused" bash -c '[ "$2" = 2 ] && grep -q "0 of 2 approval(s)" <<<"$1"' _ "$out" "$rc"
emoji 1 erin
emoji 1 project_7_bot_x1
emoji 1 carol
out="$(cc gate)"; rc=$?
check "the author's approval does not count" grep -q "not counted  @erin: an author of a change in it" <<<"$out"
check "...nor a bot's, nor a Developer's without a standby approval" bash -c 'grep -q "not counted  @project_7_bot_x1: not a Maintainer" <<<"$1" && grep -q "not counted  @carol: not a Maintainer, and no standby approval in force" <<<"$1" && [ "$2" = 2 ]' _ "$out" "$rc"
emoji 1 bob
out="$(cc gate)"; rc=$?
check "one Maintainer of two required: still refused" bash -c '[ "$2" = 2 ] && grep -q "counted      @bob (Maintainer)" <<<"$1" && grep -q "1 of 2" <<<"$1"' _ "$out" "$rc"
printf 'delegations:\n  - from: alice\n    to: carol\n    until: 2020-01-31\n    reason: leave\n' >inventory/delegations.yaml
check "a standby approval that has ended does not count" grep -q "1 of 2" <<<"$(cc gate)"
printf 'delegations:\n  - from: erin\n    to: carol\n    until: 2999-01-31\n    reason: leave\n' >inventory/delegations.yaml
check "nor one handed over by someone who is not a Maintainer" grep -q "1 of 2" <<<"$(cc gate)"
printf 'delegations:\n  - from: alice\n    to: carol\n    until: 2999-01-31\n    reason: leave\n' >inventory/delegations.yaml
emoji 1 alice
out="$(cc gate)"; rc=$?
check "a Maintainer and their stand-in count once between them" bash -c '[ "$2" = 0 ] && grep -q "counted      @carol (standing in for alice" <<<"$1" && grep -q "not counted  @alice: counts as alice, who is counted already" <<<"$1"' _ "$out" "$rc"
check "approved: the change request moves to applying, saying who approved" bash -c 'python3 -c "import json,sys;s=json.load(sys.stdin);sys.exit(0 if s[\"issues\"][0][\"labels\"]==[\"nsx-change\",\"nsx-applying\"] and \"Approved by @carol, @bob\" in s[\"notes\"][\"1\"][-1] else 1)" <<<"$1"' _ "$(st)"
check "the gate refuses a change request that is not this pipeline's" grep -q "is the change request of pipeline 100, not this one" <<<"$(PIPE=999 cc gate)"

echo "apply and record"
stubs() { # stand-ins for the credential wrapper and Terraform
	cat >scripts/with-credentials.sh <<'STUB'
#!/usr/bin/env bash
shift
[ "$1" = "--" ] && shift
exec "$@"
STUB
	cat >scripts/tf.sh <<'STUB'
#!/usr/bin/env bash
echo "tf $*" >>"$TF_LOG"
[ "$(cat "stacks/$2/tfplan")" = "plan for $3/$2" ] || { echo "Error: wrong plan for $3/$2"; exit 1; }
[ "${FAIL_SITE:-}" = "$3" ] && { echo "Error: the manager refused it"; exit 1; }
echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed."
STUB
	chmod +x scripts/with-credentials.sh scripts/tf.sh
}
stubs
export TF_LOG="$SCRATCH/tf.log"
: >"$TF_LOG"
out="$(CI_PIPELINE_ID=100 CI_COMMIT_SHA="$B" scripts/approve-apply.sh 2>&1)"; rc=$?
check "the approve job applies every changed plan and passes" bash -c '[ "$2" = 0 ] && [ "$(cat "$1")" = "$(printf "tf apply global-security gm1\ntf apply local-security lon1\ntf apply local-security par1")" ]' _ "$TF_LOG" "$rc"
check "...each manager its own plan, though two share a stack" bash -c '! grep -q "wrong plan" <<<"$1"' _ "$out"
check "...skipping what changes nothing, and never a mirror manager" bash -c 'grep -q "== lon1/local-network: no changes, skipped" <<<"$1" && ! grep -q nyc1 "$2"' _ "$out" "$TF_LOG"
check "the change request is closed as applied, with each result" bash -c 'python3 -c "import json,sys;s=json.load(sys.stdin);i=s[\"issues\"][0];n=s[\"notes\"][\"1\"][-1];sys.exit(0 if i[\"state\"]==\"closed\" and i[\"labels\"]==[\"nsx-change\",\"nsx-applied\"] and \"| par1/local-security | Apply complete!\" in n and \"@carol (for @alice)\" in n else 1)" <<<"$1"' _ "$(st)"
W="$(q 's["wiki"]["NSX-Change-Log"]')"
check "the wiki change log is created with a line for it" bash -c 'grep -q "^# NSX Change Log" <<<"$1" && grep -q "| \[#1\](http://gitlab.test/issues/1) | !12 | @erin | @bob | @carol (for @alice), @bob | applied |" <<<"$1"' _ "$W"

echo "the next change: every merge since the last applied one is checked"
git_quiet commit --allow-empty -m "merge !13" && C="$(git rev-parse HEAD)"
git_quiet commit --allow-empty -m "merge !14" && E="$(git rev-parse HEAD)"
curl -s -X POST "http://127.0.0.1:$port/__set" -d "{\"commit_mrs\": {\"$A\": [$(mr 11 "Allow web to db" dave alice)], \"$B\": [$(mr 12 "Tag the new VMs" erin erin)], \"$C\": [$(mr 13 "Quick fix" dave dave)], \"$E\": [$(mr 14 "Open 8443" carol alice)]}, \"mr_approvals\": {\"12\": [\"bob\"]}}" >/dev/null
out="$(PIPE=101 HEAD_SHA="$E" cc open)"; rc=$?
check "a merge its author merged, with no other approval, blocks the change request" bash -c '[ "$2" = 2 ] && grep -q "!13 (Quick fix) was merged by its author dave, and no other engineer approved it" <<<"$1"' _ "$out" "$rc"
check "...even though the latest merge was reviewed" bash -c 'python3 -c "import json,sys;s=json.load(sys.stdin);i=s[\"issues\"][1];sys.exit(0 if \"nsx-blocked\" in i[\"labels\"] and \"!14\" in i[\"description\"] and \"!12\" not in i[\"description\"] else 1)" <<<"$1"' _ "$(st)"
emoji 2 alice
emoji 2 bob
check "...and no approval opens it" grep -q "REFUSED" <<<"$(PIPE=101 HEAD_SHA="$E" CHANGE_ISSUE=2 cc gate)"
git_quiet commit --allow-empty -m "direct push" && F="$(git rev-parse HEAD)"
out="$(PIPE=102 HEAD_SHA="$F" cc open)"
check "a commit that reached the branch without a merge request blocks it too" grep -q "commit ${F:0:8} reached main without a merge request" <<<"$out"
check "a newer change request supersedes an older one still open" bash -c 'python3 -c "import json,sys;s=json.load(sys.stdin);i=s[\"issues\"][1];sys.exit(0 if i[\"state\"]==\"closed\" and \"nsx-superseded\" in i[\"labels\"] and \"Superseded\" in s[\"notes\"][\"2\"][-1] else 1)" <<<"$1"' _ "$(st)"

echo "the approvals schedule"
git_quiet reset -q --hard "$B"
stubs
git_quiet commit --allow-empty -m "merge !15" && G="$(git rev-parse HEAD)"
curl -s -X POST "http://127.0.0.1:$port/__set" -d "{\"commit_mrs\": {\"$G\": [$(mr 15 "Rule for payroll" dave bob)]}, \"pipeline_jobs\": {\"103\": [{\"id\": 903, \"name\": \"approve and apply\", \"status\": \"manual\"}]}}" >/dev/null
plans change none none none
PIPE=103 HEAD_SHA="$G" cc open >/dev/null
n="$(q 'len(s["issues"])')"
check "(setup) a new change request" test "$(q 's["issues"][-1]["labels"]')" = "['nsx-change', 'nsx-awaiting-approval']"
check "the sweep leaves a change request without its approvals alone" bash -c 'grep -q "#$2: waiting (0 of 2" <<<"$1"' _ "$(HEAD_SHA="$G" cc sweep)" "$n"
emoji "$n" dave
emoji "$n" alice
check "...and the author's thumbs-up does not tip it over" bash -c 'grep -q "#$2: waiting (1 of 2" <<<"$1"' _ "$(HEAD_SHA="$G" cc sweep)" "$n"
emoji "$n" bob
out="$(HEAD_SHA="$G" cc sweep)"
check "once approved, the sweep starts that pipeline's approve job" bash -c 'grep -q "approved, apply started" <<<"$1" && python3 -c "import json,sys;s=json.load(sys.stdin);sys.exit(0 if s[\"played\"]==[903] else 1)" <<<"$2"' _ "$out" "$(st)"
check "...once only" bash -c '[ "$(python3 -c "import json,sys;print(len(json.load(sys.stdin)[\"played\"]))" <<<"$(HEAD_SHA="$1" python3 scripts/change-control.py sweep >/dev/null 2>&1; curl -s "http://127.0.0.1:$2/__state")")" = 1 ]' _ "$G" "$port"
: >"$TF_LOG"
out="$(CHANGE_ISSUE="$n" CI_PIPELINE_ID=103 CI_COMMIT_SHA="$G" FAIL_SITE=gm1 scripts/approve-apply.sh 2>&1)"; rc=$?
check "an apply that fails stops there, fails the job" bash -c '[ "$2" != 0 ] && [ "$(wc -l <"$1")" = 1 ]' _ "$TF_LOG" "$rc"
check "...and is recorded: the change request stays open, marked failed, with the error" bash -c 'python3 -c "import json,sys;s=json.load(sys.stdin);i=s[\"issues\"][-1];n=s[\"notes\"][str(i[\"iid\"])][-1];sys.exit(0 if i[\"state\"]==\"opened\" and \"nsx-apply-failed\" in i[\"labels\"] and \"Apply FAILED\" in n and \"the manager refused it\" in n else 1)" <<<"$1"' _ "$(st)"
check "...and in the change log" grep -q "| FAILED |" <<<"$(q 's["wiki"]["NSX-Change-Log"]')"
check "the token never appears in any output" bash -c '! grep -rq SECRET-BOT-TOKEN <<<"$1"' _ "$out"
check "without a token it refuses, and says what to set" grep -q "NSX_BOT_TOKEN is not set" <<<"$(env -u NSX_BOT_TOKEN python3 scripts/change-control.py sweep 2>&1)"

echo "standby approvals in the data checks"
printf 'delegations:\n  - from: alice\n    to: alice\n    until: next week\n  - from: bob\n    to: carol\n    until: 2999-01-01\n    reason: leave\n' >inventory/delegations.yaml
out="$(python3 scripts/validate-data.py 2>&1)"
check "standing in for yourself, and a date that is not one, are errors" bash -c 'grep -q "alice cannot stand in for themselves" <<<"$1" && grep -q "until must be a date" <<<"$1"' _ "$out"
check "a standby approval of more than a month is questioned" grep -q "more than a month" <<<"$out"
sed -i 's/^    tier: prod$/    tier: prod\n    domain: global/' inventory/managers.yaml
check "a Global Manager domain other than default is questioned" grep -q "gm1: domain 'global'. On a Global Manager, global objects live in domain 'default'" <<<"$(python3 scripts/validate-data.py 2>&1)"

kill "$api" 2>/dev/null
finish change-control
