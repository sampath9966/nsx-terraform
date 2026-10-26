#!/usr/bin/env bash
#
# Bring an existing generated tree up to date with this repository, showing
# exactly what will change before anything is written.
#
#   scripts/update.sh                 pull this repo, preview, ask, apply
#   scripts/update.sh --check         preview only; exit 3 if changes are pending
#   scripts/update.sh --dir PATH      the generated tree (remembered after the first run)
#   scripts/update.sh --yes           apply without asking (safe changes only)
#
# The command never changes between releases. New behaviour arrives by pulling
# this repository; this script works out what that means for your tree.
#
# For every generated file it compares three things: what the generator writes
# now, what is in your tree, and what the generator wrote last time (a hash
# recorded in .nsx-generated.sha256).
#
#   NEW        not in your tree yet                          applied
#   UPDATE     generator changed it, you did not             applied
#   LOCAL      you changed it, generator did not             kept, never touched
#   CONFLICT   both changed it, or no record of last time    kept unless
#                                                            --overwrite-unknown
#
#   RETIRED    the generator no longer writes it, and you    removed
#              did not change it
#
# Estate data (data/, inventory/, envs/) is never changed: a starter file a new
# release introduces there is created only when the tree has none. A retired
# file you changed is kept, and listed. Every file that is overwritten or
# removed is first copied to .nsx-update-backup/<timestamp>/ in your tree.
#
#   --remote NAME|URL   where to pull this repository from   (default: origin)
#   --branch NAME       branch to pull                        (default: main)
#   --no-pull           do not pull; use this repository as it is
#   --no-converge       update files only; do not run scripts/converge.sh afterwards
#   --overwrite-unknown also apply CONFLICT files (backed up first)
#   --commit            in a git tree, commit the result on a new branch
#                       update/<generator-commit>. Never pushes.
#   --summary           list files only, no diffs
#   -h, --help          this text
#
# After the files are updated it runs scripts/converge.sh in the tree, which
# brings this host to what the release expects (CI image, runner, GitLab
# container) and reports anything it cannot fix by itself. Run it again whenever
# a converge step failed: updating is idempotent.
#
# Exit status: 0 up to date or applied and healthy, 3 changes pending (--check),
# 4 files are current but the host is not healthy (--check), 1 error or the
# host could not be converged.

set -o pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
GEN_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nsx-terraform"
TARGET_FILE="$STATE_DIR/target"
BASELINE=".nsx-generated.sha256"

TARGET=""
REMOTE="origin"
BRANCH="main"
PULL=1
CHECK=0
YES=0
OVERWRITE_UNKNOWN=0
COMMIT=0
SUMMARY=0
NO_CONVERGE=0

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

usage() { sed -n '2,/^set -uo/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
	--dir | -d)
		TARGET="${2:?--dir needs a path}"
		shift
		;;
	--dir=*) TARGET="${1#*=}" ;;
	--remote)
		REMOTE="${2:?--remote needs a name or URL}"
		shift
		;;
	--branch)
		BRANCH="${2:?--branch needs a name}"
		shift
		;;
	--no-pull) PULL=0 ;;
	--no-converge) NO_CONVERGE=1 ;;
	--check | --dry-run) CHECK=1 ;;
	--yes | -y) YES=1 ;;
	--overwrite-unknown) OVERWRITE_UNKNOWN=1 ;;
	--commit) COMMIT=1 ;;
	--summary) SUMMARY=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
command -v diff >/dev/null 2>&1 || die "diff is required."

# --- 1. which tree ---------------------------------------------------------

if [ -z "$TARGET" ]; then
	TARGET="${NSX_ESTATE_DIR:-}"
	[ -z "$TARGET" ] && [ -f "$TARGET_FILE" ] && TARGET="$(cat "$TARGET_FILE")"
fi
[ -n "$TARGET" ] || die "no tree to update. Run once with --dir PATH (it is remembered), or set NSX_ESTATE_DIR.
       To create a tree in the first place: scripts/bootstrap.sh"
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || die "$TARGET does not exist."
[ -f "$TARGET/.nsx-bootstrap.conf" ] || [ -f "$TARGET/Makefile" ] ||
	die "$TARGET does not look like a generated tree (no .nsx-bootstrap.conf or Makefile)."

