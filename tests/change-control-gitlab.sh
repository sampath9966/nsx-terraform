#!/usr/bin/env bash
# Change control against a REAL GitLab: the API calls of scripts/change-control.py
# (merge requests of a commit, approvals, members, issues, award emoji, wiki,
# pipeline jobs, job play) checked on GitLab Community Edition itself, not a
# stand-in.
#
#   tests/change-control-gitlab.sh <gitlab-url> <root-password> [container]
#
# Needs a running GitLab (docker exec into its container for tokens; default
# container name nsx-gitlab). Called by tests/e2e-gitlab.sh, or by hand against
# a throwaway GitLab. It creates users and a project; never point it at a
# GitLab that matters.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
URL="${1:?gitlab url}"
PW="${2:?root password}"
CT="${3:-nsx-gitlab}"
API="$URL/api/v4"
CA_ARGS=()
[ -n "${GITLAB_CA:-}" ] && CA_ARGS=(--cacert "$GITLAB_CA")

# Users and their tokens, in one Rails call (each call takes a while).
tag="cc$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
docker exec "$CT" gitlab-rails runner "
root = User.find_by_username('root')
t = root.personal_access_tokens.create!(scopes: ['api', 'write_repository'], name: '$tag', expires_at: 7.days.from_now); t.set_token('${tag}root'); t.save!
%w[alice bob carol dave].each do |n|
  u = User.find_by_username('${tag}' + n) || User.new(username: '${tag}' + n, email: '${tag}' + n + '@example.test', name: n, password: '$PW', password_confirmation: '$PW', skip_confirmation: true).tap { |x| x.assign_personal_namespace(Organizations::Organization.default_organization) rescue nil; x.save! }
  pt = u.personal_access_tokens.create!(scopes: ['api'], name: '$tag', expires_at: 7.days.from_now); pt.set_token('${tag}' + n); pt.save!
end
" >/dev/null 2>&1
as() { local who="$1"; shift; curl -s --max-time 60 ${CA_ARGS[@]+"${CA_ARGS[@]}"} -H "PRIVATE-TOKEN: ${tag}$who" "$@"; }
j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
check "(setup) users and tokens on the real GitLab" bash -c '[ "$(curl -s ${3:+--cacert "$3"} -H "PRIVATE-TOKEN: ${1}alice" "$2/user" | python3 -c "import json,sys;print(json.load(sys.stdin).get(\"username\"))")" = "${1}alice" ]' _ "$tag" "$API" "${GITLAB_CA:-}"

# A project with a generated tree, and the four as members.
pid="$(as root -X POST "$API/projects" -d "name=$tag" -d "initialize_with_readme=false" | j 'd["id"]')"
uid() { as root "$API/users?username=${tag}$1" | j 'd[0]["id"]'; }
as root -X POST "$API/projects/$pid/members" -d "user_id=$(uid alice)" -d access_level=40 >/dev/null
as root -X POST "$API/projects/$pid/members" -d "user_id=$(uid bob)" -d access_level=40 >/dev/null
as root -X POST "$API/projects/$pid/members" -d "user_id=$(uid dave)" -d access_level=40 >/dev/null
as root -X POST "$API/projects/$pid/members" -d "user_id=$(uid carol)" -d access_level=30 >/dev/null
bot="$(as root -X POST "$API/projects/$pid/access_tokens" -H "Content-Type: application/json" \
	-d "{\"name\": \"nsx-bot\", \"scopes\": [\"api\"], \"access_level\": 40, \"expires_at\": \"$(date -u -d '+7 days' +%F)\"}" | j 'd["token"]')"
check "(setup) a project access token, role Maintainer" test -n "$bot"

