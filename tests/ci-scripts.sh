#!/usr/bin/env bash
# The scripts that make the pipeline work on a restricted network, tested with
# stand-in tools: no Docker, no network.
#
#   ci-terraform-validate.sh   exit 0 / 1 / 42 for the three situations it must tell apart
#   gitlab-runner.sh           the runner profile: proxy, CA, pull policy, and when it changes
#   converge.sh / ci-image.sh  say what is wrong instead of crashing when Docker is absent
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T"

# ---------------------------------------------------------------------------
echo "ci-terraform-validate.sh"
BIN="$SCRATCH/bin"
mkdir -p "$BIN"
cat >"$BIN/terraform" <<'STUB'
#!/usr/bin/env bash
# Stand-in Terraform. TF_STUB_INIT: ok | network | real | flaky
args="$*"
case "$args" in
fmt*) [ "${TF_STUB_FMT:-ok}" = ok ] && exit 0 || { echo "main.tf"; exit 3; } ;;
*" init "*)
	case "${TF_STUB_INIT:-ok}" in
	ok) echo "Terraform has been successfully initialized!"; exit 0 ;;
	network)
		echo 'Error: Failed to query available provider packages'
		echo 'Could not retrieve the list of available versions for provider vmware/nsxt: could not connect to registry.terraform.io: Failed to request discovery document: Get "https://registry.terraform.io/.well-known/terraform.json": dial tcp: lookup registry.terraform.io: no such host'
		exit 1 ;;
	denied)
		echo 'Error: Failed to query available provider packages'
		echo 'Could not retrieve the list of available versions for provider vmware/nsxt: 403 Forbidden'
		exit 1 ;;
	real)
		echo 'Error: Failed to query available provider packages'
		echo 'Could not retrieve the list of available versions for provider vmware/nsxt: no available releases match the given constraints >= 99.0.0'
		exit 1 ;;
	flaky)
		n="$(cat "$TF_STUB_COUNT" 2>/dev/null || echo 0)"
		echo $((n + 1)) >"$TF_STUB_COUNT"
		if [ "$n" -lt 1 ]; then echo 'Error: dial tcp 1.2.3.4:443: i/o timeout'; exit 1; fi
		echo "Terraform has been successfully initialized!"; exit 0 ;;
	esac ;;
*" validate "*) [ "${TF_STUB_VALIDATE:-ok}" = ok ] && { echo "Success! The configuration is valid."; exit 0; } || { echo "Error: Invalid reference"; exit 1; } ;;
esac
exit 0
STUB
chmod +x "$BIN/terraform"
run_validate() { (cd "$T" && PATH="$BIN:$PATH" NSX_INIT_RETRY_SLEEP=0 TF_STUB_COUNT="$SCRATCH/count" bash scripts/ci-terraform-validate.sh >"$SCRATCH/v.out" 2>&1); }

TF_STUB_INIT=ok run_validate
check "providers fine, code fine: exit 0" test $? -eq 0
TF_STUB_INIT=network run_validate
rc=$?
check "providers unreachable: exit 42 (a warning, not a failure)" test "$rc" -eq 42
check "...and says plainly what to do" grep -q "NSX_TF_NETWORK_MIRROR" "$SCRATCH/v.out"
check "...and says validate did not run" grep -q "did NOT run" "$SCRATCH/v.out"
TF_STUB_INIT=real run_validate
check "a real provider error is a hard failure (exit 1), not a warning" test $? -eq 1
TF_STUB_INIT=denied run_validate
check "a proxy 403 on provider download is a warning (exit 42), not a hard failure" test $? -eq 42
TF_STUB_INIT=ok TF_STUB_VALIDATE=bad run_validate
check "an invalid stack is a hard failure" test $? -eq 1
TF_STUB_INIT=ok TF_STUB_FMT=bad run_validate
check "unformatted code is a hard failure" test $? -eq 1
TF_STUB_INIT=network TF_STUB_FMT=bad run_validate
check "unformatted code beats the network warning" test $? -eq 1
rm -f "$SCRATCH/count"
TF_STUB_INIT=flaky run_validate
check "a transient network error is retried and then succeeds" test $? -eq 0

# GitLab only honours allow_failure:exit_codes when the job's own shell executes 'exit 42'
# (found by experiment on a real runner: a command that returns 42 is recorded as exit
# code 1). So the job must be written as 'cmd || exit $?', and the exit codes must match.
check "the terraform job re-exits the script's code (|| exit \$?)" grep -q 'ci-terraform-validate.sh || exit \$?' "$T/.gitlab-ci.yml"
check "...and allows exactly the code the script uses for 'providers unreachable'" bash -c 'grep -q "exit_codes: 42" "$1/.gitlab-ci.yml" && grep -q "exit 42" "$1/scripts/ci-terraform-validate.sh"' _ "$T"
python3 - "$T/.gitlab-ci.yml" <<'PYEOF' && pass "the generated .gitlab-ci.yml parses as YAML" || fail "the generated .gitlab-ci.yml parses as YAML"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
assert d["terraform"]["script"] == ["bash scripts/ci-terraform-validate.sh || exit $?"], d["terraform"]["script"]
assert d["terraform"]["allow_failure"] == {"exit_codes": 42}
assert d["default"]["image"]["entrypoint"] == [""], d["default"]["image"]
PYEOF

