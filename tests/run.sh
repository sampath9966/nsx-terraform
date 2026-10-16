#!/usr/bin/env bash
# Run the generator's tests.
#
#   tests/run.sh            offline tests: no Docker, no network, ~1 minute
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

echo "== update.sh lifecycle and concurrency"
tests/lifecycle.sh || rc=1
echo "== YAML fallback parser"
tests/yaml-fallback.sh || rc=1
echo "== gitlab-https.sh certificates and guards"
tests/https-cert.sh || rc=1

if [ "${1:-}" = "--e2e" ]; then
	echo "== end to end against a real GitLab"
	tests/e2e-gitlab.sh || rc=1
fi

[ "$rc" -eq 0 ] && echo "ALL PASSED" || echo "FAILED"
exit "$rc"