T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1
printf 'managers:\n  lon1:\n    role: lm\n    host: lon1.example.net\n    site: lon1\n    vcf_instance: v\n    vault_path: s\n    tier: prod\n    stacks: [local-security]\n' >inventory/managers.yaml
# A pipeline that only waits: one manual job named as the real one.
printf 'approve and apply:\n  script: [echo]\n  when: manual\n' >.gitlab-ci.yml
git init -q -b main && git_quiet add -A && git_quiet commit -m base
remote="${URL/:\/\//://root:${tag}root@}/root/$tag.git"
git_quiet ${GITLAB_CA:+-c http.sslCAInfo="$GITLAB_CA"} push -q "$remote" main
check "(setup) the tree is on the real GitLab" bash -c '[ "$(curl -s ${3:+--cacert "$3"} -H "PRIVATE-TOKEN: ${1}root" "$2/projects/$4/repository/branches/main" | python3 -c "import json,sys;print(json.load(sys.stdin).get(\"name\"))")" = main ]' _ "$tag" "$API" "${GITLAB_CA:-}" "$pid"

change() { # change <author> <branch> <title>: a merge request with one commit; prints its iid
	as "$1" -X POST "$API/projects/$pid/repository/commits" -H "Content-Type: application/json" \
		-d "{\"branch\": \"$2\", \"start_branch\": \"main\", \"commit_message\": \"$3\", \"actions\": [{\"action\": \"create\", \"file_path\": \"notes/$2.txt\", \"content\": \"$3\"}]}" >/dev/null
	as "$1" -X POST "$API/projects/$pid/merge_requests" -d "source_branch=$2" -d target_branch=main -d "title=$3" | j 'd["iid"]'
}
merge() { # merge <who> <iid>: prints the commit that landed on main
	local sha=""
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		sha="$(as "$1" -X PUT "$API/projects/$pid/merge_requests/$2/merge" | j 'd.get("merge_commit_sha") or ""')"
		[ -n "$sha" ] && break
		sleep 3 # GitLab checks mergeability in the background
	done
	echo "$sha"
}

# A change by dave, approved and merged by alice.
mr1="$(change dave f1 "Allow web to db")"
as alice -X POST "$API/projects/$pid/merge_requests/$mr1/approve" >/dev/null
sha1="$(merge alice "$mr1")"
check "(setup) a reviewed merge request merged on the real GitLab" test -n "$sha1"
git_quiet ${GITLAB_CA:+-c http.sslCAInfo="$GITLAB_CA"} fetch -q "$remote" main && git_quiet reset -q --hard FETCH_HEAD
# Its pipeline holds the manual job.
pipe=""
for _ in $(seq 1 20); do
	pipe="$(as root "$API/projects/$pid/pipelines?sha=$sha1" | j 'd[0]["id"] if d else ""')"
	[ -n "$pipe" ] && break
	sleep 3
done
check "(setup) the merge made a pipeline with a manual job" test -n "$pipe"

export CI_API_V4_URL="$API" CI_PROJECT_ID="$pid" NSX_BOT_TOKEN="$bot" CI_DEFAULT_BRANCH=main \
	CI_PIPELINE_URL="$URL/root/$tag/-/pipelines/$pipe" CI_JOB_URL="$URL/root/$tag/-/jobs/1" CI_SERVER_TLS_CA_FILE="${GITLAB_CA:-}"
printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n' >plan-local-security-lon1.txt
cc() { CI_PIPELINE_ID="$pipe" CI_COMMIT_SHA="${HEAD_SHA:-$sha1}" python3 scripts/change-control.py "$@" 2>&1; }

