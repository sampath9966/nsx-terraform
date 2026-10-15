#!/usr/bin/env bash
# gitlab-https.sh certificate handling, no Docker needed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T"
S="$SCRATCH/ssl"
export GITLAB_HOST=172.16.26.100 GITLAB_SSL_DIR="$S"
H="$T/scripts/gitlab-https.sh"

echo "certificate"
"$H" --renew >/dev/null 2>&1
check "issues a certificate" test -s "$S/server.crt"
check "chains to the CA" openssl verify -CAfile "$S/ca.crt" "$S/server.crt"
check "IP goes in the SAN" bash -c "openssl x509 -in '$S/server.crt' -noout -text | grep -q 'IP Address:172.16.26.100'"
check "key is private (600)" test "$(stat -c %a "$S/server.key")" = 600
before="$(md5sum <"$S/server.crt")"
"$H" --renew >/dev/null 2>&1
check "second run is a no-op" test "$before" = "$(md5sum <"$S/server.crt")"
GITLAB_HOST=gitlab.lab "$H" --renew >/dev/null 2>&1
check "host change reissues, with a DNS SAN" bash -c "openssl x509 -in '$S/server.crt' -noout -text | grep -q 'DNS:gitlab.lab'"
(cd "$S" && openssl x509 -req -in <(openssl req -new -key server.key -subj /CN=gitlab.lab) -CA ca.crt -CAkey ca.key -CAcreateserial -days 5 -out server.crt 2>/dev/null)
GITLAB_HOST=gitlab.lab "$H" --renew >/dev/null 2>&1
check "under 30 days left: reissued" openssl x509 -in "$S/server.crt" -noout -checkend $((60 * 86400))
check "no half-written key/cert left" bash -c "! ls '$S' | grep -q '\\.new\$'"

echo "guards"
sed -i "s|^\(        registry\['enable'\] = false\)|\1\n        grafana['enable'] = false|" "$T/deploy/gitlab/docker-compose.yml"
out="$("$H" 2>&1)"; rc=$?
check "refuses a compose file with a grafana setting" test "$rc" -ne 0
check "…and explains the fix" grep -q "grafana" <<<"$out"

echo "concurrency"
( exec 8>"$S/.lock"; flock 8; sleep 5 ) &
holder=$!
sleep 1
rm -f "$S/server.crt"
start=$SECONDS
"$H" --renew >/dev/null 2>&1
check "renewal waits for a running certificate operation" test $((SECONDS - start)) -ge 3
check "…then completes" test -s "$S/server.crt"
wait "$holder" 2>/dev/null
finish https-cert