# --- 2. pull this repository, then run the pulled copy --------------------

# One update at a time per tree, and one pull at a time per clone. A cron job, a
# second terminal or a colleague on the same server must wait, not interleave.
lock() { # lock <file> <what>
	[ "${NSX_UPDATE_LOCKED:-}" = 1 ] && return 0 # inherited from the process we replaced
	command -v flock >/dev/null 2>&1 || return 0
	mkdir -p "$(dirname "$1")" 2>/dev/null
	exec 9>"$1" || return 0
	flock -w "${NSX_LOCK_WAIT:-120}" 9 || die "another update is already running against $2 (lock: $1). Try again in a minute."
}
# Keyed by the tree's path, kept outside the tree so it never shows up in git.
lockkey="$(printf '%s' "$TARGET" | cksum | awk '{print $1}')"
lock "$STATE_DIR/locks/$lockkey.lock" "$TARGET"

if [ "$PULL" = 1 ]; then
	if git -C "$GEN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		cur="$(git -C "$GEN_ROOT" symbolic-ref --short -q HEAD || true)"
		[ "$cur" = "$BRANCH" ] ||
			die "$GEN_ROOT is on '${cur:-a detached HEAD}', not '$BRANCH'. Pulling would merge $BRANCH into it.
       Switch with: git -C $GEN_ROOT checkout $BRANCH   (or pass --branch ${cur:-NAME})"
		say "pulling $REMOTE $BRANCH into $GEN_ROOT..."
		git -C "$GEN_ROOT" fetch -q "$REMOTE" "$BRANCH" || die "could not fetch $REMOTE $BRANCH."
		incoming="$(git -C "$GEN_ROOT" log --oneline HEAD..FETCH_HEAD 2>/dev/null)"
		if [ -n "$incoming" ]; then
			say "new in this repository:"
			printf '%s\n' "$incoming" | sed 's/^/  /'
			git -C "$GEN_ROOT" merge -q --ff-only FETCH_HEAD ||
				die "cannot fast-forward $GEN_ROOT. It has local commits or edits; resolve that first."
			# The script itself may have changed. Run the new one (fd 9, the lock,
			# is inherited and stays held, so nothing can slip in between).
			fwd=(--no-pull --dir "$TARGET")
			[ "$CHECK" = 1 ] && fwd+=(--check)
			[ "$YES" = 1 ] && fwd+=(--yes)
			[ "$OVERWRITE_UNKNOWN" = 1 ] && fwd+=(--overwrite-unknown)
			[ "$COMMIT" = 1 ] && fwd+=(--commit)
			[ "$SUMMARY" = 1 ] && fwd+=(--summary)
			[ "$NO_CONVERGE" = 1 ] && fwd+=(--no-converge)
			NSX_UPDATE_LOCKED=1 exec "$GEN_ROOT/scripts/update.sh" "${fwd[@]}"
		fi
		say "this repository is already up to date."
	else
		say "note: $GEN_ROOT is not a git clone; not pulling."
	fi
fi

GEN_REV="$(git -C "$GEN_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GEN_VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$GEN_ROOT/scripts/bootstrap.sh" 2>/dev/null | head -1)"
GEN_VERSION="${GEN_VERSION:-unknown}"
VERSION_FILE=".nsx-generator-version"
TREE_VERSION="$(tr -d '\r\n' <"$TARGET/$VERSION_FILE" 2>/dev/null || true)"

