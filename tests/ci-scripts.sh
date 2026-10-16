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
	echo "nsx-ci:1" >>"$d/local"
	printf '%s' "$label" >"$d/label.nsx-ci_1"
	exit 0 ;;
run) exit 0 ;;
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

finish ci-scripts