# The provider mirror setting becomes a Terraform CLI config.
out="$(cd "$T" && NSX_TF_NETWORK_MIRROR=https://mirror.corp/tf/ bash -c '. scripts/tf-mirror.sh; nsx_tf_mirror_setup; cat "$TF_CLI_CONFIG_FILE"')"
check "NSX_TF_NETWORK_MIRROR becomes a network_mirror block" grep -q 'network_mirror' <<<"$out"
out="$(cd "$T" && NSX_TF_FS_MIRROR=/opt/providers bash -c '. scripts/tf-mirror.sh; nsx_tf_mirror_setup; cat "$TF_CLI_CONFIG_FILE"')"
check "NSX_TF_FS_MIRROR becomes a filesystem_mirror block" grep -q 'filesystem_mirror' <<<"$out"
out="$(cd "$T" && env -u NSX_TF_NETWORK_MIRROR -u NSX_TF_FS_MIRROR -u TF_CLI_CONFIG_FILE bash -c '. scripts/tf-mirror.sh; nsx_tf_mirror_setup; echo "[${TF_CLI_CONFIG_FILE:-unset}]"')"
check "no mirror configured: Terraform is left alone" test "$out" = "[unset]"

# ---------------------------------------------------------------------------
echo "gitlab-runner.sh profile"
R="$T/scripts/gitlab-runner.sh"
clean() { env -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u no_proxy -u NSX_HTTP_PROXY -u NSX_HTTPS_PROXY -u NSX_NO_PROXY -u NSX_TEST_BLOCK_EGRESS -u GITLAB_SCHEME -u GITLAB_HOST -u GITLAB_PORT "$@"; }
# A PATH that has every tool the scripts use except docker.
NODOCKER="$SCRATCH/nodocker"
mkdir -p "$NODOCKER"
for f in /usr/bin/* /bin/* /usr/local/bin/*; do
	[ -x "$f" ] && [ "${f##*/}" != docker ] && ln -sf "$f" "$NODOCKER/${f##*/}" 2>/dev/null
done
base_path="$NODOCKER"
prof() { clean env PATH="$base_path" "$@" "$R" --print-profile; }

p1="$(prof GITLAB_HOST=gitlab.corp)"
check "defaults: docker executor, host network, the local image, pull if-not-present" bash -c 'grep -q -- "--docker-network-mode" <<<"$1" && grep -q -- "nsx-ci:1" <<<"$1" && grep -q -- "if-not-present" <<<"$1"' _ "$p1"
check "no HTTP proxy when the host has none" bash -c '! grep -q -- "HTTP_PROXY" <<<"$1"' _ "$p1"
check "the container config still defaults NO_PROXY" bash -c 'line=$(grep -E "^[[:space:]]*NO_PROXY=" <<<"$1"); printf "%s" "$line" | grep -q "10.0.0.0/8" && printf "%s" "$line" | grep -q "172.16.0.0/12" && printf "%s" "$line" | grep -q "192.168.0.0/16"' _ "$p1"
p2="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128)"
check "the host proxy is passed into jobs for internet access" grep -q "HTTPS_PROXY=http://proxy.corp:3128" <<<"$p2"
check "a single host proxy is used for HTTP as well" grep -q "HTTP_PROXY=http://proxy.corp:3128" <<<"$p2"
check "...GitLab itself is always excluded from it" bash -c 'grep -q "NO_PROXY=.*gitlab.corp" <<<"$1" && grep -q "NO_PROXY=.*127.0.0.1" <<<"$1"' _ "$p2"
check "...and every private range (RFC 1918) is excluded too" bash -c 'line=$(grep -E "^[[:space:]]*NO_PROXY=" <<<"$1"); printf "%s" "$line" | grep -q "10.0.0.0/8" && printf "%s" "$line" | grep -q "172.16.0.0/12" && printf "%s" "$line" | grep -q "192.168.0.0/16"' _ "$p2"
p2b="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128 NO_PROXY=corp.example,10.0.0.0/8)"
check "the host NO_PROXY is not copied into the container" bash -c '! grep -q corp.example <<<"$1"' _ "$p2b"
p2c="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128 NSX_NO_PROXY=extra.internal)"
check "NSX_NO_PROXY adds to the default list" bash -c 'line=$(grep -E "^[[:space:]]*NO_PROXY=" <<<"$1"); printf "%s" "$line" | grep -q "extra.internal" && printf "%s" "$line" | grep -q "192.168.0.0/16"' _ "$p2c"
check "...so the profile changed (a re-registration)" test "$(grep '^profile' <<<"$p1")" != "$(grep '^profile' <<<"$p2")"
p3="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://shell:1 NSX_HTTPS_PROXY=http://override:2)"
check "NSX_HTTPS_PROXY overrides the shell's" bash -c 'grep -q "HTTPS_PROXY=http://override:2" <<<"$1" && ! grep -q "http://shell:1" <<<"$1"' _ "$p3"
p4="$(prof GITLAB_HOST=gitlab.corp GITLAB_SCHEME=https)"
check "GitLab on HTTPS: the runner is told to trust its CA" grep -q -- "--tls-ca-file" <<<"$p4"
p5="$(prof GITLAB_HOST=gitlab.corp NSX_TEST_BLOCK_EGRESS=1)"
check "the no-egress test hook points proxies at a dead port" grep -q "127.0.0.1:9" <<<"$p5"
check "git is not told to ignore the host proxy" bash -c '! grep -F ".proxy" <<<"$1"' _ "$p1"
check "git copies the injected CA to a readable path before clone" grep -F 'nsx-gitlab-ca.pem' <<<"$p1"
check "...and sets sslCAInfo for this GitLab URL only" grep -F 'http.${_u}.sslCAInfo' <<<"$p1"
a="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128 | grep '^profile')"
b="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128 | grep '^profile')"
check "the profile is stable when nothing changed (no needless re-registration)" test "$a" = "$b"
# ci-network.env in the tree is read
printf 'NSX_HTTPS_PROXY=http://fromfile:9\n' >"$T/deploy/gitlab/ci-network.env"
p6="$(prof GITLAB_HOST=gitlab.corp)"
check "deploy/gitlab/ci-network.env is honoured" grep -q "http://fromfile:9" <<<"$p6"
rm -f "$T/deploy/gitlab/ci-network.env"
env_out="$(clean env PATH="$base_path" GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128 "$R" --print-env)"
check "--print-env gives KEY=VALUE lines for docker --env-file" grep -q "^https_proxy=http://proxy.corp:3128$" <<<"$env_out"

# Jobs must not inherit an image entrypoint. 'terraform sh' exits 1 in a couple of
# seconds and every job fails the same way.
check "every job clears the image entrypoint" grep -q 'entrypoint: \[""\]' "$T/.gitlab-ci.yml"
child="$(cd "$T" && python3 scripts/gitlab-child-pipeline.py)"
check "the child pipeline clears it too" grep -q 'entrypoint: \[""\]' <<<"$child"
# A child of a merge request pipeline is a merge request pipeline; jobs with no
# rules default to 'only: branches, tags' and are all filtered out of it.
check "the child pipeline is not filtered out of merge request pipelines" grep -qE '^workflow:' <<<"$child"

# NSX credentials from masked CI/CD variables instead of Vault.
cat >"$T/inventory/managers.yaml" <<'INV'
managers:
  hyd-gm01:
    role: gm
    host: gm.example.net
    site: hyd-gm01
    vcf_instance: v.example.net
    vault_path: secret/nsx/hyd-gm01
    tier: prod
INV
nsxcred() { (cd "$T" && env -i PATH="$PATH" "$@" scripts/with-credentials.sh hyd-gm01 -- sh -c 'echo "$NSXT_USERNAME:$NSXT_PASSWORD"' 2>&1); }
check "no credentials anywhere: says what to set" grep -q "no NSX credentials" <<<"$(nsxcred)"
check "a shared NSX_USERNAME/NSX_PASSWORD is used" test "$(nsxcred NSX_USERNAME=a NSX_PASSWORD=b)" = "a:b"
check "a per-site variable beats the shared one" test "$(nsxcred NSX_USERNAME=a NSX_PASSWORD=b NSX_HYD_GM01_USERNAME=c NSX_HYD_GM01_PASSWORD=d)" = "c:d"
check "the job's scope beats the per-site variable" test "$(nsxcred NSX_CRED_SCOPE=apply NSX_HYD_GM01_USERNAME=c NSX_HYD_GM01_PASSWORD=d NSX_HYD_GM01_APPLY_USERNAME=e NSX_HYD_GM01_APPLY_PASSWORD=f)" = "e:f"
check "a username with no password is ignored" grep -q "no NSX credentials" <<<"$(nsxcred NSX_USERNAME=a)"
check "VAULT_ADDR still selects Vault" grep -q "VAULT_TOKEN is not set" <<<"$(nsxcred VAULT_ADDR=http://x NSX_USERNAME=a NSX_PASSWORD=b)"
check "the child pipeline tells each job its credential scope" grep -q 'NSX_CRED_SCOPE: plan' <<<"$(cd "$T" && python3 scripts/gitlab-child-pipeline.py)"

# Terraform reads state from GitLab over HTTPS and must trust GitLab's own CA.
printf 'address = "https://gitlab.test/state"\n' >"$T/envs/hyd-gm01.backend.hcl"
mkdir -p "$SCRATCH/faketf"
cat >"$SCRATCH/faketf/terraform" <<'STUB'
#!/usr/bin/env bash
echo "SSL_CERT_FILE=${SSL_CERT_FILE:-unset}"
[ -n "${SSL_CERT_FILE:-}" ] && [ -r "$SSL_CERT_FILE" ] && grep -q GITLAB-CA "$SSL_CERT_FILE" && echo "bundle-has-gitlab-ca"
exit 0
STUB
chmod +x "$SCRATCH/faketf/terraform"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'GITLAB-CA' '-----END CERTIFICATE-----' >"$SCRATCH/gl.crt"
tfenv() { (cd "$T" && env -u SSL_CERT_FILE PATH="$SCRATCH/faketf:$PATH" "$@" scripts/tf.sh init global-security hyd-gm01 2>/dev/null); }
check "terraform is given a bundle holding the GitLab CA" grep -q "bundle-has-gitlab-ca" <<<"$(tfenv CI_SERVER_TLS_CA_FILE="$SCRATCH/gl.crt")"
check "a SSL_CERT_FILE already set is left alone" grep -q "SSL_CERT_FILE=/already/set" <<<"$(tfenv CI_SERVER_TLS_CA_FILE="$SCRATCH/gl.crt" SSL_CERT_FILE=/already/set)"
check "without the runner's CA nothing is set" grep -q "SSL_CERT_FILE=unset" <<<"$(tfenv X=1)"

# The NSX managers' CA, given as a File variable, goes into the same bundle.
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'NSX-CA' '-----END CERTIFICATE-----' >"$SCRATCH/nsx.crt"
cat >"$SCRATCH/faketf/terraform" <<'STUB'
#!/usr/bin/env bash
echo "SSL_CERT_FILE=${SSL_CERT_FILE:-unset}"
echo "TF_HTTP_USERNAME=${TF_HTTP_USERNAME:-unset} TF_HTTP_PASSWORD=${TF_HTTP_PASSWORD:-unset}"
for want in GITLAB-CA NSX-CA SITE-CA; do
	[ -n "${SSL_CERT_FILE:-}" ] && [ -r "$SSL_CERT_FILE" ] && grep -q "$want" "$SSL_CERT_FILE" && echo "has-$want"
done
exit 0
STUB
chmod +x "$SCRATCH/faketf/terraform"
out="$(tfenv CI_SERVER_TLS_CA_FILE="$SCRATCH/gl.crt" NSX_CA_FILE="$SCRATCH/nsx.crt")"
check "NSX_CA_FILE and the GitLab CA are both in the bundle" bash -c 'grep -q has-GITLAB-CA <<<"$1" && grep -q has-NSX-CA <<<"$1"' _ "$out"
check "NSX_CA_FILE alone builds a bundle" grep -q has-NSX-CA <<<"$(tfenv NSX_CA_FILE="$SCRATCH/nsx.crt")"
check "an NSX_CA_FILE that does not exist is an error, not silently ignored" bash -c '! (cd "$1" && env -u SSL_CERT_FILE NSX_CA_FILE=/no/such/file PATH="$2:$PATH" scripts/tf.sh init global-security hyd-gm01) >/dev/null 2>&1' _ "$T" "$SCRATCH/faketf"
echo "not a certificate" >"$SCRATCH/junk.crt"
check "an NSX_CA_FILE with no certificate in it is an error" bash -c '! (cd "$1" && env -u SSL_CERT_FILE NSX_CA_FILE="$3" PATH="$2:$PATH" scripts/tf.sh init global-security hyd-gm01) >/dev/null 2>&1' _ "$T" "$SCRATCH/faketf" "$SCRATCH/junk.crt"
# A manager with its own CA: NSX_CA_FILE_<SITE> wins, so its run trusts only that CA.
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'SITE-CA' '-----END CERTIFICATE-----' >"$SCRATCH/site.crt"
out="$(tfenv NSX_CA_FILE="$SCRATCH/nsx.crt" NSX_CA_FILE_HYD_GM01="$SCRATCH/site.crt")"
check "a manager's own NSX_CA_FILE_<SITE> is used instead of the shared one" bash -c 'grep -q has-SITE-CA <<<"$1" && ! grep -q has-NSX-CA <<<"$1"' _ "$out"
check "NSX_CA_FILE_<SITE> alone builds a bundle" grep -q has-SITE-CA <<<"$(tfenv NSX_CA_FILE_HYD_GM01="$SCRATCH/site.crt")"
out="$(tfenv NSX_CA_FILE="$SCRATCH/nsx.crt" NSX_CA_FILE_LAB_1A="$SCRATCH/site.crt")"
check "another manager's CA file is not used; the shared one is" bash -c 'grep -q has-NSX-CA <<<"$1" && ! grep -q has-SITE-CA <<<"$1"' _ "$out"
check "a missing per-manager CA file is an error that names the variable" grep -q "NSX_CA_FILE_HYD_GM01 is set to" <<<"$(cd "$T" && env -u SSL_CERT_FILE NSX_CA_FILE_HYD_GM01=/no/such PATH="$SCRATCH/faketf:$PATH" scripts/tf.sh init global-security hyd-gm01 2>&1)"
# GitLab-managed state is reached with the job's own token.
out="$(tfenv CI_JOB_TOKEN=job-token-123)"
check "in a GitLab job the state backend gets the job token" grep -q "TF_HTTP_USERNAME=gitlab-ci-token TF_HTTP_PASSWORD=job-token-123" <<<"$out"
check "explicit state credentials are left alone" grep -q "TF_HTTP_USERNAME=me TF_HTTP_PASSWORD=mine" <<<"$(tfenv CI_JOB_TOKEN=job-token-123 TF_HTTP_USERNAME=me TF_HTTP_PASSWORD=mine)"
check "outside CI nothing is set" grep -q "TF_HTTP_USERNAME=unset TF_HTTP_PASSWORD=unset" <<<"$(env -u CI_JOB_TOKEN -u TF_HTTP_USERNAME -u TF_HTTP_PASSWORD bash -c "$(declare -f tfenv); T=$T SCRATCH=$SCRATCH tfenv X=1")"
check "the token is never printed by tf.sh" bash -c '! (cd "$1" && env -u SSL_CERT_FILE CI_JOB_TOKEN=job-token-123 PATH="/nonexistent:$PATH" scripts/tf.sh init global-security hyd-gm01 2>&1) | grep -q job-token-123' _ "$T"
check "a preset SSL_CERT_FILE wins and says NSX_CA_FILE was not added" grep -q "NSX_CA_FILE is not added" <<<"$(cd "$T" && env PATH="$SCRATCH/faketf:$PATH" SSL_CERT_FILE=/already/set NSX_CA_FILE="$SCRATCH/nsx.crt" scripts/tf.sh init global-security hyd-gm01 2>&1)"
leftover="$(ls "${TMPDIR:-/tmp}"/nsx-ca.* 2>/dev/null | wc -l)"
check "the temporary CA bundle is removed after the run" test "$leftover" -eq 0

# Credential selection: edge cases that matter in production.
wc2() { (cd "$T" && env -i PATH="$PATH" "$@" scripts/with-credentials.sh hyd-gm01 -- sh -c 'printf "%s|%s" "$NSXT_USERNAME" "$NSXT_PASSWORD"' 2>&1); }
check "explicit --from env with nothing set gives the real message, not a bash error" bash -c 'out="$(cd "$1" && env -i PATH="$PATH" scripts/with-credentials.sh hyd-gm01 --from env -- true 2>&1)"; grep -q "no NSX credentials" <<<"$out" && ! grep -q "invalid variable name" <<<"$out"' _ "$T"
check "the error names the scope and the variables it looked for" bash -c 'grep -q "scope: plan" <<<"$1" && grep -q "NSX_HYD_GM01_PLAN_USERNAME" <<<"$1" && grep -q "NSX_PLAN_USERNAME" <<<"$1"' _ "$(wc2 NSX_CRED_SCOPE=plan)"
check "a blank username and password are not credentials" grep -q "no NSX credentials" <<<"$(wc2 NSX_USERNAME=' ' NSX_PASSWORD=' ')"
check "passwords with quotes, dollars, backslashes and spaces arrive intact" test "$(wc2 NSX_USERNAME='dom\svc user' NSX_PASSWORD='p a"s$s\n=#x')" = 'dom\svc user|p a"s$s\n=#x'
check "a plan job cannot use the apply credential" grep -q "no NSX credentials" <<<"$(wc2 NSX_CRED_SCOPE=plan NSX_APPLY_USERNAME=w NSX_APPLY_PASSWORD=w)"
check "an apply job cannot use the plan credential" grep -q "no NSX credentials" <<<"$(wc2 NSX_CRED_SCOPE=apply NSX_PLAN_USERNAME=r NSX_PLAN_PASSWORD=r)"
check "a password never appears in an error message" bash -c '! grep -q SECRETVALUE <<<"$1"' _ "$(wc2 NSX_USERNAME=u NSX_PASSWORD=SECRETVALUE VAULT_ADDR=http://x)"
np() { (cd "$T" && env -i PATH="$PATH" NSX_USERNAME=u NSX_PASSWORD=p "$@" scripts/with-credentials.sh hyd-gm01 -- sh -c 'printf "%s|%s" "$NO_PROXY" "$no_proxy"' 2>&1); }
check "the manager is added to NO_PROXY, keeping what was there" test "$(np NO_PROXY=10.0.0.0/8)" = "10.0.0.0/8,gm.example.net|10.0.0.0/8,gm.example.net"
check "...from no_proxy when only that is set" test "$(np no_proxy=localhost)" = "localhost,gm.example.net|localhost,gm.example.net"
check "...not twice" test "$(np NO_PROXY=gm.example.net)" = "gm.example.net|gm.example.net"
check "...and SDDC Manager too" test "$(np SDDC_MANAGER_HOST=sddc.example.net:443)" = "gm.example.net,sddc.example.net|gm.example.net,sddc.example.net"
check "NSX_MANAGER_VIA_PROXY=1 leaves NO_PROXY alone" test "$(np NSX_MANAGER_VIA_PROXY=1 NO_PROXY=x)" = "x|"
sed -i 's/host: gm.example.net/host: gm.example.net:8443/' "$T/inventory/managers.yaml"
check "a port in the inventory host is not part of the NO_PROXY entry" test "$(np)" = "gm.example.net|gm.example.net"
sed -i 's/host: gm.example.net:8443/host: gm.example.net/' "$T/inventory/managers.yaml"
check "the wrapped command's exit status is preserved" bash -c '(cd "$1" && env -i PATH="$PATH" NSX_USERNAME=u NSX_PASSWORD=p scripts/with-credentials.sh hyd-gm01 -- sh -c "exit 7") >/dev/null 2>&1; [ $? -eq 7 ]' _ "$T"

# Git is given only the runner's tls-ca-file. That file has to carry the host
# trust store as well, or a TLS-inspecting proxy fails every clone.
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'GITLAB-CA' '-----END CERTIFICATE-----' >"$SCRATCH/ca.crt"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'HOST-CA' '-----END CERTIFICATE-----' >"$SCRATCH/host-ca.crt"
clean env GITLAB_SCHEME=https GITLAB_SSL_DIR="$SCRATCH" NSX_HOST_CA_BUNDLE="$SCRATCH/host-ca.crt" "$R" --bundle-ca "$SCRATCH/bundle.pem"
check "the CA bundle contains the GitLab CA and the host trust store" bash -c 'grep -q GITLAB-CA "$1" && grep -q HOST-CA "$1"' _ "$SCRATCH/bundle.pem"

# ---------------------------------------------------------------------------
echo "no Docker on the host"
out="$(env PATH="$base_path" "$T/scripts/ci-image.sh" 2>&1)"
rc=$?
check "ci-image.sh says Docker is missing and exits non-zero" bash -c '[ "$2" -ne 0 ] && grep -qi "docker is not installed" <<<"$1"' _ "$out" "$rc"
out="$(env PATH="$base_path" "$T/scripts/converge.sh" 2>&1)"
rc=$?
check "converge.sh reports it and exits 1, without a stack trace" bash -c '[ "$2" -eq 1 ] && grep -q "Docker is not installed" <<<"$1" && ! grep -qi "unbound\|syntax error" <<<"$1"' _ "$out" "$rc"
out="$(env PATH="$base_path" "$R" 2>&1)"
check "gitlab-runner.sh says Docker is missing" grep -qi "docker is not installed" <<<"$out"

# ---------------------------------------------------------------------------
echo "ci-image.sh with a stand-in Docker"
FD="$SCRATCH/fakedocker"
mkdir -p "$FD/bin"
cat >"$FD/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stand-in Docker. State lives in $FAKE_DIR. Knobs: FAKE_PULL=ok|429  FAKE_BUILD_NEEDS_REGISTRY=1
d="$FAKE_DIR"
echo "$*" >>"$d/calls"
has() { grep -qxF "$1" "$d/local" 2>/dev/null; }
case "$1" in
info) exit 0 ;;
image)
	img="${*: -1}"
	has "$img" || exit 1
	case "$*" in *Labels*) cat "$d/label.$(echo "$img" | tr '/:' '__')" 2>/dev/null ;; esac
	exit 0 ;;
