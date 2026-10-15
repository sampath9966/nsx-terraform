#!/usr/bin/env bash
# update.sh against scratch trees: classification, safety, repeatability and
# what happens when two servers (or a server and cron) act at once.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch

# A copy of the generator we can pretend has a new release.
GEN="$SCRATCH/gen"
git clone -q "$REPO" "$GEN" && cp "$REPO"/scripts/*.sh "$GEN/scripts/"
git -C "$GEN" -c user.name=t -c user.email=t@t commit -qam "wip" 2>/dev/null || true
UP="$GEN/scripts/update.sh"
A="$SCRATCH/estate"
"$GEN/scripts/bootstrap.sh" --dir "$A" --vcs none --ci gitlab --no-interactive >/dev/null 2>&1
git_quiet -C "$A" init -b main && git_quiet -C "$A" add -A && git_quiet -C "$A" commit -m init

echo "lifecycle"
check "baseline record written by bootstrap" test "$(wc -l <"$A/.nsx-generated.sha256")" -gt 50
check "baseline excludes estate data" bash -c "! grep -q ' data/groups\| inventory/' '$A/.nsx-generated.sha256'"
"$UP" --no-pull --dir "$A" --check >/dev/null 2>&1
check "fresh tree, same generator: up to date (exit 0)" test $? -eq 0

# Local edits plus a simulated release.
echo "# mine" >>"$A/README.md"
echo "extra: 1" >>"$A/modules/group/main.tf"
echo "name: real" >>"$A/inventory/managers.yaml"
python3 - "$GEN" <<'PY'
import sys
p = sys.argv[1] + '/scripts/bootstrap.sh'
s = open(p).read()
s = s.replace("Not a production GitLab. No backups", "Not a production GitLab (v2). No backups", 1)
s = s.replace("# Terraform working directories and state.", "# Terraform working directories and state (v2).", 1)
s = s.replace("# The single registry of every NSX manager", "# The single registry of every NSX manager (v2)", 1)
i = s.index("write_file modules/group/main.tf")
j = s.index("\n", s.index("\n", i) + 1)
s = s[:j] + "\n# generator v2 note" + s[j:]
open(p, 'w').write(s)
PY
out="$("$UP" --no-pull --dir "$A" --check --summary 2>&1)"; rc=$?
check "release pending: exit 3" test "$rc" -eq 3
check "generator-only change is an UPDATE" grep -q "~ .gitignore" <<<"$out"
check "your edit is left alone (YOURS)" grep -q "= README.md" <<<"$out"
check "both changed is a CONFLICT" grep -q "! modules/group/main.tf" <<<"$out"
check "estate data is never listed" bash -c "! grep -q 'inventory/managers' <<<\"\$1\"" _ "$out"
git_quiet -C "$A" add -A && git_quiet -C "$A" commit -m "local edits"

echo "unrelated file" >"$A/scratch-notes.txt"        # untracked, must not be swept into the commit
"$UP" --no-pull --dir "$A" --yes --commit --summary >/dev/null 2>&1
check "--commit puts the update on a branch" test "$(git -C "$A" branch --show-current)" = "update/$(git -C "$GEN" rev-parse --short HEAD)"
check "unrelated untracked files are not committed" bash -c "! git -C '$A' show --stat HEAD | grep -q scratch-notes"
check "README (yours) untouched" test "$(tail -1 "$A/README.md")" = "# mine"
check "conflict file untouched" test "$(tail -1 "$A/modules/group/main.tf")" = "extra: 1"
check "estate data untouched" test "$(tail -1 "$A/inventory/managers.yaml")" = "name: real"
check "overwritten files were backed up" test -n "$(find "$A/.nsx-update-backup" -name .gitignore)"
check "backup dir is not committed" bash -c "! git -C '$A' show --stat HEAD | grep -q nsx-update-backup"
check "no half-written files left behind" bash -c "! find '$A' -name '*.nsx-new' | grep -q ."

# Same update on a second server must produce the same commit.
B="$SCRATCH/estate-b"
git clone -q "$A" "$B" && git -C "$B" checkout -q main 2>/dev/null
git -C "$B" reset -q --hard "$(git -C "$A" rev-parse main)"
"$UP" --no-pull --dir "$B" --yes --commit --summary >/dev/null 2>&1
check "two servers make the identical update commit" test "$(git -C "$A" rev-parse HEAD)" = "$(git -C "$B" rev-parse HEAD)"
check "…and reuse the branch they already have" test "$(git -C "$B" branch --show-current)" = "$(git -C "$A" branch --show-current)"

git_quiet -C "$A" checkout main
"$UP" --no-pull --dir "$A" --check --summary >/dev/null 2>&1
check "after applying, only the conflict remains (exit 3)" test $? -eq 3
"$UP" --no-pull --dir "$A" --yes --overwrite-unknown --summary >/dev/null 2>&1
"$UP" --no-pull --dir "$A" --check >/dev/null 2>&1
check "after --overwrite-unknown: up to date" test $? -eq 0

# Concurrency: hold the lock, a second run must refuse rather than interleave.
echo "concurrency"
(
	lockkey="$(printf '%s' "$A" | cksum | awk '{print $1}')"
	mkdir -p "$XDG_CONFIG_HOME/nsx-terraform/locks"
	exec 9>"$XDG_CONFIG_HOME/nsx-terraform/locks/$lockkey.lock"
	flock 9
	sleep 6
) &
holder=$!
sleep 1
start=$SECONDS
NSX_LOCK_WAIT=2 timeout 5 "$UP" --no-pull --dir "$A" --check >/dev/null 2>&1
rc=$?
check "second update waits for the lock (does not run alongside)" test "$rc" -ne 0 -o $((SECONDS - start)) -ge 4
wait "$holder" 2>/dev/null
"$UP" --no-pull --dir "$A" --check >/dev/null 2>&1
check "lock released afterwards" test $? -eq 0

# Pulling: refuses to merge into a different branch.
echo "pull safety"
git -C "$GEN" checkout -q -b feature
out="$("$UP" --dir "$A" --check 2>&1)"; rc=$?
check "refuses to pull while the clone is on another branch" test "$rc" -ne 0
check "…and says why" grep -q "not 'main'" <<<"$out"

finish lifecycle
