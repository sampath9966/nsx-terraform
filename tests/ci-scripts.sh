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
TF_STUB_INIT=ok TF_STUB_VALIDATE=bad run_validate
check "an invalid stack is a hard failure" test $? -eq 1
TF_STUB_INIT=ok TF_STUB_FMT=bad run_validate
check "unformatted code is a hard failure" test $? -eq 1
TF_STUB_INIT=network TF_STUB_FMT=bad run_validate
check "unformatted code beats the network warning" test $? -eq 1
rm -f "$SCRATCH/count"
TF_STUB_INIT=flaky run_validate
check "a transient network error is retried and then succeeds" test $? -eq 0

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
check "defaults: no proxy flags" bash -c '! grep -q -- "HTTP_PROXY" <<<"$1"' _ "$p1"
p2="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://proxy.corp:3128)"
check "a shell proxy is passed into jobs" grep -q "HTTPS_PROXY=http://proxy.corp:3128" <<<"$p2"
check "...GitLab itself is always excluded from it" bash -c 'grep -q "NO_PROXY=.*gitlab.corp" <<<"$1" && grep -q "NO_PROXY=.*127.0.0.1" <<<"$1"' _ "$p2"
check "...so the profile changed (a re-registration)" test "$(grep '^profile' <<<"$p1")" != "$(grep '^profile' <<<"$p2")"
p3="$(prof GITLAB_HOST=gitlab.corp HTTPS_PROXY=http://shell:1 NSX_HTTPS_PROXY=http://override:2)"
check "NSX_HTTPS_PROXY overrides the shell's" bash -c 'grep -q "HTTPS_PROXY=http://override:2" <<<"$1" && ! grep -q "http://shell:1" <<<"$1"' _ "$p3"
p4="$(prof GITLAB_HOST=gitlab.corp GITLAB_SCHEME=https)"
check "GitLab on HTTPS: the runner is told to trust its CA" grep -q -- "--tls-ca-file" <<<"$p4"
p5="$(prof GITLAB_HOST=gitlab.corp NSX_TEST_BLOCK_EGRESS=1)"
check "the no-egress test hook points proxies at a dead port" grep -q "127.0.0.1:9" <<<"$p5"
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

finish ci-scripts