pull)
	img="${*: -1}"
	if [ "${FAKE_PULL:-ok}" = 429 ]; then
		echo "toomanyrequests: You have reached your pull rate limit." >&2
		exit 1
	fi
	echo "$img" >>"$d/local"
	exit 0 ;;
build)
	# every FROM must be local, or (without --pull=false) reachable
	for b in hashicorp/terraform:1.9.8 python:3.12-bookworm; do
		if ! has "$b"; then
			echo "failed to resolve source metadata for $b: 429 Too Many Requests" >&2
			exit 1
		fi
	done
	label="$(printf '%s\n' "$@" | sed -n 's/^nsx.dockerfile=//p')"
	if ls "${*: -1}"/plugins/registry.terraform.io/vmware/nsxt/*.zip >/dev/null 2>&1; then : >"$d/baked"; else rm -f "$d/baked"; fi
	echo "nsx-ci:1" >>"$d/local"
	printf '%s' "$label" >"$d/label.nsx-ci_1"
	exit 0 ;;
run)
	case "$*" in
	*"providers mirror"*)
		[ "${FAKE_MIRROR:-ok}" = fail ] && { echo "Error: failed to query provider: request canceled (Client.Timeout exceeded)" >&2; exit 1; }
		ctx="$(printf '%s\n' "$@" | sed -n 's/:\/ctx$//p')"
		mkdir -p "$ctx/plugins/registry.terraform.io/vmware/nsxt"
		: >"$ctx/plugins/registry.terraform.io/vmware/nsxt/terraform-provider-nsxt_3.12.1_linux_amd64.zip"
		printf '%s\n' "$@" >"$d/mirror-args"
		exit 0 ;;
	*/usr/local/share/terraform/plugins*) [ -f "$d/baked" ] ;;
	*) exit 0 ;;
	esac
	exit ;;
