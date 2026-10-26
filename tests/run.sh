#!/usr/bin/env bash
# Run the generator's tests.
#
#   tests/run.sh            offline tests: no Docker, no network, ~1 minute
#   tests/run.sh --provider also adopt into a mock NSX with the real nsxt provider (a few minutes)
#   tests/run.sh --e2e      also boot a real GitLab in Docker (15-25 minutes)
#
# Run it before every merge. The offline set is what CI runs on every push; the
# end-to-end set is what proves a change works on a real GitLab, which is where
# a bad setting (like a removed Grafana option) shows up.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0

echo "== syntax"
for f in scripts/*.sh tests/*.sh; do bash -n "$f" || rc=1; done
if command -v shellcheck >/dev/null 2>&1; then
	echo "== shellcheck"
	shellcheck -S warning scripts/update.sh tests/*.sh || rc=1
else
	echo "== shellcheck: not installed, skipped"
fi

echo "== generated tree selftest"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
scripts/bootstrap.sh --dir "$t" --vcs none --no-interactive >/dev/null 2>&1 || rc=1
(cd "$t" && scripts/selftest.sh --quick 2>&1 | grep -E "^selftest:|FAIL") || true
(cd "$t" && scripts/selftest.sh --quick >/dev/null 2>&1) || rc=1

if command -v shellcheck >/dev/null 2>&1; then
	echo "== shellcheck on the generated scripts"
	# Every generated shell script, so a new one is checked without anyone adding it
	# here. bootstrap.sh is the generator's own copy, checked as the generator.
	generated=()
	for f in "$t"/scripts/*.sh; do
		[ "${f##*/}" = bootstrap.sh ] || generated+=("$f")
	done
	shellcheck -S warning "${generated[@]}" || rc=1
fi

echo "== update.sh lifecycle and concurrency"
tests/lifecycle.sh || rc=1
echo "== YAML fallback parser"
tests/yaml-fallback.sh || rc=1
echo "== CI scripts (provider downloads, runner profile, no Docker)"
tests/ci-scripts.sh || rc=1
echo "== gitlab-https.sh certificates and guards"
tests/https-cert.sh || rc=1
echo "== brownfield adoption: importer, plan guard, hand-back, per-manager safety"
tests/brownfield.sh || rc=1
echo "== change control: approvals, standby approvals, change requests, change log"
tests/change-control.sh || rc=1
echo "== scheduled rules: the schedule, the time follower, expiry, converting time windows"
tests/schedule.sh || rc=1
echo "== change watch: NSX compared with data/ for an API call"
tests/watch.sh || rc=1
echo "== governance: guardrails, no silent reverts, plans in firewall terms"
tests/govern.sh || rc=1

# CI parity: a CI image without PyYAML reads YAML with Terraform's yamldecode,
# or, with no terraform either, with the built-in reader. The suites that read
# data run again each way, unless this run already forces one.
if [ -z "${NSX_YAML_FALLBACK:-}" ]; then
	if command -v terraform >/dev/null 2>&1; then
		echo "== again, reading YAML as a CI image without PyYAML does (Terraform's yamldecode)"
		NSX_YAML_FALLBACK=1 tests/brownfield.sh || rc=1
		NSX_YAML_FALLBACK=1 tests/change-control.sh || rc=1
		NSX_YAML_FALLBACK=1 tests/schedule.sh || rc=1
		NSX_YAML_FALLBACK=1 tests/watch.sh || rc=1
		NSX_YAML_FALLBACK=1 tests/govern.sh || rc=1
	fi
	echo "== again, reading YAML with neither PyYAML nor terraform (the built-in reader)"
	NSX_YAML_FALLBACK=1 NSX_YAML_NO_TERRAFORM=1 tests/brownfield.sh || rc=1
	NSX_YAML_FALLBACK=1 NSX_YAML_NO_TERRAFORM=1 tests/schedule.sh || rc=1
	NSX_YAML_FALLBACK=1 NSX_YAML_NO_TERRAFORM=1 tests/watch.sh || rc=1
	NSX_YAML_FALLBACK=1 NSX_YAML_NO_TERRAFORM=1 tests/govern.sh || rc=1
fi

if [ "${1:-}" = "--provider" ]; then
	echo "== brownfield adoption with the real NSX provider (needs Terraform and registry access)"
	tests/brownfield-provider.sh || rc=1
fi

if [ "${1:-}" = "--e2e" ]; then
	echo "== end to end against a real GitLab"
	tests/e2e-gitlab.sh || rc=1
fi

[ "$rc" -eq 0 ] && echo "ALL PASSED" || echo "FAILED"
exit "$rc"