echo "change control on the real GitLab API"
out="$(cc open)"
issue="$(sed -n 's/^CHANGE_ISSUE=//p' change.env)"
check "the change request is raised on the real GitLab" test -n "$issue"
D="$(as root "$API/projects/$pid/issues/$issue" | j 'd["description"]')"
check "...naming the merge request, its author and the reviewer found through the real API" grep -q "| Allow web to db | @${tag}dave | @${tag}alice |" <<<"$D"
as dave -X POST "$API/projects/$pid/issues/$issue/award_emoji" -d name=thumbsup >/dev/null
as carol -X POST "$API/projects/$pid/issues/$issue/award_emoji" -d name=thumbsup >/dev/null
as bob -X POST "$API/projects/$pid/issues/$issue/award_emoji" -d name=thumbsup >/dev/null
out="$(CHANGE_ISSUE="$issue" cc gate)"; rc=$?
check "real award emoji and roles: the author and a Developer are not counted, a Maintainer is" bash -c '[ "$2" = 2 ] && grep -q "not counted  @${3}dave: an author" <<<"$1" && grep -q "not counted  @${3}carol: not a Maintainer" <<<"$1" && grep -q "counted      @${3}bob (Maintainer)" <<<"$1"' _ "$out" "$rc" "$tag"
printf 'delegations:\n  - from: %salice\n    to: %scarol\n    until: 2999-01-01\n    reason: test\n' "$tag" "$tag" >inventory/delegations.yaml
out="$(CHANGE_ISSUE="$issue" cc gate)"; rc=$?
check "with alice's standby approval, carol counts: approved" bash -c '[ "$2" = 0 ] && grep -q "standing in for ${3}alice" <<<"$1"' _ "$out" "$rc" "$tag"
printf '== lon1/local-security\nApply complete! Resources: 1 added, 0 changed, 0 destroyed.\n' >"$SCRATCH/apply.log"
check "the result is recorded" grep -q "recorded on #$issue" <<<"$(cc record --result ok --log "$SCRATCH/apply.log")"
check "...the real issue is closed, labelled applied" bash -c '[ "$(curl -s ${3:+--cacert "$3"} -H "PRIVATE-TOKEN: ${1}root" "$2" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"], \"nsx-applied\" in d[\"labels\"])")" = "closed True" ]' _ "$tag" "$API/projects/$pid/issues/$issue" "${GITLAB_CA:-}"
check "...and the real wiki has the change log line" bash -c 'curl -s ${3:+--cacert "$3"} -H "PRIVATE-TOKEN: ${1}root" "$2" | python3 -c "import json,sys;c=json.load(sys.stdin)[\"content\"];sys.exit(0 if \"| applied |\" in c and \"@${1}dave\" in c else 1)"' _ "$tag" "$API/projects/$pid/wikis/NSX-Change-Log" "${GITLAB_CA:-}"

# The sweep starts the real manual job of an approved change.
mr3="$(change dave f3 "Open 8443")"
sha3="$(merge bob "$mr3")"
git_quiet ${GITLAB_CA:+-c http.sslCAInfo="$GITLAB_CA"} fetch -q "$remote" main && git_quiet reset -q --hard FETCH_HEAD
pipe3=""
for _ in $(seq 1 20); do
	pipe3="$(as root "$API/projects/$pid/pipelines?sha=$sha3" | j 'd[0]["id"] if d else ""')"
	[ -n "$pipe3" ] && break
	sleep 3
done
out="$(CI_PIPELINE_ID="$pipe3" CI_COMMIT_SHA="$sha3" python3 scripts/change-control.py open 2>&1)"
issue3="$(sed -n 's/^CHANGE_ISSUE=//p' change.env)"
check "(setup) the next reviewed change gets its change request" test -n "$issue3"
as alice -X POST "$API/projects/$pid/issues/$issue3/award_emoji" -d name=thumbsup >/dev/null
as bob -X POST "$API/projects/$pid/issues/$issue3/award_emoji" -d name=thumbsup >/dev/null
out="$(HEAD_SHA="$sha3" cc sweep)"
check "the sweep finds the approved change and starts its manual job" grep -q "#$issue3: approved, apply started" <<<"$out"
job_status="$(as root "$API/projects/$pid/pipelines/$pipe3/jobs" | j '[x["status"] for x in d if x["name"]=="approve and apply"][0]')"
check "...the real job left 'manual'" test "$job_status" != manual

# A change dave merges himself, with no approval.
mr2="$(change dave f2 "Quick fix")"
sha2="$(merge dave "$mr2")"
git_quiet ${GITLAB_CA:+-c http.sslCAInfo="$GITLAB_CA"} fetch -q "$remote" main && git_quiet reset -q --hard FETCH_HEAD
out="$(HEAD_SHA="$sha2" cc open)"; rc=$?
check "a self-merged change is blocked, found through the real API" bash -c '[ "$2" = 2 ] && grep -q "was merged by its author ${3}dave, and no other engineer approved it" <<<"$1"' _ "$out" "$rc" "$tag"

finish change-control-gitlab