esac
exit 0
STUB
chmod +x "$FD/bin/docker"
fd_run() { # fd_run [ENV=VAL...] -> runs ci-image.sh against the stand-in
	: >"$FD/calls"
	env FAKE_DIR="$FD" NSX_PULL_RETRY_SLEEP=0 PATH="$FD/bin:$PATH" "$@" "$T/scripts/ci-image.sh" 2>&1
}

: >"$FD/local"
rm -f "$FD"/label.*
out="$(fd_run)"
rc=$?
check "bases missing, registry fine: pulls them, builds, exits 0" test "$rc" -eq 0
check "...both base images were pulled first" bash -c 'grep -q "pull -q hashicorp/terraform:1.9.8" "$1/calls" && grep -q "pull -q python:3.12-bookworm" "$1/calls"' _ "$FD"
check "...and the build did not ask the registry (--pull=false)" grep -q -- "--pull=false" "$FD/calls"

out="$(fd_run)"
check "an image that is current is left alone (no second build)" bash -c '! grep -q "^build" "$1/calls" && grep -q "is current" <<<"$2"' _ "$FD" "$out"

printf '\n# changed\n' >>"$T/deploy/ci-image/Dockerfile"
out="$(fd_run)"
check "a changed Dockerfile triggers a rebuild" bash -c 'grep -q "^build" "$1/calls" && grep -q "out of date" <<<"$2"' _ "$FD" "$out"