version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# The sections of CHANGELOG.md newer than this tree (just the newest, the first time).
release_notes() {
	local file="$GEN_ROOT/CHANGELOG.md" show=0 first=1 printed=0 line v
	[ -f "$file" ] || return 0
	while IFS= read -r line; do
		if [[ "$line" =~ ^##[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
			v="${BASH_REMATCH[1]}"
			if [ -z "$TREE_VERSION" ]; then
				show=$first
			elif version_gt "$v" "$TREE_VERSION"; then
				show=1
			else
				show=0
			fi
			first=0
			if [ "$show" = 1 ] && [ "$printed" = 0 ]; then
				say ""
				say "WHAT'S NEW"
				printed=1
			fi
		fi
		[ "$show" = 1 ] && printf '  %s\n' "$line"
	done <"$file"
	return 0
}

# Bring this host in line with the release. Prints its own report.
converge() {
	[ "$NO_CONVERGE" = 1 ] && return 0
	[ -x "$TARGET/scripts/converge.sh" ] || return 0
	local args=()
	[ "$CHECK" = 1 ] && args=(--check)
	say ""
	say "== host =="
	"$TARGET/scripts/converge.sh" ${args[@]+"${args[@]}"}
}
[ -x "$GEN_ROOT/scripts/bootstrap.sh" ] || die "$GEN_ROOT/scripts/bootstrap.sh is missing."

# --- 3. generate what the tree would be today, in a scratch directory ------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nsx-update.XXXXXX")" || die "cannot make a scratch directory."
trap 'rm -rf "$WORK"' EXIT
FRESH="$WORK/fresh"

# The answers given at first run decide the shape of the tree. VCS does not
# change file contents, so the scratch run uses 'none' and never touches git
# or Docker.
SAVED_CI_PLATFORM="" SAVED_BACKEND=""
# shellcheck disable=SC1091
[ -f "$TARGET/.nsx-bootstrap.conf" ] && . "$TARGET/.nsx-bootstrap.conf" 2>/dev/null
args=(--dir "$FRESH" --vcs none --no-examples --no-interactive)
[ -n "${SAVED_CI_PLATFORM:-}" ] && args+=(--ci "$SAVED_CI_PLATFORM")
[ -n "${SAVED_BACKEND:-}" ] && args+=(--backend "$SAVED_BACKEND")
"$GEN_ROOT/scripts/bootstrap.sh" "${args[@]}" >"$WORK/gen.log" 2>&1 ||
	{
		cat "$WORK/gen.log" >&2
		die "the generator failed in the scratch directory; nothing was changed."
	}

# --- 4. classify every generated file --------------------------------------

# Same rule as bootstrap.sh: estate data is yours, the generator never edits it.
is_estate_data() {
	case "$1" in
	data/schema/*.json) return 1 ;;
	data/schema/tag-scopes.yaml) return 0 ;;
	data/* | inventory/* | envs/*) return 0 ;;
	*) return 1 ;;
	esac
}
# Starter files a release adds to estate data: created when missing, never
# changed after, as everything there.
is_starter() {
	case "$1" in
	inventory/ownership.yaml | data/guardrails.yaml) return 0 ;;
	esac
	return 1
}
# Written by the scratch run, not part of the tree.
is_scratch_only() {
	case "$1" in
	.nsx-bootstrap.conf | .nsx-generated.sha256 | .nsx-generator-version | .git/*) return 0 ;;
	esac
	return 1
}

hash_of() { sha256sum "$1" | awk '{print $1}'; }
baseline_of() { [ -f "$TARGET/$BASELINE" ] && awk -v p="$1" '$2==p {print $1}' "$TARGET/$BASELINE" || true; }

NEW=() UPDATE=() LOCAL=() CONFLICT=() SAME=()
while IFS= read -r rel; do
	rel="${rel#./}"
	is_scratch_only "$rel" && continue
	f="$FRESH/$rel" t="$TARGET/$rel"
	if is_estate_data "$rel"; then
		is_starter "$rel" && [ ! -e "$t" ] && NEW+=("$rel")
		continue
	fi
	if [ ! -e "$t" ]; then
		NEW+=("$rel")
		continue
	fi
	if cmp -s "$f" "$t"; then
		SAME+=("$rel")
		continue
	fi
	base="$(baseline_of "$rel")"
	if [ -z "$base" ]; then
		CONFLICT+=("$rel")
	elif [ "$(hash_of "$t")" = "$base" ]; then
		UPDATE+=("$rel")
	elif [ "$(hash_of "$f")" = "$base" ]; then
		LOCAL+=("$rel")
	else
		CONFLICT+=("$rel")
	fi
done < <(cd "$FRESH" && find . -type f -not -path './.git/*' | LC_ALL=C sort)

# What the generator wrote last time and writes no more (a script folded into
# another, say): removed when you did not change it, listed when you did.
RETIRED=() RETIRED_KEPT=()
if [ -f "$TARGET/$BASELINE" ]; then
	while read -r base rel; do
		[ -e "$FRESH/$rel" ] || [ ! -f "$TARGET/$rel" ] || is_estate_data "$rel" && continue
		if [ "$(hash_of "$TARGET/$rel")" = "$base" ]; then
			RETIRED+=("$rel")
		else
			RETIRED_KEPT+=("$rel")
		fi
	done <"$TARGET/$BASELINE"
fi

show_diff() { diff -u --label "your tree: $1" --label "generator now: $1" "$TARGET/$1" "$FRESH/$1" | sed 's/^/    /' || true; }

say ""
say "tree        $TARGET"
say "generator   $GEN_ROOT @ $GEN_REV (release $GEN_VERSION)"
say "tree        is at release ${TREE_VERSION:-unrecorded}"
release_notes
say ""
say "  ${#NEW[@]} new   ${#UPDATE[@]} update   ${#RETIRED[@]} retired   ${#LOCAL[@]} yours, kept   ${#CONFLICT[@]} conflict   ${#SAME[@]} unchanged"
say "  (data/, inventory/ and envs/ are never changed; a starter file missing there is created)"

if [ "${#NEW[@]}" -gt 0 ]; then
	say ""
	say "NEW — will be created"
	printf '  + %s\n' "${NEW[@]}"
fi
if [ "${#UPDATE[@]}" -gt 0 ]; then
	say ""
	say "UPDATE — generator changed these, you did not; will be replaced"
	for r in "${UPDATE[@]}"; do
		say "  ~ $r"
		[ "$SUMMARY" = 1 ] || show_diff "$r"
	done
fi
if [ "${#RETIRED[@]}" -gt 0 ]; then
	say ""
	say "RETIRED — the generator no longer writes these, and you did not change them; will be removed"
	printf '  - %s\n' "${RETIRED[@]}"
fi
if [ "${#RETIRED_KEPT[@]}" -gt 0 ]; then
	say ""
	say "RETIRED, BUT YOURS — the generator no longer writes these, and you changed them; left alone."
	say "                    Remove each once nothing of yours needs it."
	printf '  = %s\n' "${RETIRED_KEPT[@]}"
fi
if [ "${#CONFLICT[@]}" -gt 0 ]; then
	say ""
	say "CONFLICT — differ from the generator, and I cannot tell the change is only the generator's."
	say "           Kept as they are unless you pass --overwrite-unknown (backed up first)."
	for r in "${CONFLICT[@]}"; do
		say "  ! $r"
		[ "$SUMMARY" = 1 ] || show_diff "$r"
	done
fi
if [ "${#LOCAL[@]}" -gt 0 ]; then
	say ""
	say "YOURS — you changed these and the generator did not; left alone"
	printf '  = %s\n' "${LOCAL[@]}"
fi

# The last thing printed when files were kept. A conflict listed in the middle of
# a long diff is easy to miss, and a kept file means part of the release does not
# take effect, so it is repeated at the end with what to do about it.
report_kept() {
	[ "$OVERWRITE_UNKNOWN" = 1 ] && return 0
	[ "${#CONFLICT[@]}" -gt 0 ] || return 0
	say ""
	say "================================================================"
	say "ATTENTION: ${#CONFLICT[@]} file(s) were NOT updated, because they differ from the generator:"
	printf '  ! %s\n' "${CONFLICT[@]}"
	say ""
	say "This release changes them, so those changes are not in effect yet."
	say "Read the diffs above. If the difference is only an earlier copy of a"
	say "generator change (for example a fix you applied by hand), take the"
	say "generator's version; the original is backed up first:"
	say "  scripts/update.sh --dir $TARGET --overwrite-unknown"
	say "If it is a change you meant to keep, keep it and port the generator's"
	say "change into it by hand."
	say "================================================================"
}

TO_APPLY=(${NEW[@]+"${NEW[@]}"} ${UPDATE[@]+"${UPDATE[@]}"})
[ "$OVERWRITE_UNKNOWN" = 1 ] && TO_APPLY+=(${CONFLICT[@]+"${CONFLICT[@]}"})

if [ "${#TO_APPLY[@]}" -eq 0 ] && [ "${#RETIRED[@]}" -eq 0 ]; then
	say ""
	if [ "${#CONFLICT[@]}" -gt 0 ]; then
		say "nothing is applied automatically. Review the CONFLICT files above."
	else
		say "files are up to date."
	fi
	converge
	crc=$?
	[ "$CHECK" = 1 ] || report_kept
	if [ "$CHECK" = 1 ]; then
		[ "${#CONFLICT[@]}" -gt 0 ] && exit 3
		[ "$crc" -ne 0 ] && exit 4
		exit 0
	fi
	# Nothing to write, so this release is adopted once the host is healthy.
	if [ "$crc" -eq 0 ] && [ "$TREE_VERSION" != "$GEN_VERSION" ]; then
		printf '%s\n' "$GEN_VERSION" >"$TARGET/$VERSION_FILE"
	fi
	exit "$crc"
fi

if [ "$CHECK" = 1 ]; then
	say ""
	say "$((${#TO_APPLY[@]} + ${#RETIRED[@]})) change(s) pending. Run scripts/update.sh to apply."
	converge >/dev/null 2>&1 || true
	exit 3
fi

# --- 5. ask, back up, apply ------------------------------------------------

if [ "$YES" != 1 ]; then
	[ -t 0 ] || die "no terminal to ask on. Review with --check, then pass --yes."
	say ""
	printf 'Apply %d change(s) to %s? [y/N] ' "$((${#TO_APPLY[@]} + ${#RETIRED[@]}))" "$TARGET"
	reply=""
	IFS= read -r reply
	case "$reply" in
	y | Y | yes) ;;
	*)
		say "nothing was changed."
		exit 0
		;;
	esac
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/.nsx-update-backup/$STAMP"

COMMIT_BRANCH=""
if [ "$COMMIT" = 1 ]; then
	git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || die "--commit needs $TARGET to be a git repository."
	[ -z "$(git -C "$TARGET" status --porcelain --untracked-files=no 2>/dev/null)" ] ||
		die "$TARGET has uncommitted changes. Commit or stash them first, so this update is its own commit."
	# Built on a temporary branch and named at the end, because the branch for
	# this release may already be here: another server can have pushed it.
	COMMIT_BRANCH="update/$GEN_REV"
	TMP_BRANCH="update/tmp-$$"
	git -C "$TARGET" checkout -q -b "$TMP_BRANCH" 2>/dev/null || die "could not create a branch in $TARGET."
fi

for r in "${TO_APPLY[@]}"; do
	if [ -e "$TARGET/$r" ]; then
		mkdir -p "$BACKUP/$(dirname "$r")"
		cp -p "$TARGET/$r" "$BACKUP/$r"
	fi
	mkdir -p "$TARGET/$(dirname "$r")"
	# Copy beside, then rename: a reader never sees half a file, and an
	# interrupted run leaves the original in place.
	cp -p "$FRESH/$r" "$TARGET/$r.nsx-new" && mv -f "$TARGET/$r.nsx-new" "$TARGET/$r" ||
		die "could not write $r. Originals are in $BACKUP; nothing else was changed after this point."
done

for r in ${RETIRED[@]+"${RETIRED[@]}"}; do
	mkdir -p "$BACKUP/$(dirname "$r")"
	cp -p "$TARGET/$r" "$BACKUP/$r" && rm -f "$TARGET/$r" ||
		die "could not remove $r. Originals are in $BACKUP; nothing else was changed after this point."
done

# Record what the generator wrote, for every file now identical to it, so the
# next update can tell its own changes from yours. A file that stayed as yours
# keeps the record it already had.
{
	for rel in ${SAME[@]+"${SAME[@]}"} ${TO_APPLY[@]+"${TO_APPLY[@]}"}; do
		printf '%s  %s\n' "$(hash_of "$FRESH/$rel")" "$rel"
	done
	for rel in ${LOCAL[@]+"${LOCAL[@]}"} ${CONFLICT[@]+"${CONFLICT[@]}"} ${RETIRED_KEPT[@]+"${RETIRED_KEPT[@]}"}; do
		cmp -s "$FRESH/$rel" "$TARGET/$rel" && continue
		b="$(baseline_of "$rel")"
		[ -n "$b" ] && printf '%s  %s\n' "$b" "$rel"
	done
} | LC_ALL=C sort -k2,2 -u >"$TARGET/$BASELINE.tmp"
mv "$TARGET/$BASELINE.tmp" "$TARGET/$BASELINE"

mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$TARGET" >"$TARGET_FILE" 2>/dev/null || true

if [ -d "$BACKUP" ]; then
	say ""
	say "originals saved in $BACKUP"
fi
say ""
say "applied $((${#TO_APPLY[@]} + ${#RETIRED[@]})) change(s)."

# Things that need a human to act, not an update to do silently.
followups=()
for r in "${TO_APPLY[@]}"; do
	case "$r" in
	deploy/gitlab/*) followups+=("deploy/gitlab changed: the host step below recreates the GitLab/runner containers if their configuration changed (data is kept).") ;;
	.gitlab-ci.yml | .github/*) followups+=("the pipeline definition changed: it takes effect on the next push; review it in a merge request.") ;;
	stacks/*/backend.tf) followups+=("a backend.tf changed: run 'terraform init' in that stack before the next plan.") ;;
	esac
done
if [ "${#followups[@]}" -gt 0 ]; then
	say ""
	say "follow-ups:"
	printf '%s\n' "${followups[@]}" | sort -u | sed 's/^/  - /'
fi

printf '%s\n' "$GEN_VERSION" >"$TARGET/$VERSION_FILE"
converge
crc=$?

if [ "$COMMIT" = 1 ]; then
	# Only the files this run wrote, never whatever else is lying around.
	for r in ${TO_APPLY[@]+"${TO_APPLY[@]}"} ${RETIRED[@]+"${RETIRED[@]}"} "$BASELINE" "$VERSION_FILE"; do
		git -C "$TARGET" add -- "$r" 2>/dev/null
	done
	# The same update on the same parent gives the same commit id on every server
	# (fixed dates and author), so two servers pushing it do not collide.
	gdate="$(git -C "$GEN_ROOT" log -1 --format=%cI 2>/dev/null || echo 2000-01-01T00:00:00Z)"
	GIT_AUTHOR_DATE="$gdate" GIT_COMMITTER_DATE="$gdate" \
		git -C "$TARGET" -c user.name="nsx-update" -c user.email="nsx-update@localhost" -c commit.gpgsign=false \
		commit -q -m "Update generated files to generator $GEN_REV" || die "the commit failed; your files are updated but uncommitted on $TMP_BRANCH."
	mine="$(git -C "$TARGET" rev-parse HEAD)"
	if git -C "$TARGET" rev-parse -q --verify "refs/heads/$COMMIT_BRANCH" >/dev/null; then
		if [ "$(git -C "$TARGET" rev-parse "refs/heads/$COMMIT_BRANCH")" = "$mine" ]; then
			# Same parent, same files, same dates: the very same commit.
			git -C "$TARGET" checkout -q "$COMMIT_BRANCH" && git -C "$TARGET" branch -q -D "$TMP_BRANCH"
		else
			COMMIT_BRANCH="update/$GEN_REV-$(date +%H%M%S)"
			git -C "$TARGET" branch -q -m "$TMP_BRANCH" "$COMMIT_BRANCH"
			say "" && say "note: update/$GEN_REV already exists here with different content; used $COMMIT_BRANCH."
		fi
	else
		git -C "$TARGET" branch -q -m "$TMP_BRANCH" "$COMMIT_BRANCH"
	fi
	say "" && say "committed on branch $COMMIT_BRANCH. Push it and open a merge request; nothing was pushed."
elif git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
	say ""
	say "review with 'git -C $TARGET diff', then commit on a branch and open a merge request."
fi

report_kept
exit "$crc"
