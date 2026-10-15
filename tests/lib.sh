# shellcheck shell=bash
# Shared helpers for the generator's tests. Sourced, not run.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { # check "name" cmd...
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
finish() {
	printf '%s: %d passed, %d failed\n' "${1:-tests}" "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}
# A scratch directory removed on exit, and a private config dir so a test never
# reads or writes the real ~/.config/nsx-terraform.
scratch() {
	SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/nsx-test.XXXXXX")"
	export XDG_CONFIG_HOME="$SCRATCH/config"
	trap 'rm -rf "$SCRATCH"' EXIT
}
# generate [dir] [extra bootstrap args] — a tree from the working copy
generate() {
	local dir="$1"
	shift
	"$REPO/scripts/bootstrap.sh" --dir "$dir" --vcs none --ci gitlab --no-interactive "$@" >/dev/null 2>&1
}
git_quiet() { git -c user.name=test -c user.email=test@test "$@" >/dev/null 2>&1; }