# Registry rate-limited, but the base images are already on the host: still builds.
: >"$FD/local"
printf 'hashicorp/terraform:1.9.8\npython:3.12-bookworm\n' >"$FD/local"
rm -f "$FD"/label.*
out="$(fd_run FAKE_PULL=429)"
rc=$?
check "registry rate-limited but bases cached: builds from them, exits 0" test "$rc" -eq 0
check "...without pulling anything" bash -c '! grep -q "^pull" "$1/calls"' _ "$FD"

# Registry rate-limited and nothing cached: fails, and says why in plain words.
: >"$FD/local"
rm -f "$FD"/label.*
out="$(fd_run FAKE_PULL=429)"
rc=$?
check "rate-limited with nothing cached: exits non-zero" test "$rc" -ne 0
check "...names the rate limit and what to do" bash -c 'grep -qi "rate-limiting" <<<"$1" && grep -q "docker login" <<<"$1"' _ "$out"
check "...after retrying the pull" bash -c '[ "$(grep -c "^pull" "$1/calls")" -ge 3 ]' _ "$FD"

# Mirror mode: planned, never applied, from any pipeline.
cp "$T/inventory/managers.yaml" "$SCRATCH/managers.keep"
cat >"$T/inventory/managers.yaml" <<'INV'
managers:
  hyd-gm01:
    role: gm
    host: gm.example.net
    site: hyd-gm01
    vcf_instance: v.example.net
    vault_path: secret/nsx/hyd-gm01
    tier: prod
    mode: mirror
  hyd-np01:
    role: lm
    host: np.example.net
    site: hyd-np01
    vcf_instance: v.example.net
    vault_path: secret/nsx/hyd-np01
    tier: nonprod
