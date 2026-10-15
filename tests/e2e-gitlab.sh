#!/usr/bin/env bash
# End to end against a REAL GitLab container: the path a user takes.
#   plain HTTP via scripts/gitlab-up.sh  ->  scripts/gitlab-https.sh  ->  renewal
# Needs Docker, ~6 GB free RAM and 15-25 minutes. Uses fixed container names and
# ports 8929/8443/2224, so it refuses to run where a GitLab already exists.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || {
	echo "e2e: Docker is not available; skipped."
	exit 0
}
if docker inspect nsx-gitlab >/dev/null 2>&1 || docker inspect nsx-gitlab-runner >/dev/null 2>&1; then
	echo "e2e: a container named nsx-gitlab already exists here. Refusing to touch it." >&2
	exit 2
fi
for port in 8929 8443; do
	if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"; then
		echo "e2e: port $port is in use. Refusing to run." >&2
		exit 2
	fi
done

scratch
T="$SCRATCH/estate"
export GITLAB_HOST=127.0.0.1 NSX_CRON_FILE="$SCRATCH/cron-nsx-gitlab-cert"
SSL="$SCRATCH/ssl"          # exported only for step 2: GitLab must not create it as root first
cleanup() {
	echo "--- cleaning up"
	(cd "$T/deploy/gitlab" 2>/dev/null && docker compose down -v >/dev/null 2>&1)
	docker rm -f nsx-gitlab nsx-gitlab-runner >/dev/null 2>&1
	rm -rf "$SCRATCH"
}
trap cleanup EXIT

generate "$T"
git_quiet -C "$T" init -b main
git_quiet -C "$T" add -A
git_quiet -C "$T" commit -m init

echo "step 1: start GitLab over HTTP with scripts/gitlab-up.sh (first boot is slow)"
env -u GITLAB_SSL_DIR GITLAB_WAIT_MINUTES=25 "$T/scripts/gitlab-up.sh" >"$SCRATCH/up.log" 2>&1
check "gitlab-up.sh succeeds" test $? -eq 0
tail -12 "$SCRATCH/up.log" | sed 's/^/    /'
check "answers over plain HTTP on 8929" curl -sf -o /dev/null --max-time 20 http://127.0.0.1:8929/users/sign_in
check "gitlab-up.sh registered a runner" docker exec nsx-gitlab-runner grep -q '\[\[runners\]\]' /etc/gitlab-runner/config.toml
projects_before="$(docker exec nsx-gitlab gitlab-rails runner 'puts Project.count' 2>/dev/null | tail -1)"
check "a project exists before the switch" test "${projects_before:-0}" -ge 1

echo "step 2: switch to HTTPS on 8443"
GITLAB_SSL_DIR="$SSL" "$T/scripts/gitlab-https.sh" >"$SCRATCH/https.log" 2>&1
rc=$?
check "gitlab-https.sh succeeds" test "$rc" -eq 0
[ "$rc" -eq 0 ] || tail -40 "$SCRATCH/https.log" | sed 's/^/    /'
export GITLAB_SSL_DIR="$SSL"
CA="$SSL/ca.crt"
check "answers over HTTPS on 8443, trusting only our CA" curl -sf -o /dev/null --max-time 20 --cacert "$CA" https://127.0.0.1:8443/users/sign_in
check "is NOT trusted without the CA" bash -c "! curl -sf -o /dev/null --max-time 20 https://127.0.0.1:8443/users/sign_in"
check "certificate carries the IP in its SAN" bash -c "echo | openssl s_client -connect 127.0.0.1:8443 -CAfile '$CA' 2>/dev/null | openssl x509 -noout -text | grep -q 'IP Address:127.0.0.1'"
check "old HTTP port no longer answers" bash -c "! curl -sf -o /dev/null --max-time 10 http://127.0.0.1:8929/users/sign_in"
projects_after="$(docker exec nsx-gitlab gitlab-rails runner 'puts Project.count' 2>/dev/null | tail -1)"
check "data survived the restart (same project count)" test "$projects_after" = "$projects_before"
check "renewal job installed (or its line printed)" bash -c "test -f '$NSX_CRON_FILE' || grep -q 'renew' '$SCRATCH/https.log'"

echo "step 3: the runner follows the switch"
check "runner config points at https" docker exec nsx-gitlab-runner grep -q 'https://127.0.0.1:8443' /etc/gitlab-runner/config.toml
check "runner config trusts the CA" docker exec nsx-gitlab-runner grep -q tls-ca-file /etc/gitlab-runner/config.toml
v="$(docker exec nsx-gitlab-runner gitlab-runner verify 2>&1)"
check "runner can reach GitLab over HTTPS (verify)" grep -qi "is valid\|is alive" <<<"$v"
[ -n "$v" ] && printf '%s\n' "$v" | tail -3 | sed 's/^/    /'

echo "step 4: git over HTTPS with the CA"
tok="nsxe2e$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
docker exec nsx-gitlab gitlab-rails runner "u=User.find_by_username('root'); t=u.personal_access_tokens.create!(scopes:['api','write_repository'],name:'e2e',expires_at:7.days.from_now); t.set_token('$tok'); t.save!" >/dev/null 2>&1
check "git ls-remote works over HTTPS" env GIT_SSL_CAINFO="$CA" git ls-remote "https://root:$tok@127.0.0.1:8443/root/nsx-terraform.git"

echo "step 5: renewal reloads nginx without a restart"
served() { echo | openssl s_client -connect 127.0.0.1:8443 -CAfile "$CA" 2>/dev/null | openssl x509 -noout -fingerprint -sha256; }
# nginx reloads asynchronously (a few seconds): wait for the served certificate to differ from $1.
served_after_change() {
	local was="$1" now
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		now="$(served)"
		[ -n "$now" ] && [ "$now" != "$was" ] && break
		sleep 3
	done
	printf '%s' "$now"
}
before="$(served)"
started="$(docker inspect -f '{{.State.StartedAt}}' nsx-gitlab)"
( cd "$GITLAB_SSL_DIR" && openssl x509 -req -in <(openssl req -new -key server.key -subj /CN=127.0.0.1) \
	-CA ca.crt -CAkey ca.key -CAcreateserial -days 5 \
	-extfile <(printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n') -out server.crt 2>/dev/null )
docker exec nsx-gitlab gitlab-ctl hup nginx >/dev/null 2>&1
short="$(served_after_change "$before")"
check "(setup) nginx now serves the short-lived certificate" test "$short" != "$before"
"$T/scripts/gitlab-https.sh" --renew >/dev/null 2>&1
after="$(served_after_change "$short")"
check "--renew replaced the certificate that nginx serves" test "$after" != "$short"
check "…which is valid for more than 60 days" bash -c "echo | openssl s_client -connect 127.0.0.1:8443 -CAfile '$CA' 2>/dev/null | openssl x509 -noout -checkend $((60 * 86400))"
check "…without restarting the container" test "$(docker inspect -f '{{.State.StartedAt}}' nsx-gitlab)" = "$started"

echo "step 6: running it again is harmless"
"$T/scripts/gitlab-https.sh" >"$SCRATCH/https2.log" 2>&1
check "second gitlab-https.sh succeeds" test $? -eq 0
check "still answers over HTTPS" curl -sf -o /dev/null --max-time 20 --cacert "$CA" https://127.0.0.1:8443/users/sign_in

finish e2e-gitlab