INV
main_child="$(cd "$T" && CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py)"
job() { python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin).get(sys.argv[1])))' "$1"; }
check "a manager in mode: mirror is planned on the default branch" grep -q '^"plan global-security @ hyd-gm01":' <<<"$main_child"
check "...but has no apply job" bash -c '! grep -q "^\"apply global-security @ hyd-gm01\":" <<<"$1"' _ "$main_child"
sync="$(job "sync-state global-security @ hyd-gm01" <<<"$main_child")"
check "...it has an automatic sync-state job instead, with the read-only credential" python3 -c "import json,sys;j=json.loads(sys.argv[1]);v=j['variables'];sys.exit(0 if v['NSX_CRED_SCOPE']=='plan' and v['VAULT_TOKEN']=='\$VAULT_PLAN_TOKEN' and 'when' not in j and j['allow_failure'] is True and j['needs'][0]['job']=='plan global-security @ hyd-gm01' else 1)" "$sync"
check "...its plan, a warning not a failure, never holds up the others" python3 -c "import json,sys;sys.exit(0 if json.loads(sys.argv[1])['allow_failure'] is True else 1)" "$(job "plan global-security @ hyd-gm01" <<<"$main_child")"
check "...while a managed manager still has its manual apply jobs, and strict plans" python3 -c "import json,sys;a=json.loads(sys.argv[1]);p=json.loads(sys.argv[2]);sys.exit(0 if a['when']=='manual' and a['variables']['NSX_CRED_SCOPE']=='apply' and p['allow_failure'] is False else 1)" "$(job "apply local-security @ hyd-np01" <<<"$main_child")" "$(job "plan local-security @ hyd-np01" <<<"$main_child")"
check "a waiting manual apply does not hold the pipeline 'blocked'" python3 -c "import json,sys;a=json.loads(sys.argv[1]);sys.exit(0 if a['when']=='manual' and a['allow_failure'] is True else 1)" "$(job "apply local-security @ hyd-np01" <<<"$main_child")"
auto_child="$(cd "$T" && NSX_APPLY_MODE=auto CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py)"
check "...while an automatic apply that fails still fails the pipeline" python3 -c "import json,sys;a=json.loads(sys.argv[1]);sys.exit(0 if a['when']=='on_success' and a['allow_failure'] is False else 1)" "$(job "apply local-security @ hyd-np01" <<<"$auto_child")"
own_mr="$(cd "$T" && CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=mirror/hyd-gm01 python3 scripts/gitlab-child-pipeline.py)"
check "in its own mirror merge request, a mirror manager's plan must pass" python3 -c "import json,sys;sys.exit(0 if json.loads(sys.argv[1])['allow_failure'] is False else 1)" "$(job "plan global-security @ hyd-gm01" <<<"$own_mr")"
check "...and no merge request pipeline has sync-state or apply jobs" bash -c '! grep -qE "^\"(sync-state|apply) " <<<"$1"' _ "$own_mr"
var_child="$(cd "$T" && NSX_MODE_HYD_NP01=mirror NSX_MODE_HYD_GM01=managed CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py)"
# GitLab rejects a script line YAML reads as anything but a string (": " in an
# unquoted line makes it a mapping). Python's parser accepts that silently, so
# check every job's script, in every mode, for strings only.
check "every generated script line is a string GitLab accepts, in every apply mode" bash -c 'cd "$1" && for mode in manual auto; do NSX_APPLY_MODE=$mode CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
bad = [(n, l) for n, j in d.items() if isinstance(j, dict) for l in j.get(\"script\", []) if not isinstance(l, str)]
sys.exit(1 if bad else 0)" || exit 1; done' _ "$T"
check "a variable named in the wrong case stops the pipeline, naming the right name" bash -c 'cd "$1" && ! out="$(env NSX_MODE_hyd_np01=mirror CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py 2>&1)" && grep -q "NSX_MODE_hyd_np01  ->  rename it to NSX_MODE_HYD_NP01" <<<"$out"' _ "$T"
check "...and so does any NSX job that talks to the manager" bash -c 'cd "$1" && out="$(env -i PATH="$PATH" NSX_USERNAME=u NSX_PASSWORD=p NSX_CA_FILE_hyd_gm01=/x scripts/with-credentials.sh hyd-gm01 -- true 2>&1)"; grep -q "NSX_CA_FILE_hyd_gm01->NSX_CA_FILE_HYD_GM01" <<<"$out"' _ "$T"
check "NSX_MODE_<SITE> overrides the inventory, both ways, without a commit" bash -c 'grep -q "^\"sync-state local-security @ hyd-np01\":" <<<"$1" && ! grep -q "^\"apply local-security @ hyd-np01\":" <<<"$1" && grep -q "^\"apply global-security @ hyd-gm01\":" <<<"$1"' _ "$var_child"
check "...and an unknown value stops the pipeline, naming the variable" bash -c 'cd "$1" && ! out="$(NSX_MODE_HYD_NP01=Mirror python3 scripts/gitlab-child-pipeline.py 2>&1)" && grep -q "NSX_MODE_HYD_NP01 must be one of: managed, mirror" <<<"$out"' _ "$T"
check "the inventory schema accepts mode" bash -c 'cd "$1" && ! python3 scripts/validate-data.py 2>&1 | grep -q "\.mode:"' _ "$T"
check "...and rejects anything but managed or mirror" bash -c 'cd "$1" && sed -i "s/mode: mirror/mode: mirrored/" inventory/managers.yaml && python3 scripts/validate-data.py 2>&1 | grep -q "hyd-gm01.mode: .mirrored. is not one of managed, mirror"; rc=$?; sed -i "s/mode: mirrored/mode: mirror/" inventory/managers.yaml; exit $rc' _ "$T"
appr="$(cd "$T" && NSX_APPLY_MODE=approval CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py)"
check "change control: no apply job per manager, one change request and one approve job" bash -c '! grep -q "^\"apply " <<<"$1" && grep -q "^\"change request\":" <<<"$1" && grep -q "^\"approve and apply\":" <<<"$1"' _ "$appr"
check "...the change request takes every managed plan (not the mirror's), with full history, and hands on its issue" python3 -c "import json,sys;j=json.loads(sys.argv[1]);n=[x['job'] for x in j['needs']];sys.exit(0 if n==['plan local-security @ hyd-np01','plan local-tags @ hyd-np01','plan local-network @ hyd-np01','plan platform @ hyd-np01'] and j['variables']['GIT_DEPTH']=='0' and j['artifacts']['reports']['dotenv']=='change.env' and j['stage']=='review' else 1)" "$(job "change request" <<<"$appr")"
check "...the approve job: manual, non-blocking, one at a time, write credential, every plan and the issue" python3 -c "import json,sys;j=json.loads(sys.argv[1]);n=[x['job'] for x in j['needs']];v=j['variables'];sys.exit(0 if j['when']=='manual' and j['allow_failure'] is True and j['resource_group']=='nsx-apply' and v['NSX_CRED_SCOPE']=='apply' and v['APPROVE']=='yes' and n[0]=='change request' and len(n)==5 and j['script']==['scripts/approve-apply.sh'] else 1)" "$(job "approve and apply" <<<"$appr")"
check "...a mirror manager keeps its automatic read-only sync" grep -q '^"sync-state global-security @ hyd-gm01":' <<<"$appr"
check "...every plan keeps a copy under its manager's name" python3 -c "import json,sys;j=json.loads(sys.argv[1]);sys.exit(0 if 'plans/hyd-np01/local-security/' in j['artifacts']['paths'] and any('plans/\$SITE/\$STACK' in l for l in j['script']) else 1)" "$(job "plan local-security @ hyd-np01" <<<"$appr")"
appr_mr="$(cd "$T" && NSX_APPLY_MODE=approval python3 scripts/gitlab-child-pipeline.py)"
check "...and a merge request pipeline has neither" bash -c '! grep -qE "^\"(change request|approve and apply)\":" <<<"$1"' _ "$appr_mr"
check "an unknown NSX_APPLY_MODE names the three" bash -c 'cd "$1" && ! out="$(NSX_APPLY_MODE=approve python3 scripts/gitlab-child-pipeline.py 2>&1)" && grep -q "manual., .auto. or .approval." <<<"$out"' _ "$T"
check "the GitHub apply matrix leaves mirror managers out" bash -c 'cd "$1" && m="$(python3 scripts/ci-matrix.py --format github --managed-only)" && ! grep -q hyd-gm01 <<<"$m" && grep -q hyd-np01 <<<"$m"' _ "$T"
check "...and is exactly the empty form the apply job tests for when all are mirrors" bash -c 'cd "$1" && sed -i "/^    tier: nonprod$/a\    mode: mirror" inventory/managers.yaml && [ "$(python3 scripts/ci-matrix.py --format github --managed-only)" = "{\"include\": []}" ] && grep -q "apply_matrix != '"'"'{\"include\": \[\]}'"'"'" .github/workflows/apply.yml 2>/dev/null || [ ! -f .github/workflows/apply.yml ]' _ "$T"
cp "$SCRATCH/managers.keep" "$T/inventory/managers.yaml"
ci="$T/.gitlab-ci.yml"
check "the mirror job runs only from a schedule or Run pipeline, on the default branch" python3 - "$ci" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
rules = d["mirror"]["rules"]
ok = len(rules) == 1 and "$MIRROR_SITE" in rules[0]["if"] and '"schedule"' in rules[0]["if"] and "$CI_DEFAULT_BRANCH" in rules[0]["if"]
ok = ok and d["mirror"]["variables"]["NSX_CRED_SCOPE"] == "plan" and d["mirror"]["interruptible"] is False
sys.exit(0 if ok else 1)
PY
check "the approvals sweep runs only from a schedule or Run pipeline, on the default branch, with full history" python3 - "$ci" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["approvals"]
ok = len(j["rules"]) == 1 and "$APPROVAL_SWEEP" in j["rules"][0]["if"] and '"schedule"' in j["rules"][0]["if"]
ok = ok and j["variables"]["GIT_DEPTH"] == "0" and j["script"] == ["python3 scripts/change-control.py sweep"]
for job in ("data", "terraform", "matrix", "managers"):
    ok = ok and any("$APPROVAL_SWEEP" in r.get("if", "") and r.get("when") == "never" for r in d[job]["rules"])
sys.exit(0 if ok else 1)
PY
check "...and a mirror pipeline runs nothing else" python3 - "$ci" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in ("data", "terraform", "matrix", "managers"):
    first = d[job]["rules"]
    if not any("$MIRROR_SITE" in r.get("if", "") and r.get("when") == "never" for r in first):
        sys.exit(1)
PY

# The NSX provider in the image.
: >"$FD/local"
rm -f "$FD"/label.*
out="$(fd_run)"
rc=$?
check "the provider is fetched and built into the image" bash -c '[ "$2" -eq 0 ] && grep -q "vmware/nsxt 3.12.1 inside" <<<"$1"' _ "$out" "$rc"
check "...for this platform, as the invoking user, through the job network settings" bash -c 'grep -qx -- "-platform=linux_amd64" "$1/mirror-args" && grep -qx -- "--user" "$1/mirror-args" && grep -qx -- "--env-file" "$1/mirror-args"' _ "$FD"
check "...and the fetched packages are not committed" grep -qx "deploy/ci-image/plugins/" "$T/.gitignore"
out="$(fd_run)"
check "an image with the provider inside is current" bash -c '! grep -q "^build" "$1/calls" && grep -q "is current" <<<"$2"' _ "$FD" "$out"
sed -i 's/version = "3.12.1"/version = "3.12.2"/' "$T/deploy/ci-image/providers.tf"
out="$(fd_run)"
check "a new provider pin rebuilds the image" grep -q "out of date" <<<"$out"
sed -i 's/version = "3.12.2"/version = "3.12.1"/' "$T/deploy/ci-image/providers.tf"
rm -f "$FD"/label.*
out="$(fd_run FAKE_MIRROR=fail)"
rc=$?
check "a failed fetch still builds a working image, and exits 2" test "$rc" -eq 2
check "...saying so, with the reason and the fix" bash -c 'grep -q "WITHOUT the NSX provider" <<<"$1" && grep -q "Client.Timeout" <<<"$1" && grep -q "NSX_HTTPS_PROXY" <<<"$1"' _ "$out"
out="$(fd_run)"
check "...and the next run tries again and bakes it" bash -c 'grep -q "trying again" <<<"$1" && grep -q "inside)" <<<"$1"' _ "$out"
check "the pinned provider satisfies the stacks' constraint (~> 3.9)" bash -c 'v="$(sed -n "s/.*version = \"\(.*\)\"/\1/p" "$1/deploy/ci-image/providers.tf")"; grep -rq "\"~> 3.9\"" "$1/stacks" && [ "${v%%.*}" = 3 ] && [ "$(echo "$v" | cut -d. -f2)" -ge 9 ]' _ "$T"

finish ci-scripts
