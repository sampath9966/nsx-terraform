#!/usr/bin/env bash
#
# bootstrap.sh — scaffold the NSX/VCF Terraform repository described in docs/ARCHITECTURE.md.
#
# The script is self-contained: every file it writes is embedded here. It has no
# dependency on the repository it came from, on the network, or on any tool
# beyond bash, coreutils and (for the generated validator) python3. Run it in an
# empty directory, in an existing repository, or anywhere else — it scaffolds
# relative to the target directory, never to a hardcoded path.
#
#   ./scripts/bootstrap.sh                 # scaffold into the current directory
#   ./scripts/bootstrap.sh --dir ~/work/x  # scaffold into another directory
#   ./scripts/bootstrap.sh --dry-run       # show what would happen, write nothing
#   ./scripts/bootstrap.sh --force         # overwrite files that already differ
#
# It is idempotent: an unchanged file is left alone, an existing file that
# differs is kept and reported unless --force is given. Nothing is ever deleted.

set -euo pipefail

VERSION="1.5.1"

ROOT="$PWD"
FORCE=0
FORCE_DATA=0
DRY_RUN=0
QUIET=0
WITH_EXAMPLES=1
WITH_GIT=0
BACKEND=local

# Overwriting takes a flag AND this phrase, typed in full. See confirm_overwrite.
CONFIRM_PHRASE="wipe everything & start fresh"
CONFIRM_ARG="${BOOTSTRAP_CONFIRM:-}"
CONFIRMED=0

INTERACTIVE=0
NO_INTERACTIVE=0

# Where the files live and how changes get reviewed. Chosen at first run, and
# changeable later with scripts/enable-gitops.sh — the pipeline files are always
# generated, so this only drives what happens after generation.
VCS=ask          # ask | none | git | github | gitlab | gitlab-docker
GIT_REMOTE=""
GIT_BRANCH=main

# Which pipeline definitions get written. GitLab is the default because it is
# the only one this script can set up end to end — repository, runner, variables
# and gate — rather than leaving files for somebody to wire up.
CI_PLATFORM=gitlab   # gitlab | github | both | none
GITLAB_URL_ARG=""
GITLAB_TOKEN_ARG="${GITLAB_TOKEN:-}"
GITLAB_PROJECT_ARG=""
CI_EXPLICIT=0        # set when --ci was given, so a VCS choice does not override it

created=0
updated=0
unchanged=0
skipped=0
protected=0
EXECUTABLES=""

usage() {
	cat <<'USAGE'
bootstrap.sh — scaffold the NSX/VCF Terraform repository layout.

Usage: bootstrap.sh                 # interactive menu
       bootstrap.sh [options]       # scripted; any flag suppresses the menu

Run it with no arguments and it asks: basic deployment (best practices assumed,
three questions), advanced (every option), or update an existing tree. The menu
prints the equivalent command line before it does anything, so one pass through
it teaches the flags below. Any flag on the command line means a script is
driving, so the menu stays out of the way.

Options:
      --vcs KIND      Where these files live and how changes are reviewed.
                      GitLab is the default: it is the only host this script can
                      set up end to end rather than leaving files to wire up.

                        gitlab          an existing GitLab. Full pipeline.
                                        Pass --git-remote URL.       [default]
                        gitlab-docker   stand up GitLab CE and a runner in
                                        Docker, create the repository, push,
                                        register the runner, and print the
                                        initial root password.
                        github          GitHub. Workflows are written; you set
                                        the secrets and protect the apply
                                        environments.
                        git             another git host. Both sets of CI files
                                        are written and their location printed.
                        none            local files only. No versioning, no
                                        pipeline — plan and apply by hand.

                      Changeable later with scripts/enable-gitops.sh, which
                      writes whatever pipeline is missing.
      --ci PLATFORM   Which pipeline definitions to write: gitlab, github, both
                      or none. Follows --vcs unless given explicitly.
      --gitlab-url URL
      --gitlab-project GROUP/NAME
      --gitlab-token TOKEN
                      Give all three and the run creates the project on that
                      GitLab, pushes, sets the CI/CD variables, protects the
                      default branch and creates the apply environments. Without
                      them the pipeline is still written and the remote still
                      attached — nothing is created. The token needs the 'api'
                      scope; it is used in memory and never written to disk.
                      Also read from GITLAB_TOKEN.
      --git-remote URL
                      Remote to attach as 'origin'.
      --git-branch NAME
                      Default branch name (default: main).
  -i, --interactive   Force the menu even when other flags are given.
      --no-interactive
                      Never show the menu; use defaults and the flags given.
  -d, --dir PATH      Target directory (default: current working directory).
                      Created if it does not exist.
  -f, --force         Overwrite existing REGENERATED files whose content
                      differs — modules, stacks, scripts, CI, schemas, docs.
                      Never touches estate data. This is the flag to use when
                      picking up a newer version of the scaffold.
      --force-data    Also overwrite estate data: data/groups, data/policies,
                      data/services, data/network, data/platform,
                      data/schema/tag-scopes.yaml, inventory/ and envs/.
                      Refuses outright for any file recorded in
                      data/.import-manifest.json — imported estate is never
                      overwritten by this script. Implies --force.
      --confirm TEXT  Supply the overwrite confirmation phrase non-interactively,
                      for a pipeline. Must match exactly; also read from
                      BOOTSTRAP_CONFIRM. Without a terminal and without this,
                      an overwrite aborts rather than proceeding.

WITHOUT A FLAG, NOTHING EXISTING IS EVER OVERWRITTEN. A file that differs from
what this script would write is kept, reported, and the run exits 2.

WITH --force OR --force-data, the first file that would actually be overwritten
stops the run and asks you to type a confirmation phrase in full. Answer once
and it covers the rest of the run; answer wrong and nothing is overwritten. A
flag in shell history should not be able to revert a tree somebody has spent
months editing.
      --no-examples   Skip the example data files (inventory entry, groups,
                      policies, services, network and platform data). The
                      structure, modules, stacks, schemas and tooling are
                      still written.
      --backend TYPE  State backend written into stacks/*/backend.tf. Case
                      insensitive; the friendly names in brackets also work.

                        http     GitLab-managed Terraform state  [gitlab]
                                 Locking, encryption at rest and versioning
                                 come from GitLab. Credentials come from
                                 TF_HTTP_USERNAME and TF_HTTP_PASSWORD, never
                                 from a committed file.
                        s3       S3 or an S3-compatible store  [minio, ceph]
                                 Needs DynamoDB or native locking configured.
                        azurerm  Azure blob storage  [azure]
                        local    Filesystem on this server  [file, filesystem]
                                 NO LOCKING. The default, and the placeholder:
                                 it exists so the stacks initialise for offline
                                 validation.

                      Whatever you choose, state carries the full security
                      posture of the estate. It never goes in a git repository:
                      plaintext, permanent history, and no locking.
      --git-init      Run 'git init' in the target directory if it is not
                      already inside a git working tree.
  -n, --dry-run       Report what would be written; change nothing.
  -q, --quiet         Only print the summary and any warnings.
  -h, --help          Show this help.
      --version       Print the bootstrap script version.

Estate data is what describes YOUR network — the rules, groups, segments and
managers. It is written once, on a first run into an empty directory, and from
then on it belongs to you. Regenerated files are this script's own output and
are safe to refresh.

Exit status is 0 on success, 1 on error, 2 if files were skipped because they
already exist with different content (re-run with --force to overwrite).
USAGE
}

log() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

ARGC=$#

# ---------------------------------------------------------------------------
# Interactive mode
#
# Runs when there are no arguments and there is a terminal, or on --interactive.
# Any flag on the command line means somebody is scripting this, so the wizard
# stays out of the way — that is what keeps CI and self-reproduction working.
#
# Every question here maps to a flag that already exists. The wizard prints the
# equivalent command line before it runs, so using it once teaches the flags.
# ---------------------------------------------------------------------------

can_prompt() { { true </dev/tty; } 2>/dev/null; }

say() { printf '%s\n' "$*" >&2; }

# ask <prompt> <default> — free text, empty input takes the default.
ask() {
	local prompt="$1" default="$2" reply=""
	if [ -n "$default" ]; then
		printf '%s [%s]: ' "$prompt" "$default" >&2
	else
		printf '%s: ' "$prompt" >&2
	fi
	IFS= read -r reply </dev/tty || reply=""
	printf '%s' "${reply:-$default}"
}

# ask_yes_no <prompt> <default y|n>
ask_yes_no() {
	local prompt="$1" default="$2" reply=""
	while :; do
		if [ "$default" = y ]; then
			printf '%s [Y/n]: ' "$prompt" >&2
		else
			printf '%s [y/N]: ' "$prompt" >&2
		fi
		IFS= read -r reply </dev/tty || reply=""
		reply="$(printf '%s' "${reply:-$default}" | tr '[:upper:]' '[:lower:]')"
		case "$reply" in
		y | yes) return 0 ;;
		n | no) return 1 ;;
		*) say "  please answer y or n." ;;
		esac
	done
}

# ask_menu <default-index> <prompt> <label>... — echoes the chosen 1-based index.
ask_menu() {
	local default="$1" prompt="$2"
	shift 2
	local count=$# i=1 reply=""
	say ""
	say "$prompt"
	say ""
	for label in "$@"; do
		printf '  %d) %s\n' "$i" "$label" >&2
		i=$((i + 1))
	done
	say ""
	while :; do
		printf 'Select [%s]: ' "$default" >&2
		IFS= read -r reply </dev/tty || reply=""
		reply="${reply:-$default}"
		case "$reply" in
		'' | *[!0-9]*) ;;
		*)
			if [ "$reply" -ge 1 ] && [ "$reply" -le "$count" ]; then
				printf '%s' "$reply"
				return 0
			fi
			;;
		esac
		say "  enter a number from 1 to $count."
	done
}

# The decision the whole review model rests on. Asked at first run because
# retrofitting review onto an estate somebody has been hand-editing is harder
# than starting with it — though scripts/enable-gitops.sh does exactly that, so
# "decide later" is a real answer rather than a trap.
wizard_vcs() {
	local choice
	choice="$(ask_menu 1 "Where do these files live, and how do changes get reviewed?" \
		"GitLab   — full CI/CD pipeline, set up for you      (recommended)" \
		"GitHub   — workflows written; you wire them up" \
		"Another git host — CI files written; you wire them up" \
		"Local files only — no versioning, no pipeline, manual apply")"

	case "$choice" in
	1)
		CI_PLATFORM=gitlab
		CI_EXPLICIT=1
		local how
		how="$(ask_menu 1 "  GitLab — which one?" \
			"I have a GitLab and the repository URL" \
			"Stand one up locally in Docker and create the repository" \
			"Not yet — just write the pipeline, I will connect it later")"
		case "$how" in
		1)
			VCS=gitlab
			GITLAB_URL_ARG="$(ask "  GitLab URL (https://gitlab.example.com)" "$GITLAB_URL_ARG")"
			if [ -n "$GITLAB_URL_ARG" ]; then
				GITLAB_PROJECT_ARG="$(ask "  Project path (group/name)" "${GITLAB_PROJECT_ARG:-netops/nsx-terraform}")"
				say ""
				say "  With an access token (scope 'api', Maintainer or Owner) this can"
				say "  create the project, push, set the CI variables and protect the"
				say "  default branch. Leave blank to do that yourself later."
				GITLAB_TOKEN_ARG="$(ask "  Access token (blank to skip)" "")"
				GIT_BRANCH="$(ask "  Default branch" "$GIT_BRANCH")"
				GIT_REMOTE="${GITLAB_URL_ARG%/}/${GITLAB_PROJECT_ARG}.git"
				if [ -z "$GITLAB_TOKEN_ARG" ]; then
					say ""
					say "  No token: the remote will be set but nothing created or pushed."
					say "  Later:  scripts/gitlab-setup.sh --url $GITLAB_URL_ARG \\"
					say "            --token TOKEN --project $GITLAB_PROJECT_ARG"
				fi
			else
				say "  no URL given; writing the pipeline and leaving GitLab for later."
				VCS=none
			fi
			;;
		2)
			VCS=gitlab-docker
			say ""
			say "  GitLab CE and a runner will be started in Docker after the files"
			say "  are written, the repository created and pushed, the runner"
			say "  registered, and the initial root password printed."
			say "  Needs docker and roughly 4 GB of RAM; first boot takes minutes."
			;;
		3)
			VCS=none
			say ""
			say "  Pipeline written, nothing connected."
			say "  When ready:  scripts/enable-gitops.sh"
			;;
		esac
		;;
	2)
		VCS=github
		CI_PLATFORM=github
		CI_EXPLICIT=1
		GIT_REMOTE="$(ask "  Repository URL (git@github.com:org/repo.git), or blank for later" "")"
		[ -n "$GIT_REMOTE" ] || VCS=none
		say ""
		say "  Workflows go in .github/workflows/ — validate, plan and apply."
		say "  You will need to set the repository secrets and protect the apply"
		say "  environments yourself; docs/GITOPS.md lists exactly which."
		;;
	3)
		VCS=git
		CI_PLATFORM=both
		CI_EXPLICIT=1
		GIT_REMOTE="$(ask "  Repository URL, or blank for later" "")"
		[ -n "$GIT_REMOTE" ] || VCS=none
		say ""
		say "  Both .gitlab-ci.yml and .github/workflows/ are written; point your"
		say "  host at whichever it understands and delete the other."
		;;
	4)
		VCS=none
		CI_PLATFORM=none
		CI_EXPLICIT=1
		say ""
		say "  No versioning and no pipeline. Changes are applied by hand with"
		say "  make plan / make show / make apply, which still refuse to apply"
		say "  without a saved plan and an explicit APPROVE=yes."
		say ""
		say "  Nothing will record who changed a firewall rule, when, or why."
		say "  scripts/enable-gitops.sh adds all of it later."
		;;
	esac
}

wizard_backend() {
	local choice
	choice="$(ask_menu 1 "State backend — where Terraform keeps its state." \
		"GitLab-managed state  (locking, encryption and history from GitLab)" \
		"S3 or S3-compatible   (MinIO, Ceph; needs locking configured)" \
		"Azure blob storage" \
		"Filesystem on this server   NO LOCKING — lab only" \
		"Decide later   (placeholder; apply is blocked until you choose)")"
	case "$choice" in
	1) BACKEND=http ;;
	2) BACKEND=s3 ;;
	3) BACKEND=azurerm ;;
	4)
		BACKEND=local
		say ""
		say "  Filesystem state has no locking: two runs at once corrupt it."
		say "  Only defensible with one runner, an encrypted and backed-up"
		say "  volume, and permissions limited to the pipeline user."
		;;
	5) BACKEND=local ;;
	esac
}

wizard_summary_and_go() {
	local mode="create — never overwrites anything that exists"
	[ "$FORCE" = 1 ] && mode="update — overwrites regenerated files after you type the phrase"
	[ "$FORCE_DATA" = 1 ] && mode="update — overwrites regenerated files AND estate data after the phrase"
	[ "$DRY_RUN" = 1 ] && mode="dry run — reports only, writes nothing"

	local backend_label="$BACKEND"
	[ "$BACKEND" = http ] && backend_label="http (GitLab-managed state)"
	[ "$BACKEND" = local ] && backend_label="local (placeholder, no locking)"

	local cmd="scripts/bootstrap.sh --dir '$ROOT'"
	[ "$BACKEND" != local ] && cmd="$cmd --backend $BACKEND"
	case "$VCS" in
	gitlab)
		cmd="$cmd --vcs gitlab"
		if [ -n "$GITLAB_TOKEN_ARG" ]; then
			cmd="$cmd --gitlab-url '$GITLAB_URL_ARG' --gitlab-project '$GITLAB_PROJECT_ARG' --gitlab-token '***'"
		else
			cmd="$cmd --git-remote '$GIT_REMOTE'"
		fi
		;;
	github | git) cmd="$cmd --vcs $VCS --git-remote '$GIT_REMOTE'" ;;
	gitlab-docker) cmd="$cmd --vcs gitlab-docker" ;;
	none) cmd="$cmd --vcs none" ;;
	esac
	cmd="$cmd --ci $CI_PLATFORM"
	[ "$WITH_EXAMPLES" = 0 ] && cmd="$cmd --no-examples"
	[ "$WITH_GIT" = 1 ] && cmd="$cmd --git-init"
	[ "$FORCE_DATA" = 1 ] && cmd="$cmd --force-data"
	[ "$FORCE" = 1 ] && [ "$FORCE_DATA" = 0 ] && cmd="$cmd --force"
	[ "$DRY_RUN" = 1 ] && cmd="$cmd --dry-run"

	say ""
	say "-------------------------------------------------------------------"
	local vcs_label
	case "$VCS" in
	gitlab)
		if [ -n "$GITLAB_TOKEN_ARG" ]; then
			vcs_label="GitLab $GITLAB_URL_ARG — project $GITLAB_PROJECT_ARG will be created and pushed"
		else
			vcs_label="GitLab — ${GIT_REMOTE:-no remote yet} (remote only; nothing created)"
		fi
		;;
	github | git) vcs_label="$VCS — ${GIT_REMOTE:-no remote yet} (branch $GIT_BRANCH)" ;;
	gitlab-docker) vcs_label="GitLab in Docker, started after generation" ;;
	none) vcs_label="local files only — no remote (migrate later)" ;;
	*) vcs_label="unchanged" ;;
	esac

	say "  target directory : $ROOT"
	local ci_label
	case "$CI_PLATFORM" in
	gitlab) ci_label="GitLab — .gitlab-ci.yml + child pipeline" ;;
	github) ci_label="GitHub — .github/workflows/" ;;
	both) ci_label="GitLab and GitHub, both written" ;;
	none) ci_label="none — manual make plan / make apply" ;;
	esac

	say "  version control  : $vcs_label"
	say "  review pipeline  : $ci_label"
	say "  state backend    : $backend_label"
	say "  example data     : $([ "$WITH_EXAMPLES" = 1 ] && echo 'yes' || echo 'no')"
	say "  git init         : $([ "$WITH_GIT" = 1 ] && echo 'yes' || echo 'no')"
	say "  mode             : $mode"
	say "-------------------------------------------------------------------"
	say ""
	say "Same thing without the questions, next time:"
	say "  $cmd"
	say ""

	ask_yes_no "Proceed?" y || die "cancelled; nothing was written."
	say ""
}

wizard_basic() {
	say ""
	say "Basic — best practices assumed. Four questions."
	ROOT="$(ask "Directory to create the repository in" "$ROOT")"
	wizard_vcs
	wizard_backend
	if ask_yes_no "Include worked example data? (recommended the first time)" y; then
		WITH_EXAMPLES=1
	else
		WITH_EXAMPLES=0
	fi
	# Assumed: git init on a tree that is not already one, and never overwrite.
	git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || WITH_GIT=1
	wizard_summary_and_go
}

wizard_advanced() {
	say ""
	say "Advanced — every option."
	ROOT="$(ask "Directory to create the repository in" "$ROOT")"
	wizard_vcs
	wizard_backend

	if ask_yes_no "Include worked example data? (4 managers, 10 groups, 4 policy files)" y; then
		WITH_EXAMPLES=1
	else
		WITH_EXAMPLES=0
	fi

	if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		say ""
		say "  Already inside a git working tree; leaving git alone."
		WITH_GIT=0
	elif ask_yes_no "Run 'git init' in that directory?" y; then
		WITH_GIT=1
	else
		WITH_GIT=0
	fi

	local ow
	ow="$(ask_menu 1 "Existing files — what may this run overwrite?" \
		"Nothing   (differing files are kept and reported; exit 2)" \
		"Regenerated files   (modules, stacks, scripts, CI, docs; NOT your data)" \
		"Regenerated files AND estate data   (data/, inventory/, envs/)")"
	case "$ow" in
	1) FORCE=0 FORCE_DATA=0 ;;
	2) FORCE=1 FORCE_DATA=0 ;;
	3)
		FORCE=1 FORCE_DATA=1
		say ""
		say "  You will be asked to type the confirmation phrase in full before"
		say "  anything is overwritten. Imported estate is refused regardless."
		;;
	esac

	ask_yes_no "Dry run — report what would be written and change nothing?" n && DRY_RUN=1
	ask_yes_no "Quiet — print only the summary and warnings?" n && QUIET=1

	wizard_summary_and_go
}

wizard_update() {
	say ""
	say "Update an existing tree — take newer generator output."
	ROOT="$(ask "Directory of the existing repository" "$ROOT")"
	[ -d "$ROOT" ] || die "$ROOT does not exist. Use option 1 or 2 to create a new tree."

	local ow
	ow="$(ask_menu 2 "What may this run overwrite?" \
		"Nothing   (add missing files only — safest)" \
		"Regenerated files   (modules, stacks, scripts, CI, docs; NOT your data)" \
		"Regenerated files AND estate data   (data/, inventory/, envs/)")"
	case "$ow" in
	1) FORCE=0 FORCE_DATA=0 ;;
	2) FORCE=1 FORCE_DATA=0 ;;
	3) FORCE=1 FORCE_DATA=1 ;;
	esac

	# Keep whatever backend the tree already uses unless asked to change it.
	local current=""
	current="$(sed -n 's/.*backend "\([a-z0-9]*\)".*/\1/p' "$ROOT/stacks/platform/backend.tf" 2>/dev/null | head -1)"
	if [ -n "$current" ]; then
		BACKEND="$current"
		say ""
		say "  Existing state backend: $current"
		if ask_yes_no "Change it?" n; then
			wizard_backend
		fi
	else
		wizard_backend
	fi

	WITH_EXAMPLES=0 # never re-seed example data into a tree in use
	ask_yes_no "Dry run first — report what would change and write nothing?" y && DRY_RUN=1

	wizard_summary_and_go
}

# The migration path for a tree set up without versioning. Hands off to the
# generated script rather than duplicating it, so there is one implementation.
wizard_migrate() {
	say ""
	say "Add version control and the review pipeline to an existing tree."
	ROOT="$(ask "Directory of the existing repository" "$ROOT")"
	[ -d "$ROOT" ] || die "$ROOT does not exist. Use option 1 or 2 to create a new tree."

	if [ ! -x "$ROOT/scripts/enable-gitops.sh" ]; then
		say ""
		say "  That tree predates the migration script. Refreshing the generator's"
		say "  own output first — your data is not touched."
		FORCE=1
		return 0
	fi

	say ""
	say "  Handing over to $ROOT/scripts/enable-gitops.sh"
	say ""
	exec "$ROOT/scripts/enable-gitops.sh"
}

run_wizard() {
	say ""
	say "==================================================================="
	say " NSX / VCF Terraform scaffold                      bootstrap $VERSION"
	say "==================================================================="

	local choice
	choice="$(ask_menu 1 "What would you like to do?" \
		"Basic deployment      — best practices assumed, four questions" \
		"Advanced deployment   — every option asked" \
		"Update an existing tree" \
		"Add version control and the review pipeline to an existing tree" \
		"Dry run               — show what a basic run would write" \
		"Help                  — list every flag" \
		"Quit")"

	case "$choice" in
	1) wizard_basic ;;
	2) wizard_advanced ;;
	3) wizard_update ;;
	4) wizard_migrate ;;
	5)
		DRY_RUN=1
		wizard_basic
		;;
	6)
		usage
		exit 0
		;;
	7)
		say "nothing written."
		exit 0
		;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
	-d | --dir)
		[ $# -ge 2 ] || die "--dir requires a path"
		ROOT="$2"
		shift 2
		;;
	--dir=*)
		ROOT="${1#*=}"
		shift
		;;
	-f | --force)
		FORCE=1
		shift
		;;
	--force-data)
		FORCE=1
		FORCE_DATA=1
		shift
		;;
	--no-examples)
		WITH_EXAMPLES=0
		shift
		;;
	--confirm)
		[ $# -ge 2 ] || die "--confirm requires the phrase"
		CONFIRM_ARG="$2"
		shift 2
		;;
	--confirm=*)
		CONFIRM_ARG="${1#*=}"
		shift
		;;
	--backend)
		[ $# -ge 2 ] || die "--backend requires a type"
		BACKEND="$2"
		shift 2
		;;
	--backend=*)
		BACKEND="${1#*=}"
		shift
		;;
	--ci)
		[ $# -ge 2 ] || die "--ci requires a value"
		CI_PLATFORM="$2"
		CI_EXPLICIT=1
		shift 2
		;;
	--ci=*)
		CI_PLATFORM="${1#*=}"
		CI_EXPLICIT=1
		shift
		;;
	--vcs)
		[ $# -ge 2 ] || die "--vcs requires a value"
		VCS="$2"
		shift 2
		;;
	--vcs=*)
		VCS="${1#*=}"
		shift
		;;
	--git-remote)
		[ $# -ge 2 ] || die "--git-remote requires a URL"
		GIT_REMOTE="$2"
		# Only a default: an explicit --vcs, before or after, still wins.
		[ "$VCS" = ask ] && VCS=gitlab
		shift 2
		;;
	--git-remote=*)
		GIT_REMOTE="${1#*=}"
		[ "$VCS" = ask ] && VCS=gitlab
		shift
		;;
	--gitlab-url)
		[ $# -ge 2 ] || die "--gitlab-url requires a URL"
		GITLAB_URL_ARG="$2"
		[ "$VCS" = ask ] && VCS=gitlab
		shift 2
		;;
	--gitlab-url=*)
		GITLAB_URL_ARG="${1#*=}"
		[ "$VCS" = ask ] && VCS=gitlab
		shift
		;;
	--gitlab-token)
		[ $# -ge 2 ] || die "--gitlab-token requires a token"
		GITLAB_TOKEN_ARG="$2"
		shift 2
		;;
	--gitlab-token=*)
		GITLAB_TOKEN_ARG="${1#*=}"
		shift
		;;
	--gitlab-project)
		[ $# -ge 2 ] || die "--gitlab-project requires group/name"
		GITLAB_PROJECT_ARG="$2"
		shift 2
		;;
	--gitlab-project=*)
		GITLAB_PROJECT_ARG="${1#*=}"
		shift
		;;
	--git-branch)
		[ $# -ge 2 ] || die "--git-branch requires a name"
		GIT_BRANCH="$2"
		shift 2
		;;
	--git-branch=*)
		GIT_BRANCH="${1#*=}"
		shift
		;;
	-i | --interactive)
		INTERACTIVE=1
		shift
		;;
	--no-interactive)
		INTERACTIVE=0
		NO_INTERACTIVE=1
		shift
		;;
	--git-init)
		WITH_GIT=1
		shift
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	-q | --quiet)
		QUIET=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--version)
		printf 'bootstrap.sh %s\n' "$VERSION"
		exit 0
		;;
	*)
		# Editors, chat clients and word processors substitute an em- or
		# en-dash for a double hyphen when you copy a command out of them.
		# The result looks almost identical and is a different byte sequence.
		# Strip the exact dash rather than one character: these are multibyte,
		# and ${1#?} would leave the remaining bytes behind.
		bare=""
		case "$1" in
		—*) bare="${1#—}" ;;
		–*) bare="${1#–}" ;;
		―*) bare="${1#―}" ;;
		‐*) bare="${1#‐}" ;;
		‑*) bare="${1#‑}" ;;
		−*) bare="${1#−}" ;;
		esac
		if [ -n "$bare" ]; then
			die "unknown option: $1
       That leading character is a dash, not two hyphens. Something between the
       command and your shell substituted it — editors and chat clients do this
       silently when you copy a command. Retype it as:  --$bare"
		fi
		die "unknown option: $1 (try --help)" ;;
	esac
done

VCS="$(printf '%s' "$VCS" | tr '[:upper:]' '[:lower:]')"
case "$VCS" in
docker | local-gitlab | gitlab-local) VCS=gitlab-docker ;;
gh) VCS=github ;;
local | no | skip) VCS=none ;;
esac
case "$VCS" in
ask | none | git | github | gitlab | gitlab-docker) ;;
*) die "unknown --vcs: $VCS
       Expected one of:
         gitlab         an existing GitLab; full pipeline (the default)
         gitlab-docker  stand GitLab up locally in Docker, set everything up
         github         GitHub; workflows written for you to wire up
         git            another git host; CI files written, you wire them up
         none           no versioning, no pipeline, manual apply" ;;
esac

# What was chosen last time. Without this, re-running in an existing tree would
# quietly fall back to the defaults and start writing pipeline files somebody
# deliberately did not want — the opposite of what a re-run should do.
CONF="$ROOT/.nsx-bootstrap.conf"
if [ -f "$CONF" ]; then
	# shellcheck disable=SC1090
	. "$CONF" 2>/dev/null || warn "could not read $CONF; using defaults"
	[ "$VCS" = ask ] && [ -n "${SAVED_VCS:-}" ] && VCS="$SAVED_VCS"
	[ "$CI_EXPLICIT" = 0 ] && [ -n "${SAVED_CI_PLATFORM:-}" ] && {
		CI_PLATFORM="$SAVED_CI_PLATFORM"
		CI_EXPLICIT=1 # a saved answer is an answer; do not re-derive over it
	}
	[ -z "$GIT_REMOTE" ] && GIT_REMOTE="${SAVED_GIT_REMOTE:-}"
	[ "$GIT_BRANCH" = main ] && [ -n "${SAVED_GIT_BRANCH:-}" ] && GIT_BRANCH="$SAVED_GIT_BRANCH"
	[ "$BACKEND" = local ] && [ -n "${SAVED_BACKEND:-}" ] && BACKEND="$SAVED_BACKEND"
fi

# Nobody chose, and nobody was asked (a flag suppressed the menu, or there is no
# terminal). Take the documented default rather than a half-configured tree that
# has a GitLab pipeline in it but is not a git repository.
[ "$VCS" = ask ] && VCS=gitlab

# The pipeline follows the host, unless --ci said otherwise.
if [ "$CI_EXPLICIT" = 0 ]; then
	case "$VCS" in
	gitlab | gitlab-docker) CI_PLATFORM=gitlab ;;
	github) CI_PLATFORM=github ;;
	git) CI_PLATFORM=both ;;
	none) CI_PLATFORM=none ;;
	esac
fi

CI_PLATFORM="$(printf '%s' "$CI_PLATFORM" | tr '[:upper:]' '[:lower:]')"
case "$CI_PLATFORM" in
all) CI_PLATFORM=both ;;
no | skip | manual) CI_PLATFORM=none ;;
esac
case "$CI_PLATFORM" in
gitlab | github | both | none) ;;
*) die "unknown --ci: $CI_PLATFORM (expected gitlab, github, both or none)" ;;
esac

# Answers true when the named platform's pipeline should be written.
wants_ci() {
	case "$CI_PLATFORM" in
	both) return 0 ;;
	"$1") return 0 ;;
	*) return 1 ;;
	esac
}

# The menu runs on --interactive, or when invoked bare with a terminal present.
# A single flag suppresses it: flags mean a script, and a script must not block.
if [ "$INTERACTIVE" = 1 ]; then
	can_prompt || die "--interactive needs a terminal. There is none, so nothing was written."
	run_wizard
elif [ "$ARGC" -eq 0 ] && [ "$NO_INTERACTIVE" = 0 ] && can_prompt; then
	run_wizard
fi

# The Terraform backend type is what goes in backend.tf, but nobody thinks in
# those terms — GitLab-managed state is the 'http' backend, and MinIO and Ceph
# are the 's3' one. Accept what a person would actually type.
BACKEND="$(printf '%s' "$BACKEND" | tr '[:upper:]' '[:lower:]')"
case "$BACKEND" in
gitlab | gitlab-managed | tfstate-http) BACKEND=http ;;
file | filesystem | disk | server) BACKEND=local ;;
minio | ceph) BACKEND=s3 ;;
azure | blob) BACKEND=azurerm ;;
esac

case "$BACKEND" in
local | http | s3 | azurerm) ;;
git | github | repo)
	die "state does not belong in a git repository: it is plaintext, git history is
       permanent, and git has no locking, so two runs diverge silently. For
       GitLab-managed Terraform state — an API GitLab hosts, not a file in a
       repository — use --backend gitlab."
	;;
*)
	die "unknown backend: $BACKEND
       Valid types: local, http, s3, azurerm
       Also accepted: gitlab (=http), minio/ceph (=s3), azure (=azurerm),
                      file/filesystem/disk/server (=local)"
	;;
esac

if [ ! -d "$ROOT" ]; then
	if [ "$DRY_RUN" = 1 ]; then
		log "would create directory $ROOT"
	else
		mkdir -p "$ROOT" || die "cannot create $ROOT"
	fi
fi
[ "$DRY_RUN" = 1 ] || ROOT="$(cd "$ROOT" && pwd)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nsx-bootstrap.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

MANIFEST="$ROOT/data/.import-manifest.json"

# Was the example data already seeded before this run? Used for the
# data/.example-content marker, which must be written once and then stay
# deleted: removing it is how somebody says "this estate is real now", and a
# re-run must not undo that.
if [ -f "$ROOT/inventory/managers.yaml" ]; then SEEDED_ALREADY=1; else SEEDED_ALREADY=0; fi

# is_estate_data <relative-path>
#
# Estate data describes the customer's network: rules, groups, segments, the
# manager registry, backend settings. This script writes it once into an empty
# directory and never again — --force is for refreshing the scaffold's own
# output, and refreshing the scaffold must not be able to destroy a hand-built
# or imported ruleset.
is_estate_data() {
	case "$1" in
	data/schema/*.json) return 1 ;; # regenerated: the schemas are this script's
	data/schema/tag-scopes.yaml) return 0 ;;
	data/* | inventory/* | envs/*) return 0 ;;
	*) return 1 ;;
	esac
}

# is_imported <relative-path> — recorded in the import manifest, i.e. adopted
# from a live NSX manager. Never overwritten, by any flag.
is_imported() {
	[ -f "$MANIFEST" ] || return 1
	grep -Fq "\"$1\"" "$MANIFEST" 2>/dev/null
}

# confirm_overwrite <relative-path>
#
# A flag is not consent. On day two this script runs against a tree somebody has
# been editing for months, and --force in shell history is one arrow-key away
# from a run that reverts all of it. So the first file that would actually be
# overwritten stops the run and asks for the phrase, typed in full.
#
# Asked once per run: answering covers every remaining file, and nothing has
# been overwritten before the question. Read from /dev/tty, because write_file
# takes its content on stdin — a read here would eat the heredoc.
confirm_overwrite() {
	[ "$CONFIRMED" = 1 ] && return 0

	local scope
	if [ "$FORCE_DATA" = 1 ]; then
		scope="Regenerated files AND ESTATE DATA — data/, inventory/ and envs/, which
       describe your network. Anything recorded in data/.import-manifest.json is
       still refused outright."
	else
		scope="Regenerated files only — modules, stacks, scripts, schemas, CI, docs.
       Estate data in data/, inventory/ and envs/ will NOT be touched."
	fi

	if [ -n "$CONFIRM_ARG" ]; then
		[ "$CONFIRM_ARG" = "$CONFIRM_PHRASE" ] || die "--confirm does not match. Expected exactly:
       $CONFIRM_PHRASE
       Nothing has been overwritten."
		CONFIRMED=1
		log ""
		log "--confirm matched; overwriting existing files for the rest of this run."
		log ""
		return 0
	fi

	# Not [ -r /dev/tty ]: the device node is readable by mode even when there is
	# no controlling terminal to open. Try the open.
	if ! { true </dev/tty; } 2>/dev/null; then
		die "$1 already exists and differs, and this run would overwrite it.
       There is no terminal to confirm on, so nothing has been changed.
       In a pipeline, pass the phrase explicitly:
         --confirm '$CONFIRM_PHRASE'"
	fi

	{
		printf '\n'
		printf '%s\n' "-------------------------------------------------------------------"
		printf 'About to OVERWRITE files that already exist and differ from what this\n'
		printf 'script generates. First one found: %s\n' "$1"
		printf '\n'
		printf 'Scope: %s\n' "$scope"
		printf '\n'
		printf 'This cannot be undone by re-running the script. If the tree is a git\n'
		printf 'working copy, commit or stash first — that is your undo.\n'
		printf '%s\n' "-------------------------------------------------------------------"
		printf '\n'
		printf 'Type exactly this phrase to continue, or anything else to abort:\n'
		printf '  %s\n' "$CONFIRM_PHRASE"
		printf '> '
	} >&2

	local reply=""
	IFS= read -r reply </dev/tty || reply=""

	if [ "$reply" != "$CONFIRM_PHRASE" ]; then
		printf '\n' >&2
		die "phrase did not match. Nothing has been overwritten."
	fi

	CONFIRMED=1
	printf '\n' >&2
	log "confirmed; overwriting existing files for the rest of this run."
	log ""
}

# write_file <relative-path> — content is read from stdin.
# record_gen <relative-path> <staged-file> — remember what the generator wrote,
# so scripts/update.sh can later tell its own changes from yours. Estate data is
# yours from the first minute and is not recorded.
record_gen() {
	is_estate_data "$1" && return 0
	[ "$DRY_RUN" = 1 ] && return 0
	printf '%s  %s\n' "$(sha256sum "$2" | awk '{print $1}')" "$1" >>"$STAGE/generated.sha256"
}

write_file() {
	local rel="$1"
	local dest="$ROOT/$rel"
	local tmp="$STAGE/staged"
	local may_overwrite="$FORCE"
	local guard=""

	cat >"$tmp"

	if is_estate_data "$rel"; then
		if is_imported "$rel"; then
			may_overwrite=0
			guard="imported from a live manager; recorded in data/.import-manifest.json"
		else
			may_overwrite="$FORCE_DATA"
			guard="estate data; use --force-data to overwrite"
		fi
	fi

	if [ -e "$dest" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			# cmp against the real file even in dry-run: it is read-only.
			if cmp -s "$tmp" "$dest"; then
				log "  ok       $rel"
				unchanged=$((unchanged + 1))
			elif [ "$may_overwrite" = 1 ]; then
				log "  would overwrite $rel"
				updated=$((updated + 1))
			elif [ -n "$guard" ]; then
				warn "would keep $rel — $guard"
				protected=$((protected + 1))
			else
				warn "exists with different content, kept: $rel (use --force to overwrite)"
				skipped=$((skipped + 1))
			fi
			return 0
		fi
		if cmp -s "$tmp" "$dest"; then
			log "  ok       $rel"
			record_gen "$rel" "$tmp"
			unchanged=$((unchanged + 1))
		elif [ "$may_overwrite" = 1 ]; then
			confirm_overwrite "$rel"
			cat "$tmp" >"$dest"
			record_gen "$rel" "$tmp"
			log "  updated  $rel"
			updated=$((updated + 1))
		elif [ -n "$guard" ]; then
			warn "kept $rel — $guard"
			protected=$((protected + 1))
			return 0
		else
			warn "exists with different content, kept: $rel (use --force to overwrite)"
			skipped=$((skipped + 1))
			return 0
		fi
	else
		if [ "$DRY_RUN" = 1 ]; then
			log "  would create $rel"
			created=$((created + 1))
			return 0
		fi
		mkdir -p "$(dirname "$dest")"
		cat "$tmp" >"$dest"
		record_gen "$rel" "$tmp"
		log "  created  $rel"
		created=$((created + 1))
	fi
}

# mark_executable <relative-path> ... — chmod +x applied at the end of the run.
mark_executable() { EXECUTABLES="$EXECUTABLES $*"; }

make_dir() {
	local rel="$1"
	if [ "$DRY_RUN" = 1 ]; then
		[ -d "$ROOT/$rel" ] || log "  would mkdir $rel/"
		return 0
	fi
	mkdir -p "$ROOT/$rel"
}

# A .gitkeep keeps an intentionally empty directory in git.
keep_dir() {
	make_dir "$1"
	write_file "$1/.gitkeep" </dev/null
}

log "nsx-terraform bootstrap $VERSION"
log "target: $ROOT"
[ "$DRY_RUN" = 1 ] && log "(dry run — nothing will be written)"
log ""

# ---------------------------------------------------------------------------
# 1. Directory structure (docs/ARCHITECTURE.md section 4, plus data/network and
#    data/platform for the per-site network and platform stacks).
# ---------------------------------------------------------------------------

log "directories"
for d in \
	inventory \
	data/groups data/policies data/services data/schema data/network data/platform data/vm-tags \
	modules/dfw-policy modules/group modules/service modules/segment modules/tier1 modules/tier0 modules/vm-tags \
	stacks/global-security stacks/local-security stacks/local-network stacks/platform stacks/local-tags \
	envs scripts docs deploy/gitlab deploy/ci-image; do
	make_dir "$d"
done
wants_ci gitlab && make_dir .gitlab/merge_request_templates
wants_ci github && make_dir .github/workflows
true # the two above are conditional; do not let the last one set the status
log ""

log "files"

# ---------------------------------------------------------------------------
# 2. Repository root
# ---------------------------------------------------------------------------

write_file .gitignore <<'SCAFFOLD_EOF'
# Terraform working directories and state. State contains the full security
# posture of the estate — it never lands in git. See docs/ARCHITECTURE.md section 9.
.terraform/
*.tfstate
*.tfstate.*

# Variable files may carry site specifics; examples are committed.
*.tfvars
!*.example.tfvars

# Saved plans are sensitive artifacts, not review attachments.
tfplan
tfplan.site
*.tfplan
plan.json
plan.txt

crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Placeholder local backend output. Never a real manager's state.
.local-state/

# Drift reports and raw estate dumps. A plan reveals the security posture of
# the estate; it is not a review attachment.
reports/

# Sidecars written by import-estate.py when a target already exists. Diff them
# against the real file, merge by hand, then delete.
*.yaml.new
*.tf.new

# Host-specific GitLab container settings written by scripts/gitlab-https.sh.
deploy/gitlab/.env
deploy/gitlab/ssl/
# Optional per-host CI network overrides (may hold proxy credentials).
deploy/gitlab/ci-network.env
# Provider packages and Python wheels fetched by scripts/ci-image.sh for the CI image.
deploy/ci-image/plugins/
deploy/ci-image/wheels/

# Originals saved by the generator's update script before it overwrites a file.
.nsx-update-backup/

# Local tool output.
.bin/
__pycache__/
*.pyc
.venv/

# .terraform.lock.hcl IS committed — it is the provider pin, not a secret.
SCAFFOLD_EOF

write_file Makefile <<'SCAFFOLD_EOF'
# Entry points for this repository. Every target here has been run; if you add
# one, document it in docs/ARCHITECTURE.md section 16 in the same commit.
#
# Usage:
#   make help
#   make validate
#   make plan SITE=lon1 STACK=global-security

SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
SITE   ?=
STACK  ?=

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Check that the tools this repository needs are present
	@scripts/preflight.sh

.PHONY: ready
ready: ## Is this repository ready to apply to a production estate? Exits 1 if not.
	@scripts/readiness.sh

.PHONY: selftest
selftest: ## Prove the generator and validators work. Offline. Exits 1 on any failure.
	@scripts/selftest.sh

.PHONY: validate
validate: schema-validate fmt-check ## Run every offline check (no credentials, no network)

.PHONY: schema-validate
schema-validate: ## Validate everything under data/ and inventory/ against the schemas
	@$(PYTHON) scripts/validate-data.py

.PHONY: fmt
fmt: ## Rewrite all Terraform files in canonical format
	@terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	@terraform fmt -recursive -check -diff .

.PHONY: matrix
matrix: ## Print the CI matrix derived from inventory/managers.yaml
	@$(PYTHON) scripts/ci-matrix.py

.PHONY: add-rule
add-rule: ## Add a rule to an EXISTING policy. POLICY=<id> RULE=<key> ARGS='--source x --scope y'
	@$(PYTHON) scripts/add-rule.py --policy "$(POLICY)" --rule "$(RULE)" $(ARGS)

.PHONY: tag-vm
tag-vm: ## Tag a VM as a data edit. SITE=<site> VM=<name> ARGS='--set workload=payments-web'
	@$(PYTHON) scripts/tag-vm.py --site "$(SITE)" --vm "$(VM)" $(ARGS)

.PHONY: tags
tags: ## List the VMs tagged from Terraform at SITE
	@$(PYTHON) scripts/tag-vm.py --site "$(SITE)" --list

.PHONY: import
import: ## Adopt existing objects: SITE=<site> [DUMP=<file>] [POLICY="id1 id2"] [TRANCHE=<name>]
	@set -- ; for p in $(POLICY); do set -- "$$@" --policy "$$p"; done; \
	[ -z "$(TRANCHE)" ] || set -- "$$@" --tranche "$(TRANCHE)"; \
	if [ -n "$(DUMP)" ]; then \
		$(PYTHON) scripts/import-estate.py --site "$(SITE)" --from-dump "$(DUMP)" "$$@"; \
	else \
		scripts/with-credentials.sh "$(SITE)" -- $(PYTHON) scripts/import-estate.py --site "$(SITE)" "$$@"; \
	fi

.PHONY: hand-back
hand-back: ## Stop managing one object, without deleting it: STACK=<stack> ADDRESS='<resource address>'
	@$(PYTHON) scripts/hand-back.py --stack "$(STACK)" --address '$(ADDRESS)'

.PHONY: drift
drift: ## Report drift for STACK at SITE. Reports only — never reverts, never writes data/.
	@scripts/with-credentials.sh "$(SITE)" -- scripts/drift.sh "$(STACK)" "$(SITE)"

.PHONY: init
init: ## terraform init for STACK against SITE
	@scripts/tf.sh init "$(STACK)" "$(SITE)"

.PHONY: plan
plan: ## terraform plan -out=tfplan for STACK against SITE
	@scripts/tf.sh plan "$(STACK)" "$(SITE)"

.PHONY: show
show: ## Render the saved plan for STACK/SITE in human-readable form
	@scripts/tf.sh show "$(STACK)" "$(SITE)"

.PHONY: apply
apply: ## Apply the SAVED plan for STACK/SITE. Requires APPROVE=yes and a human decision.
	@scripts/tf.sh apply "$(STACK)" "$(SITE)"

.PHONY: clean
clean: ## Remove local plan files and python caches (never touches state)
	@find . -name 'tfplan' -o -name 'tfplan.site' -o -name '*.tfplan' -o -name 'plan.json' | xargs -r rm -f
	@find . -name '__pycache__' -type d | xargs -r rm -rf
SCAFFOLD_EOF

write_file .editorconfig <<'SCAFFOLD_EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.{tf,tfvars,hcl}]
indent_style = space
indent_size = 2

[*.{yaml,yml,json}]
indent_style = space
indent_size = 2

[*.py]
indent_style = space
indent_size = 4

[Makefile]
indent_style = tab
SCAFFOLD_EOF

write_file docs/IMPORT.md <<'SCAFFOLD_EOF'
# Adopting the estate you already have

NSX is already running and the rules already carry traffic. Nothing here may
create a second copy of any of it, change it on the way in, or delete it by
accident. The approach is **adopt, never recreate**, one piece of one manager
at a time, with every step reversible.

## What you can rely on, and what enforces it

| Guarantee | Enforced by |
|---|---|
| Pointing the pipeline at a manager changes nothing until you adopt something. Terraform only acts on objects in `data/`; it never touches what is not there. | Every resource is `for_each` over data. A manager with no data plans **no changes**. |
| Adoption imports; it never creates, edits or deletes. | `scripts/plan-guard.py`, run by `scripts/tf.sh` after every plan and again before every apply: while a tranche is open, any create, update or destroy fails the plan. |
| Nothing live is deleted unless that exact object is approved, in the merge request. | `plan-guard.py` refuses every destroy and replace not listed in `allow-destroy.txt`. Policies additionally carry `prevent_destroy`. |
| An object is never built twice. | Objects keep their real NSX id (`nsx_id`), so a create of an existing object fails at the provider (`Resource with id … already exists`) before any write. |
| Nothing is adopted lossily. | `import-estate.py` adopts only what it can represent exactly; the rest stays in the UI and is listed. |
| A tranche on one manager does not affect the others that share the stack. | Import files are gated on `var.site`; the working directory is re-initialised per manager, and a saved plan only applies to the manager it was made for. |
| Any adoption can be undone without touching NSX. | `scripts/hand-back.py` (below). |

## Before you start

1. `make preflight`, and the managers in `inventory/managers.yaml` with one
   `envs/<site>.backend.hcl` each.
2. Pick a **pilot**: one Local Manager, one application policy. Not the busiest
   one, and not production-critical on the first pass.
3. Run a plan for that manager with no data. It must say **no changes**. That is
   your proof that the tooling is inert until you adopt something.

## From the pipeline: the usual way

No credentials on any server, and every step leaves a record in GitLab.

1. **Survey.** *Build → Pipelines → Run pipeline* on the default branch, with the
   variable `ADOPT_SITE` set to the manager (`lon1`). The `adopt` job reads the
   manager with the read-only plan credential and lists its policies and whether
   each can be adopted. It changes nothing.
2. **Adopt one.** Run it again with `ADOPT_POLICY` set too (several ids, space
   separated, are one tranche; `ADOPT_TRANCHE` names it). The job converts those
   policies and what they need, commits that to a branch
   `adopt/<site>-<tranche>`, and opens a merge request whose description is the
   converter's report, including what was left in the UI and why.
3. **Review and merge** that merge request as in steps 3 and 4 below: its
   pipeline plans it, and `plan-guard` fails it unless it only imports.

The job never applies, never pushes to the default branch, and never keeps the
capture (it lives in a temporary directory for the length of the job). It needs
`NSX_ADOPT_TOKEN`, a project access token with the `api` and `write_repository`
scopes, masked and protected; branch protection still keeps it off the default
branch. Steps 1 and 2 below are the same thing done by hand, for when you want to
iterate on a conversion offline.

## Mirror mode: the whole manager, kept in step, until you cut over

For a manager that engineers keep running from the UI while the repository and
Terraform's state catch up. Instead of choosing policies, the repository holds a
copy of **everything** the importer can represent, refreshed on a schedule, and
state follows it. Nothing is applied to NSX for that manager until you switch
it to managed. The other managers carry on as normal: their merge requests are
planned, merged and applied as usual.

**Turn it on, per manager**, with `mode: mirror` for that manager in
`inventory/managers.yaml`, in a merge request: entering and leaving mirror mode
is a reviewed change like any other. (There is no CI/CD variable for it; one
named `NSX_MODE_...` stops the pipeline and says so.)

From then on, for that manager:

- **no apply job.** On the default branch it gets an automatic `sync-state` job
  instead. That job applies its plan only if the plan just imports and refreshes
  (`plan-guard --observe`: any create, update, destroy or hand-back is refused),
  and only with the **read-only** plan credential, so it cannot write to NSX
  even by mistake. `scripts/tf.sh apply` holds anyone to the same rules.
  GitHub Actions leaves it out of the apply matrix.
- **its plans never hold up the other managers.** It changes in the UI between
  syncs, so on other merge requests and on the default branch its plan may fail,
  shown as a warning. In its own mirror merge request the plan must pass.

**Schedule the sync.** *Build → Pipeline schedules → New schedule*, on the
default branch, with the variable `MIRROR_SITE` = `all` (every manager in mirror
mode) or one manager's name, and `MIRROR_AUTO_MERGE` = `1` for state to follow
without anyone merging. Every few hours is typical. *Run pipeline* with the same
variables syncs on demand. The `mirror` job (`scripts/mirror.sh`):

1. reads each manager with the read-only plan credential;
2. rewrites that manager's mirror files from what it holds now:
   `data/groups/imported-<site>-mirror.yaml`, `data/services/imported-<site>-mirror.yaml`,
   `data/policies/<policy-id>.yaml` and `stacks/<stack>/import-<site>-mirror.tf`, each
   starting with the line `# nsx-mirror: <site>`. Objects added in the UI are
   added, edited ones follow, deleted ones are removed;
3. if that matches the default branch, does nothing (and closes a merge request
   still open for it); otherwise force-pushes the branch `mirror/<site>` and keeps
   **one** merge request for it up to date, listing what was added, changed and
   deleted. With `MIRROR_AUTO_MERGE=1` it merges itself when its pipeline passes.

Once merged, the default-branch pipeline's `sync-state` job brings state up to
date: new objects are imported, edited ones are refreshed, deleted ones leave
state. If an engineer changed the manager after the sync read it, the plan
differs from the copy; it is refused, nothing is pushed back onto NSX, and the
next sync brings the change in.

**Every UI change becomes an issue to investigate.** When a sync finds that
engineers changed the manager since the copy on the default branch, it also
raises a GitLab issue labelled `nsx-drift` and `site:<site>`. The issue lists
each object added, changed or deleted, what changed in it (`action ALLOW → DROP`,
`source_groups +App-Web`), and who last changed it and when, as NSX records them.
It also has a checklist: who made the change and why, keep it or revert it, and
whether it should have come through a merge request. That is the tracker for
the observation period: close each issue once its changes are explained. A
change is raised once, however many syncs see it; a further change to the same
object is raised again. The first copy of a manager is its baseline, not drift.
An object nobody touched in NSX since the last copy is not raised either, so
an importer upgrade that can take over more objects does not flood the tracker.
Filter the board on the `nsx-drift` label.

It needs `NSX_ADOPT_TOKEN`, as the adopt job. An unchanged manager rewrites the
same bytes, so a quiet manager produces no merge requests. Objects declared in any
other file (adopted by hand, or written by you) are left to that file and listed
as `MANAGED`; objects the importer cannot represent exactly stay in the UI and are
listed as `NOT ADOPTED`, as everywhere else. Do not edit the mirror files: the
next sync overwrites them.

**A Global Manager and its Local Managers.** Each object has exactly one owner in
`data/`, so exactly one stack manages it and the GM and an LM never fight over
it:

- The GM's copy is read from the global tree (`/global-infra`), in every domain:
  `default` (or the inventory's `domain`) first, then each location domain such
  as `WL-Mum`. Its objects are `owner: gm`; one outside `default` keeps its
  `domain:`, so it is created there and Local Managers find it under that
  domain. data/ names objects by id alone, so an id found in two domains is
  taken from the first and left in the UI in the other. A Local Manager also lists
  the GM's objects; its copy never takes them (`NOT ADOPTED ... belongs to the
  Global Manager`).
- A site-local rule that uses a global group or service names it, and the
  local-security stack resolves the name to its `/global-infra` path without
  managing it. If the GM's copy does not hold that object yet, the rule waits in
  the UI until the next sync after the GM's copy is merged.
- A local group or service whose id another manager already owns in `data/` is
  not taken, nor are the rules that use it, since the name would resolve to the
  other object. Rename one of them in NSX to bring it in.
- A policy with no rule left to take stays in the UI whole.

Two managers cannot both own an object with the same id (the data is keyed by
id): the second is listed as `NOT ADOPTED` and left in its UI. An object edited in
the UI into something the importer cannot represent leaves the copy but not
state, so its plan shows a destroy and is refused every time: hand it back
(below) to stop managing it.

**Cut over** when the team is ready to stop changing that manager by hand. The
imported copy is not a report: it becomes the configuration, and engineers
change it, and add to it, like anything they wrote themselves.

1. Agree a freeze on UI changes for that manager, and explain its open
   `nsx-drift` issues.
2. Run the sync (*Run pipeline*, `MIRROR_SITE` = the manager), merge its merge
   request, and let `sync-state` finish.
3. *Run pipeline* on the default branch with `CUTOVER_SITE` = the manager. The
   `cutover` job (`scripts/cutover.sh`):
   - reads the manager and stops if anything changed in the UI since the sync;
   - turns its copy into ordinary data files: the "do not edit" header goes,
     `imported-<site>-mirror.yaml` becomes `imported-<site>.yaml`, and the import
     blocks are deleted, since state already holds every object;
   - sets `mode: managed` in the inventory;
   - plans every stack of the manager with exactly that, and stops unless each
     plan changes nothing at all;
   - opens the merge request **Cut <site> over to managed**.
4. Merge it. That is the cutover. Nothing is applied: there is nothing to apply.

From then on, for that manager:

- **Change an imported object** by editing it in its file: a rule in
  `data/policies/<policy-id>.yaml`, a group in `data/groups/imported-<site>.yaml`.
  **Add** rules to an imported policy in the same file (`scripts/add-rule.py`),
  and new groups, services and policies in new files. The plan shows exactly
  that change, and it goes through review and change control like any other.
- Imported objects keep the ids NSX gave them (`_h-app01`, spaces and all); a
  new object you write follows the naming convention, which the validator
  enforces.
- **A change made in the UI is drift.** Schedule the `drift` job: *Build →
  Pipeline schedules*, on the default branch, with `DRIFT_SITE` = `all` (every
  manager in mode: managed) or one manager, every hour or so. It runs a
  refresh-only plan per manager and stack with the read-only credential,
  changes nothing, and raises each change as an `nsx-drift` issue, with who made
  it and when, as in mirror mode. Either bring the change into `data/` in a
  merge request, or the next apply puts NSX back to the repository.

## 1. Capture, read-only

```bash
scripts/with-credentials.sh lon1 -- scripts/import-estate.py --site lon1 \
    --dump-only reports/lon1-raw.json
```

A read-only snapshot of groups, services and policies. `reports/` is gitignored;
treat the dump like a plan file. Capturing once and converting offline means you
can iterate without touching the manager.

## 2. Convert one piece

```bash
make import SITE=lon1 DUMP=reports/lon1-raw.json POLICY="legacy-app"
```

`POLICY` takes one or more policy ids; `TRANCHE=<name>` names the piece of work
(default: the first policy). Only those policies are converted, with exactly what
they need: the groups they reference (nested groups followed through), and their
custom services. Anything already in `data/` is skipped: it is managed already.

| Written | Holds |
|---|---|
| `data/policies/<policy-id>.yaml` | the policy and its rules; new rules for it go here |
| `data/groups/imported-<site>-<tranche>.yaml` | the groups it needs |
| `data/services/imported-<site>-<tranche>.yaml` | its custom services, scoped to the site |
| `stacks/<stack>/import-<site>-<tranche>.tf` | the import blocks, for this site only |

Nothing you already have is overwritten: an existing target is written as
`<name>.new` for you to diff.

**What is not adopted, and stays in the UI.** The report lists each one and why.
Importing them would change them on the first apply, because Terraform clears
any setting it does not manage:

- groups with identity (AD) membership or other extended criteria, a group type
  other than "IP Addresses Only", or a condition whose key, member type or
  operator the schema does not list, or with a tag-scope operator other than
  equals (the provider cannot carry it); and groups that nest one of those;
- services with a nested-service entry, or an ALG entry with other than one
  destination port;
- rules with inline service entries, or that use one of the above. The rest of
  their policy is still adopted: Terraform manages rules one by one and leaves
  the others alone;
- a policy whose Apply To uses one of the above.

## 3. Read what it produced

```bash
make validate
```

- What is taken as it is, exactly as NSX holds it: tag, name and OS conditions,
  IP and MAC addresses, VMs picked one by one, "IP Addresses Only" groups,
  empty groups (with a `why_empty` placeholder), services of TCP/UDP, ICMP,
  IP protocol (GRE, ESP...), ALG, IGMP and EtherType entries, the services NSX
  ships with (`predefined_ids`, by id: display names are not unique), and
  rules with sequence number 0 or numbers NSX holds twice in one policy
  (`allow_duplicate_sequence`).
- Every group with static membership (IP addresses, or VMs picked one by one:
  `external_ids`, each VM's instance UUID) has a placeholder `why_static`.
  Replace it with the real reason. A VM rebuilt or restored as a new VM gets a
  new UUID and silently leaves such a group; a tag does not.
- A rule's source or destination may hold IP addresses, CIDRs and ranges as NSX
  does (`172.19.20.57`, `10.1.0.0/16`, `172.17.9.10-172.17.9.20`), next to group
  names. Not in an Apply To, which takes groups only.
- Tag scopes must be in `data/schema/tag-scopes.yaml`. Add the ones your estate
  uses deliberately; a typo there silently empties a group. In files adopted
  from NSX an unlisted scope is a warning (it is a fact of the estate); in
  files you write it is an error.
- A rule with an empty `scope` is pushed to every host in the span. The
  validator fails it: that is a finding about your estate, not a bug.
- Object keys are the real NSX ids, kept verbatim (mixed case included). The
  naming convention applies to objects you create from here on.

## 4. Plan, review, apply: a merge request per tranche

The tranche goes through the pipeline like any change. The plan must read:

```
Plan: N to import, 0 to add, 0 to change, 0 to destroy.
plan-guard lon1/local-security, import tranche (must be pure): N import, 0 create, 0 update, 0 destroy/replace
```

Anything else and the plan job fails, saying which objects and why:

| Refused | Meaning | Do |
|---|---|---|
| update | the data does not match the live object yet | fix the data to match NSX, re-plan. Never "fix" NSX to match the data during adoption |
| create | an object would be built a second time, or its import is missing | find the object's real id; add the import |
| `Cannot import non-existent remote object` | the import id is wrong; nothing was written to state | re-run the converter with `--id-format domain-id` or `id` |

There is no override for these during adoption, on purpose.

Apply from the default branch as usual. Then the next plan must report **no
changes**. Delete `stacks/<stack>/import-<site>-<tranche>.tf` in its own small
merge request: until you do, `plan-guard` keeps that stack in import-only mode
for that site and tells you so.

## 5. Next piece

Repeat 2 to 4. One policy, or one small related set, per merge request. Each
tranche is independent and can be stopped at any point; nothing half-adopted
affects traffic, because adoption never changes anything in NSX.

## Undo: hand an object back to the UI

To stop managing something without deleting it, for example to undo an
adoption or retire a rule from code while it keeps running:

```bash
make hand-back STACK=local-security \
  ADDRESS='module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["old-rule"]'
```

and, in the same merge request, remove it from `data/`. The plan says the object
"will no longer be managed by Terraform, but will not be destroyed", and nothing
else. Terraform refuses the plan if the object is still in `data/`, so the two
cannot get out of step. The resource address is the one shown in the plan or by
`terraform state list`.

## Deleting something on purpose

Remove it from `data/`, and add one line per object to `allow-destroy.txt` at the
repository root, in the same merge request:

```
# <site> <stack> <resource address>
lon1 local-security module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["old-rule"]
```

The refused plan prints these lines ready to paste. Remove them after the apply;
`plan-guard` reports lines that no longer match anything. Deleting a whole
policy also needs its `prevent_destroy` lifted in a reviewed commit.

## After the import: your data is yours

- `bootstrap.sh` will not overwrite estate data with `--force`, and refuses
  outright, even with `--force-data`, anything in `data/.import-manifest.json`.
- Drift detection is read-only: `scripts/drift.sh` writes a report and never
  writes back into `data/`. Drift is a ticket for a human.

## Adding a rule after importing

A new rule goes into the policy that already exists:

```bash
scripts/add-rule.py --policy legacy-app --rule allow-monitoring \
    --source prod-monitoring --destination legacy-web \
    --service https --scope legacy-web
```

It finds the policy by id or display name, appends to that file and allocates the
next free sequence number. Creating a new policy needs `--create-policy`, because
a new policy is a new category placement, a new ordering and a new blast radius.
SCAFFOLD_EOF

write_file README.md <<'SCAFFOLD_EOF'
# NSX Terraform

Terraform for NSX across a multi-VCF estate: one Global Manager owning the
federated distributed firewall, 10+ Local Managers owning their own networking,
and **firewall rules kept as reviewed data rather than as HCL edits or clicks in
the NSX UI**.

Generated by `scripts/bootstrap.sh`. See `docs/ARCHITECTURE.md` for the design
and the rules, and `docs/STRUCTURE.md` for what each directory holds.

## The idea in one screen

A day-to-day change is a YAML edit, reviewed like code and applied by the
pipeline:

```yaml
# data/policies/payments.yaml
rules:
  allow-web-to-app:
    sequence_number: 300
    source_groups: [prod-payments-web]
    destination_groups: [prod-payments-app]
    services: [https]
    scope: [prod-payments-app]     # mandatory: bounds where the rule is pushed
    action: ALLOW
```

Nobody writes that by hand either:

```bash
make add-rule POLICY=prod-payments RULE=allow-web-to-app \
  ARGS='--source prod-payments-web --destination prod-payments-app --service https --scope prod-payments-app'
make validate
make plan STACK=global-security SITE=gm1
```

Groups are selected by tag, so membership follows the workload instead of being
maintained by hand. Tags come either from your provisioning system or from
`data/vm-tags/` — `docs/TAGGING.md` covers the choice.

## Layout

| Path | Holds |
|---|---|
| `inventory/managers.yaml` | Every GM and LM. Adding a manager is a data change. |
| `data/` | Groups, policies, services, per-site network/platform, VM tags. |
| `data/schema/` | JSON Schema and the tag vocabulary. Enforced in CI. |
| `modules/` | One module per NSX object kind. `for_each`, never `count`. |
| `stacks/` | One root module per state boundary, run once per manager. |
| `scripts/` | Validation, CI matrix, credentials, import, rule and tag edits. |

Five stacks, split by change cadence and blast radius so a daily rule edit never
refreshes a transport zone:

| Stack | Runs on | Cadence | Blast radius |
|---|---|---|---|
| `global-security` | GM | daily | all sites |
| `local-security` | each LM | weekly | one site |
| `local-tags` | each LM | daily | the VMs listed |
| `local-network` | each LM | weekly | one site |
| `platform` | each LM | rarely | one site, total |

## Getting started

```bash
make preflight     # are the tools here
make selftest      # prove the generator and validators. Offline, ~1 minute.
make validate      # schema + convention checks. Offline, no credentials.
make ready         # what still stands between this and production
make matrix        # what CI would run, derived from the inventory
```

`make ready` is the honest one. A freshly generated tree is **not** production
ready and it will tell you exactly why — placeholder backend, example data, no
lock files, no remote — and exit non-zero until those are dealt with. It also
lists what it cannot see: branch protection, CI variables, and whether a plan
has ever run against a real manager.

Then, in order:

1. Replace `inventory/managers.yaml` — everything derives from it.
2. Add one `envs/<site>.backend.hcl` per manager.
3. **Decide the state backend.** The default is a placeholder `backend "local"`,
   which has no locking and is not acceptable for a real manager. Pick one with
   `scripts/bootstrap.sh --force --backend gitlab|s3|azure|local`, then fill in
   `envs/<site>.backend.hcl`.
4. `terraform init` in one stack and commit the `.terraform.lock.hcl`.
5. Adopt what already exists: `make import SITE=<site>`, per `docs/IMPORT.md`.

Everything under `data/` and `inventory/` ships as realistic example content
describing no real site. Replace it, or regenerate with `--no-examples`.

## Documentation

| Document | Read it for |
|---|---|
| `README.md` *(this file)* | What this repository does and how to start. |
| `docs/ARCHITECTURE.md` | The design and the operating rules, 16 sections — the reference. **§2 is the ten things that will break this repository.** |
| `docs/STRUCTURE.md` | What each directory is for, and what must *not* go in it. |
| `docs/TAGGING.md` | Who applies tags: the two variants, the ownership constraint, how the boundary is enforced. |
| `docs/IMPORT.md` | Adopting an estate that already exists — the tranche workflow. |
| `docs/SETUP.md` | Standing this up end to end: prerequisites, the decisions that are yours, backend choice, first contact with a manager. |
| `docs/GITOPS.md` | How a rule edit becomes a merge request, a plan, an approval and an apply — and what the approver is looking for. |
| `docs/ACCEPTANCE.md` | **What "it works" means and how to prove it** — the staged plan from offline checks to a real apply. Read before promising this to anyone. |
| `deploy/gitlab/README.md` | Running a local GitLab in Docker, if you do not have one. |
| `modules/*/README.md` | Input shape and gotchas, one per module. |
| `stacks/*/README.md` | Cadence, blast radius, approver, and what the stack consumes. |
| `inventory/README.md` | How the manager registry drives everything else. |

By question:

| You want to | Go to |
|---|---|
| Add a firewall rule | `docs/ARCHITECTURE.md` §8 and §10 |
| Avoid breaking a live firewall | `docs/ARCHITECTURE.md` §2 |
| Get changes reviewed before they apply | `docs/GITOPS.md` |
| Decide who tags workloads | `docs/TAGGING.md` |
| Adopt an existing estate | `docs/IMPORT.md` |
| Find a command | `docs/ARCHITECTURE.md` §16 — every command that exists |
| Know what is still undecided | `docs/ARCHITECTURE.md` §14 |

## Getting changes reviewed

A rule change should be a merge request, not an edit somebody made on a
Tuesday. The pipeline files are already here:

```
edit data/policies/*.yaml -> MR -> validate -> plan posted to the MR
   -> approver reads the PLAN -> merge -> MANUAL apply of the SAVED plan
```

The apply never re-plans; it applies the artifact the approver looked at.

If this tree has no remote yet:

```bash
scripts/enable-gitops.sh --remote git@gitlab.example.com:net/nsx.git
scripts/enable-gitops.sh --local-gitlab   # or stand GitLab up in Docker
```

`docs/GITOPS.md` covers the CI variables, the branch protection this depends on,
and what the approver is checking.

## Re-running the generator

`scripts/bootstrap.sh` is safe to re-run, and it is how you take updates. Run it
bare and it offers a menu — pick **Update an existing tree**, which keeps the
state backend this tree already uses, never re-seeds example data, and offers a
dry run first:

```bash
./scripts/bootstrap.sh
```

**With no flag it never overwrites anything that already exists.** A file whose
content differs is kept and reported, the run exits `2`, and files that are
missing are still added.

**Overwriting takes a flag *and* a typed phrase.** `--force` alone does not do
it: the first file that would be overwritten stops the run and asks for
`wipe everything & start fresh`, typed in full. Anything else aborts having
changed nothing.

| Command | Overwrites |
|---|---|
| *(no flag)* | nothing — differing files kept, exit 2 |
| `--force` | generator output only: modules, stacks, scripts, schemas, CI, docs |
| `--force-data` | the above **and** `data/`, `inventory/`, `envs/` |

It **never deletes**, and anything recorded in `data/.import-manifest.json` is
**never** overwritten — flag and phrase or not. Commit before a `--force` run:
git is the real undo.

## Before you touch a live manager

- No `terraform plan` in this repository has ever run against an NSX manager.
  Provider schema validity is not API validity.
- `scripts/tf.sh` refuses to apply without a saved plan and `APPROVE=yes`.
- State and saved plans carry the estate's full security posture. They are
  sensitive, and they never land in git.

Read `docs/ARCHITECTURE.md` section 2 — ten things that will break this
repository — before the first change.
SCAFFOLD_EOF

write_file docs/ACCEPTANCE.md <<'SCAFFOLD_EOF'
# What "it works" means, and how to prove it

`make selftest` proves the generator and the validators, offline, in about a
minute. It proves nothing about GitLab, Vault or NSX, because it never talks to
them.

This document is the rest: the stages that need real infrastructure, in the
order that keeps a mistake cheap. **Nothing below has been done yet.** Until
someone works through it, this repository is a well-tested scaffold, not a
deployment.

## First, about "single click"

It cannot be one click, and the honest reason is worth stating before anyone
promises it to a team.

A single command can create a repository, push it, configure a pipeline and
protect a branch. It cannot decide which state backend your organisation will
support, obtain a Vault path and a token, know which NSX manager is safe to
point at first, or accept the risk of the first apply. Those are decisions and
credentials, not steps.

What *is* achievable, and what to aim for:

- **One command to a reviewable pipeline.** `scripts/bootstrap.sh` with the
  GitLab flags creates the project, pushes, sets the variables and protects the
  branch. Reachable today; unproven until stage 2 below.
- **One merge request to a firewall change.** Edit a file, get a plan, approve,
  merge, apply. That is the actual product.

Say "one command to get started, one merge request per change". Do not say
"single click" — the first person to hit the Vault question will stop trusting
everything else you said.

---

## Stage 0 — offline, no infrastructure

```bash
make selftest      # generator, validators, pipeline shape, guards
make validate      # your data specifically
make ready         # what still blocks production
```

**Pass:** `selftest` exits 0. `ready` exits 1 and the reasons are all things you
have not done yet rather than things that are broken.

Cost: minutes. Do this on every change to the generator, and in CI.

---

## Stage 1 — a GitLab you can throw away

Prove the pipeline definition is one GitLab accepts, before it matters.

```bash
scripts/gitlab-up.sh                    # local GitLab in Docker, ~4 GB RAM
# or point at a sandbox project on a GitLab you already have:
scripts/gitlab-setup.sh --url https://gitlab.example.com \
                        --token glpat-xxxx --project sandbox/nsx-test
```

**Prove, in order:**

1. The project exists and the tree is in it.
2. `.gitlab-ci.yml` **lints** — Settings → CI/CD → Pipeline editor, or
   `POST /api/v4/projects/:id/ci/lint`. Valid YAML is not a valid pipeline;
   this is the first place the generated child pipeline can be rejected.
3. A pipeline runs on a push and the `validate` stage goes green with no
   credentials configured. This proves the offline half works on a runner.
4. The `matrix` job produces a child pipeline and the `managers` job triggers it.
   Plan jobs will **fail** here — there are no credentials yet. That is expected;
   what you are proving is that the jobs exist and are named per manager.
5. The default branch is protected and `VAULT_APPLY_TOKEN` is marked protected.

**Pass:** validate green, child pipeline generated and triggered, one plan job
per manager per stack, apply jobs present but manual and not startable from a
merge request.

**Fail here means:** the pipeline shape is wrong. Fix it before anyone points it
at a manager.

---

## Stage 2 — state backend, no NSX

Prove Terraform can hold state before it holds your firewall.

```bash
scripts/bootstrap.sh --force --backend gitlab   # or s3 / azure
# fill in envs/<site>.backend.hcl, then:
terraform -chdir=stacks/local-security init -backend-config=../../envs/lon1.backend.hcl
```

**Prove:**

1. `init` succeeds against the real backend.
2. A `.terraform.lock.hcl` is produced and **committed**.
3. **Locking works.** Start a plan, and while it runs start another against the
   same state. The second must block or fail, not proceed. This is the check
   nobody does and the one that corrupts state when it is missing.
4. State is encrypted at rest and readable only by the pipeline identity.

**Pass:** two concurrent runs cannot both hold the lock.

---

## Stage 3 — credentials

```bash
scripts/with-credentials.sh lon1 -- env | grep -c NSXT_
```

**Prove:**

1. It resolves the Vault path from the inventory and exports `NSXT_*`.
2. Nothing lands on disk: no file under the repository contains the secret
   after the command exits.
3. The plan token is **read-only** — confirm by trying a write against NSX with
   it and being refused. A token you assume is read-only is not read-only.

**Pass:** credentials reach the process, nothing reaches the disk, and the plan
identity cannot write.

---

## Stage 4 — a plan against a real NSX manager

The first stage where the product is actually being tested, and the first with
a blast radius. Use a **non-production Local Manager**.

```bash
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
scripts/tf.sh show local-security lon1
```

**Prove:**

1. `plan` completes. Provider schema validity is not API validity — this is
   where a wrong argument name, a wrong id format or a wrong domain shows up.
2. Against an estate you have **imported**, the plan reports **no changes**.
   Any *create* means an id did not match and Terraform is about to build a
   duplicate. Stop.
3. Against a greenfield site, the plan creates exactly what the data describes
   and nothing else.

**Pass:** an imported tranche plans clean. This is the single most important
line in this document.

---

## Stage 5 — the loop, end to end

On the non-production site, with a trivial change — one rule, one narrow scope.

1. Branch, edit one file in `data/policies/`, push, open a merge request.
2. **The plan appears as a comment on the merge request.** If it does not,
   `CI_API_TOKEN` is missing; the pipeline still works, the review is worse.
3. A second person approves. Confirm the author cannot approve their own.
4. Merge. The apply job appears and is **manual**.
5. Start it. It applies the **saved plan**, not a fresh one.
6. Confirm the rule exists in NSX and matches what the plan said.
7. Re-run the plan. It must report **no changes** — an apply that is not
   idempotent is an apply you cannot trust.
8. Revert the merge request and confirm the rule is removed.

**Pass:** steps 6, 7 and 8. Especially 7.

---

## Stage 6 — before an organisation consumes it

Technical correctness is not readiness for other people.

| Question | Who answers it |
|---|---|
| Who may approve a firewall change? | security owner |
| Who may start an apply, and out of hours? | change management |
| Where is state backed up, and how is it restored? | platform owner |
| What happens when CI is down and a change is urgent? | you — document it |
| Who is called when an apply half-fails? | on-call |
| Which site is the pilot, and when does it widen? | change advisory |

Also run once, deliberately:

- **A rollback.** Revert a merged change and apply the revert. Time it.
- **A broken apply.** Kill an apply mid-run and recover the state lock.
- **An onboarding.** Hand `docs/SETUP.md` to somebody who has not seen this
  and watch where they get stuck, without helping. Fix those places.

---

## The shortest honest summary

| Stage | Needs | Proves | Status |
|---|---|---|---|
| 0 | nothing | generator and validators | **done** — `make selftest`, 34 checks |
| 1 | any GitLab | the pipeline is one GitLab accepts | not started |
| 2 | a state backend | state is held and locked | not started |
| 3 | Vault | credentials flow, nothing on disk | not started |
| 4 | a non-prod NSX manager | plan matches reality | not started |
| 5 | all of the above | the review loop works end to end | not started |
| 6 | people | the organisation can run it | not started |

Stage 4 is the one that decides whether any of this is real. Everything before
it is preparation; everything after it is process.
SCAFFOLD_EOF

write_file docs/GITOPS.md <<'SCAFFOLD_EOF'
# A rule change is a merge request

The point of this repository is that nobody edits the firewall. They edit a
file, and a pipeline turns that into a plan somebody approves.

```
  engineer edits data/policies/payments.yaml
        |
        v
  push a branch, open a merge request
        |
        v
  VALIDATE   schemas and conventions. Offline, no credentials.
  PLAN       one job per manager, READ-ONLY credentials.
             The rendered plan is posted onto the merge request.
        |
        v
  APPROVER   reads the plan, not the YAML. Count delta, no unexpected
             destroys, scope set, default rule untouched. Approves.
        |
        v
  MERGE      to the default branch.
        |
        v
  APPLY      a MANUAL job on a protected environment, applying the SAVED
             plan artifact — never a fresh one.
```

The last step is the one that matters: **apply never re-plans.** It applies the
artifact the approver looked at. If the estate drifted in between, the apply
fails on a stale plan rather than quietly doing something nobody reviewed.

## What makes it safe

| Control | Enforced by |
|---|---|
| Nobody can push to the default branch | branch protection, on the git host |
| A change needs another person | merge request approval rules |
| Plans cannot write | a read-only plan credential: `VAULT_PLAN_TOKEN`, or the `NSX_PLAN_*` account |
| Only protected branches can write | the apply credential marked **protected**: `VAULT_APPLY_TOKEN` or `NSX_APPLY_*` |
| Nothing live is deleted by accident | `scripts/plan-guard.py` fails any plan that destroys or replaces an object not listed in `allow-destroy.txt` |
| Adoption never creates, edits or deletes | `scripts/plan-guard.py`: while an import tranche is open, the plan may only import |
| A plan is applied only to the manager it was made for | `scripts/tf.sh` records the manager with the saved plan and re-initialises per manager |
| Apply needs a human | manual job + protected environment |
| Apply cannot re-plan | `scripts/tf.sh apply` refuses without a saved plan and `APPROVE=yes` |
| Bad data never reaches a plan | `scripts/validate-data.py` in the validate stage |

Four of those live on the git host rather than in this repository. Setting them
is part of the job — a pipeline without branch protection is a pipeline that
anybody can bypass by pushing to the default branch.

## Which pipeline you get

Chosen at first run and recorded in `.nsx-bootstrap.conf`, so a later re-run
does not quietly change it.

| Choice | Written | Set up for you |
|---|---|---|
| **GitLab** *(default)* | `.gitlab-ci.yml`, the child-pipeline generator, an MR template | repository, runner, variables and gate, if you let it |
| GitHub | `.github/workflows/{validate,plan,apply}.yml`, a PR template | nothing — you set the secrets and protect the environments |
| Another git host | both of the above | nothing; point your host at whichever it reads |
| Local only | nothing | nothing — `make plan` / `make apply` by hand |

GitLab is the default because it is the only one this script can take all the
way: `scripts/gitlab-up.sh` will stand the server up, create the project, push,
register a runner and print the root password. For GitHub the workflows are
correct and complete, but the secrets and the environment protection are yours
to set, and nothing here can do it for you.

## Setting it up

**Writing the pipeline is not the same as having one.** The files are inert
until a GitLab project exists, the CI variables are set and the branch is
protected. `scripts/gitlab-setup.sh` does that part against any GitLab:

```bash
VAULT_ADDR=https://vault.example.com \
VAULT_PLAN_TOKEN=... VAULT_APPLY_TOKEN=... \
scripts/gitlab-setup.sh --url https://gitlab.example.com \
                        --token glpat-xxxx \
                        --project netops/nsx-terraform
```

It creates the project (and the group if needed), pushes, sets the four CI
variables with `VAULT_APPLY_TOKEN` marked **protected**, protects the default
branch against direct pushes, and creates one environment per manager/stack. Each
step is skipped if already done, so it is safe to re-run.

`scripts/gitlab-up.sh` calls the same script after starting its container, so
the Docker path and the bring-your-own-GitLab path configure a project
identically.

Two things it deliberately leaves alone:

- **Merge request approval rules.** Set at least one approver under
  Settings → Merge requests → Approvals.
- **Protected environments**, which are GitLab Premium. On Free the gate is the
  manual apply job plus the protected branch and protected token — weaker,
  because anyone who can run a pipeline on the default branch can start the
  apply. The script says so rather than implying the gate is stronger than it is.

Three ways in, all producing the same pipeline:

```bash
# 1. an existing repository
scripts/enable-gitops.sh --remote git@gitlab.example.com:net/nsx-terraform.git

# 2. no GitLab yet — stand one up in Docker
scripts/enable-gitops.sh --local-gitlab      # or scripts/gitlab-up.sh

# 3. at first run
scripts/bootstrap.sh                          # the menu asks
```

Nothing in the repository changes between them: `.gitlab-ci.yml`,
`.github/workflows/` and the helper scripts are always generated. Choosing later
costs nothing, which is why "local only, decide later" is a supported answer
rather than a trap.

### CI variables

| Variable | Value | Flags |
|---|---|---|
| `VAULT_ADDR` | Vault endpoint | masked |
| `VAULT_PLAN_TOKEN` | **read-only** token | masked |
| `VAULT_APPLY_TOKEN` | write token | masked, **protected** |
| `CI_API_TOKEN` | project token, `api` scope, so plans can be posted to the MR | masked |
| `NSX_APPLY_MODE` | `manual` (default), `auto`, or `approval` (change control, below) | optional |
| `NSX_BOT_TOKEN` | change control only: project access token, role **Maintainer**, `api` scope | masked, **protected** |
| `NSX_REQUIRED_APPROVALS` | change control only: approvals per change (default `2`) | optional |

Without Vault, put the NSX credentials in GitLab instead. The first complete
pair wins, where `<SITE>` is the manager key upper-cased (`hyd-gm01` is
`HYD_GM01`):

| Variable pair | Flags |
|---|---|
| `NSX_<SITE>_PLAN_USERNAME` / `_PASSWORD`, or `NSX_PLAN_...` for every manager | masked; a **read-only** NSX account |
| `NSX_<SITE>_APPLY_USERNAME` / `_PASSWORD`, or `NSX_APPLY_...` | masked, **protected** |
| `NSX_<SITE>_USERNAME` / `_PASSWORD`, or `NSX_USERNAME` / `_PASSWORD` | fallback for both; masked |

Plan jobs on a merge request cannot read protected variables, which is why plan
and apply have separate pairs. A masked value must be at least 8 characters
with no spaces. The state backend needs no variable: jobs use `CI_JOB_TOKEN`.

| Variable | Value | Flags |
|---|---|---|
| `NSX_CA_FILE_<SITE>` | PEM of the CA that signed **that** manager's certificate, or the certificate itself if self-signed. `hyd-gm01` is `NSX_CA_FILE_HYD_GM01` | type **File**; needed for an internal CA or a self-signed manager |
| `NSX_CA_FILE` | the same, for every manager without its own; several PEMs in one file trust all of them | type **File** |

A per-manager file wins, so where each manager has its own CA, each run trusts
only that one. Without either, Terraform rejects the certificate with `x509:
certificate signed by unknown authority`. The generated jobs trust GitLab's own
CA automatically.

A manager certificate with only a Common Name and no Subject Alternative Name is
rejected whatever you trust (`x509: certificate relies on legacy Common Name
field`). Check before you start, from any machine that reaches the manager:

```bash
openssl s_client -connect <manager>:443 -showcerts </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -ext subjectAltName
```

The SAN must list the name or address in `inventory/managers.yaml`; if it does
not, replace the certificate on the manager. Do not turn verification off.

Jobs reach managers directly, never through the internet proxy the runner may
have: `scripts/with-credentials.sh` adds the manager's host (and
`SDDC_MANAGER_HOST`) to `NO_PROXY`. A manager name sent to such a proxy fails
as `remote error: tls: unrecognized name`, a 403 or a 502. Only where managers
really are reached through a proxy, set the CI/CD variable
`NSX_MANAGER_VIA_PROXY=1`.

| Variable | Value | Flags |
|---|---|---|
| `NSX_ADOPT_TOKEN` | project access token, scopes `api` and `write_repository`, role Developer: lets the `adopt` job push an `adopt/*` branch and open a merge request | masked, **protected** |

**Read this before you rely on unprotected plan variables.** Anyone who can push
a branch or open a merge request can run pipeline code that reads every variable
that is not protected, and masking does not stop a deliberate leak. So the
`NSX_PLAN_*` account must be genuinely read-only in NSX (an auditor role, never
the account you apply with), and write access to the project should be limited
to people you would trust with that read access. Keep the write account in
`NSX_APPLY_*`, protected, and protect the default branch. Do not put the write
account in the shared `NSX_USERNAME` / `NSX_PASSWORD` fallback unless you mark
it protected as well, because an unprotected shared pair is also used by merge
request plans.

If `CI_API_TOKEN` is absent the pipeline still runs; it just does not comment,
and the approver reads the plan in the job log instead.

Credentials held in CI/CD variables (`NSX_PLAN_*`, `NSX_APPLY_*`, `NSX_CA_FILE*`)
are wired up for GitLab only. The generated GitHub workflow still takes them
from Vault; to use plain secrets there, add them to the job's `env:` yourself.

On GitHub the equivalents are repository secrets `VAULT_ADDR`,
`VAULT_PLAN_TOKEN` and `VAULT_APPLY_TOKEN`; the plan comment uses the built-in
`GITHUB_TOKEN` and needs nothing extra. The apply gate is
**Settings → Environments → `nsx-<site>-<stack>` → Required reviewers**, and
`VAULT_APPLY_TOKEN` should be scoped to those environments so a plan job can
never reach it.

## How the per-manager jobs appear

GitLab cannot build a job matrix from a file at parse time, so
`scripts/gitlab-child-pipeline.py` reads `inventory/managers.yaml` and emits the
jobs as a child pipeline. Adding an eleventh Local Manager stays a data change:
add it to the inventory, and its plan job appears on the next merge request.

GitHub Actions does the same thing with `scripts/ci-matrix.py --format github`.
Both read the same `scripts/ci_matrix_lib.py`, so the two platforms cannot drift
apart.

## Change control: two approvals before anything reaches NSX

GitLab Community Edition has no enforced approval rules and no deployment
approvals, so with `NSX_APPLY_MODE=approval` the pipeline enforces them itself
(`scripts/change-control.py`):

1. **Merge request.** Formatting, validation and the plans run on it. A
   Maintainer other than its author merges it, or another engineer approves it.
   Turn on *Settings → Merge requests → Pipelines must succeed*, and set
   *Settings → Repository → Protected branches* → `main` to **Allowed to
   merge: Maintainers**, **Allowed to push and merge: No one**.
2. **Change Request.** On the default branch every manager is planned, then
   the `change request` job opens an issue (label `nsx-change`) with what each
   plan changes in NSX, the merge requests in the change, their authors and who
   reviewed them, and the plans in full. Plans that change nothing open none.
   Every merge since the last applied change is checked: one that its author
   merged with no other approval, or a commit that reached `main` without a
   merge request, **blocks** the change request (label `nsx-blocked`, the
   pipeline fails), and nothing in it can be applied until that change is
   reverted or reviewed in a new merge request.
3. **Approvals.** Approvers give the issue a :thumbsup:. It needs
   `NSX_REQUIRED_APPROVALS` of them (default 2), each from a **Maintainer** or
   from an engineer standing in for one, and never from an author of a change
   in it. A stand-in and the Maintainer they stand in for count once between
   them.
4. **Apply.** The `approve and apply` job applies every manager's saved plan
   and records the result. A Maintainer can start it, or the approvals schedule
   starts it within minutes of the last approval. Either way it checks the
   approvals again first, so the button alone approves nothing. It is manual
   and non-blocking: the pipeline shows **passed** while the change waits.
5. **Record.** The result goes on the Change Request, which is closed (label
   `nsx-applied`), or left open marked `nsx-apply-failed` with the error. Each
   change also adds a line to the wiki page **NSX Change Log**: when, the change
   request, its merge requests, authors, reviewers, approvers and the result.

A newer change supersedes one still waiting (its plan already holds it); the
older issue is closed and its approvals do not carry over. Managers in mirror
mode are not change-controlled: their state follows NSX on its own.

**The approvals schedule.** *Build → Pipeline schedules → New schedule* on the
default branch, every 5–10 minutes, with the variable `APPROVAL_SWEEP` = `1`.
It only starts the apply of change requests that already have their approvals.

**Standby approvals.** When a Maintainer is away, they hand their approval to
another engineer for a set period in `inventory/delegations.yaml`, through a
merge request like any other change:

```yaml
delegations:
  - from: alice        # the Maintainer
    to: carol          # who approves in their place
    until: 2026-11-15  # the last day, UTC
    reason: annual leave
```

It counts only until `until`, never for a change the Maintainer authored, and
`make validate` questions one longer than a month.

**Setup**, once: set `NSX_APPLY_MODE=approval`; create a project access token
(*Settings → Access tokens*, role Maintainer, scope `api`) as `NSX_BOT_TOKEN`;
keep at least `NSX_REQUIRED_APPROVALS` Maintainers besides any author; create
the approvals schedule. GitLab only: GitHub Actions keeps its own environment
approvals.

## The approver's job

Read the **plan**, not the diff. The YAML says what somebody intended; the plan
says what Terraform will do.

- **Resource count delta matches the intent.** One rule added should not be
  fourteen resources changed.
- **No unexpected destroys.** The plan job already fails on any destroy not
  approved in `allow-destroy.txt`, so a destroy you see was asked for in this
  merge request: check that `allow-destroy.txt` names exactly the objects the
  change means to remove, and nothing else.
- **`scope` is set on everything new or changed.** An unscoped rule goes to every
  hypervisor in the span.
- **The default rule and the Emergency category are untouched**, unless that is
  explicitly what the change is for, in which case it is a restricted change and
  needs the change advisory (`docs/ARCHITECTURE.md` §11).

## Where this matches the standard flow, and where it does not

The shape is the usual one: feature branch, pull/merge request, CI runs fmt,
validate, data checks and plan, the plan is commented on the request, a reviewer
approves, it merges, and a CD pipeline applies on the default branch. Both
`.gitlab-ci.yml` and `.github/workflows/` implement all of that.

Two deliberate differences, both because this applies firewall rules across a
federated estate rather than creating a bucket:

**1. The apply is gated a second time, and defaults to waiting for a human.**

An approved merge request says *the change is wanted*. It does not say *this
plan, computed against the estate as it is right now, is what should be applied*.
Between approval and merge the estate can move. So merging queues the apply and
a person starts it, with the plan in front of them.

| | GitLab | GitHub |
|---|---|---|
| Gate | `when: manual` job | Environment required reviewers |
| Turn it off | `NSX_APPLY_MODE=auto` in CI/CD variables | leave the environment unprotected |

Setting it to apply on merge makes this exactly the standard diagram. That is
reasonable for a lab. On a production firewall it means a merge is the last
moment anybody sees what is about to happen.

**2. The apply does not re-plan.**

The common pattern re-runs `terraform plan` in the CD job and applies the result.
This applies the **saved plan artifact** the approver looked at. If the estate
drifted in between, the apply fails on a stale plan instead of quietly applying
something nobody reviewed. `scripts/tf.sh apply` enforces it: no saved plan, no
apply.

Everything else — fmt, validate, data schema checks, plan on every request, the
comment, the merge — is the diagram.

## Local only — the manual path

If you chose local files, there is no pipeline and no merge request. The
workflow is:

```bash
make validate                                    # schemas and conventions
make plan  STACK=local-security SITE=lon1        # writes a saved plan
make show  STACK=local-security SITE=lon1        # read it — this is the review
APPROVE=yes make apply STACK=local-security SITE=lon1
```

`scripts/tf.sh` still enforces what the pipeline relies on: no apply without a
saved plan, no apply without an explicit `APPROVE=yes`, and no apply through the
placeholder local backend. So the *shape* of the review survives even with
nobody to review it.

What is missing is the record. Nothing says who changed a rule, when, or why,
and the plan is read by the same person who wrote the change. For a lab that is
fine. For a production firewall it is the thing an audit will ask about first.

`scripts/enable-gitops.sh` adds all of it later, including writing the pipeline
files that were skipped. Nothing about the Terraform changes.

Even with a pipeline, this remains the incident path — a workstation apply when
CI is down. It leaves no record of who approved what, so it is the exception.
SCAFFOLD_EOF

write_file docs/TAGGING.md <<'SCAFFOLD_EOF'
# Tagging workloads without touching the NSX UI

Groups select workloads by tag. So the question "who applies the tag" decides
whether a firewall change is a reviewed data edit or a click nobody can audit.

This repository supports both answers. Picking the wrong one is expensive, so
read the constraint first.

## The constraint

`nsxt_policy_vm_tags` **has no per-tag ownership.** It replaces a VM's entire
tag set on every change, and removes every tag on the VM when the resource is
destroyed. There is no "manage only the tags I listed" mode, and none can be
built: the API call underneath sets the whole collection.

Two consequences follow, and everything else in this document is downstream of
them:

1. If any other system writes NSX tags on a VM that Terraform also manages, the
   two overwrite each other on every run. Terraform reports drift forever, and
   whichever ran last wins.
2. The data file must therefore always carry the **complete** tag set for a VM.
   A tag you delete from the file is a tag deleted from the VM.

## The two variants

### Variant A — another system tags, this repository consumes

The default, and the right answer for most VCF estates.

VM provisioning, vRA/VCF automation, or a CMDB sync writes the tags. This
repository never calls `nsxt_policy_vm_tags`; groups match on the tags with
dynamic criteria, and `data/vm-tags/` stays empty.

Choose this when any of the following is true — any one is decisive:

- VCF automation or vRA applies NSX tags as part of provisioning.
- A CMDB, ServiceNow sync, or vSphere tag sync writes them.
- The estate has more than a few hundred workloads to tag.

Scale is the second reason, independent of correctness: one resource per VM
across 10+ managers is tens of thousands of state entries and a refresh time
that makes daily changes impossible.

**Engineers still never open the NSX UI.** They tag in the provisioning system,
which is where a workload's identity is decided anyway. What this repository
owns is the vocabulary those tags must use — `data/schema/tag-scopes.yaml` — and
the group criteria that consume them.

### Variant B — this repository tags

For the estate where **nothing else writes NSX tags** and engineers have been
applying them by hand in the UI. That is the case this variant replaces.

```bash
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make validate
make plan STACK=local-tags SITE=lon1
```

The edit lands in `data/vm-tags/lon1.yaml`, goes through pull request review like
any other change, and applies through the pipeline. No UI, and a git history of
who tagged what and why.

Choose this when all of the following hold:

- No other system writes NSX tags on these VMs.
- The set is bounded — exception workloads, hand-built servers, appliances.
- You want the tag under change control.

### Mixing them

Per **VM**, not per tag. A VM is either Terraform-tagged or it is not; there is
no half. Splitting an estate so that some VMs are in `data/vm-tags/` and the rest
come from automation is fine and common. Splitting a single VM's tags between the
two is not possible.

## How the boundary is enforced

`data/schema/tag-scopes.yaml` records an `owner` for every scope: the system that
authoritatively writes it. `make validate` **errors** if `data/vm-tags/` writes a
scope owned by anything other than `terraform`:

```
ERROR data/vm-tags/lon1.yaml: vms.web-01.tags[0]: scope 'app' is owned by
      'cmdb-sync' in data/schema/tag-scopes.yaml, so Terraform must not write it.
```

To move a scope into variant B, change its `owner` to `terraform`. That is a
reviewed change, and the review question is exactly the right one: *are we sure
nothing else tags these VMs?*

`scripts/tag-vm.py` refuses the same thing up front, so you find out before
opening a pull request rather than in CI.

## Creating a tag

NSX has no standalone tag object. A tag exists because something is tagged with
it; there is nothing to create first and nothing left behind when the last
assignment goes away. So "create a tag" means two things here:

1. **Declare it** in `data/schema/tag-scopes.yaml` — the scope, what it means,
   who owns it, and optionally a closed list of values. This is the reviewed
   step, because a scope is an API contract: renaming one silently empties every
   group that matches it.
2. **Assign it** — from the provisioning system (variant A), or from
   `data/vm-tags/` (variant B). Segments are tagged inline in
   `data/network/<site>.yaml` and groups in `data/groups/`, both of which are
   Terraform-owned already and need no decision.

The vocabulary is checked on every assignment: an unknown scope is an error, and
a value outside a declared `values` list is an error. A typo cannot reach NSX
and silently empty a group.

## Identifying a VM

`external_id` is preferred over `display_name`:

| | `display_name` | `external_id` |
|---|---|---|
| Survives a vCenter rename | no | yes |
| Unique across vCenters | no | yes |
| Readable in review | yes | no |

A `display_name` that matches nothing fails at **plan** time — the module has a
precondition, so an unresolvable name never applies as an empty id. Names are
resolved through a single `nsxt_policy_vms` inventory read per plan, not one API
call per VM.

Keep the logical key readable and put the id underneath:

```yaml
vms:
  payments-web-01:
    external_id: 502f1a2b-...
    description: Hand-built, not in the CMDB.
    tags:
      - { scope: workload, tag: payments-web }
```

## Quarantine

`quarantine` is `owner: terraform` so that isolating a workload is a reviewed
data edit rather than a click. But incident response must not depend on a
healthy pipeline: apply the tag by hand in an emergency, then reconcile the data
file afterwards. The Emergency-category policy that acts on the tag is standing
configuration and does not change during an incident — see
`docs/ARCHITECTURE.md` section 11.

## What this repository will not do

**Merge with the tags already on the VM.** Reading current tags and unioning them
into the desired set would make removal impossible and produce a permanent diff.
A tag that cannot be removed is worse than one that was never managed. If that
sounds like what you need, you want variant A.
SCAFFOLD_EOF

write_file docs/STRUCTURE.md <<'SCAFFOLD_EOF'
# Repository structure

Generated by `scripts/bootstrap.sh`. This describes what each directory is for
and, more importantly, what must *not* go in it.

```
inventory/managers.yaml    Single registry of every GM and LM. Adding a manager
                           is a data change here — never a code change.
data/
  groups/                  Group definitions (dynamic criteria and static).
  policies/                DFW policies and their rules, one file per app.
  services/                Reusable service definitions and predefined aliases.
  network/                 Per-site segments and T1 gateways.
  platform/                Per-site T0, transport zones, edge clusters.
  vm-tags/                 Per-site VM tag assignments. Terraform owns the whole
                           tag set of every VM listed — read docs/TAGGING.md.
  schema/                  JSON Schema + the tag scope vocabulary. Enforced in CI.
modules/
  dfw-policy/              Parent policy + standalone rules, built from data.
  group/                   Groups with tag criteria or static membership.
  service/                 Custom L4/ICMP services.
  segment/                 Segments (Terraform-owned, so segment tags live here).
  vm-tags/                 VM tags, for VMs nothing else tags.
  tier1/                   T1 gateways.
  tier0/                   T0 gateways.
stacks/
  global-security/         GM: federated DFW. One state for the federation.
  local-security/          Per-LM: site-local DFW exceptions. One state per LM.
  local-tags/              Per-LM: VM tags. One state per LM.
  local-network/           Per-LM: segments, T1s. One state per LM.
  platform/                Per-LM: T0, transport zones, edge clusters.
envs/<site>.backend.hcl    Partial backend config, one file per manager.
scripts/                   Bootstrap, validation, CI matrix, credential handling,
                           estate import, rule and tag edits, GitOps setup.
deploy/gitlab/             A local GitLab in Docker, for teams without one.
                           Not a production deployment.
.gitlab-ci.yml             MR -> validate -> plan -> approve -> merge -> apply.
.github/workflows/         The same flow on GitHub Actions.
```

## Why the split

State boundaries follow change cadence and blast radius, not topology. A daily
DFW rule edit must never force Terraform to refresh transport zones.

| Stack | Cadence | Blast radius | Approver |
|---|---|---|---|
| `global-security` | daily | all sites | security review |
| `local-security` | weekly | one site | site owner |
| `local-tags` | daily | the VMs listed | site owner |
| `local-network` | weekly | one site | network owner |
| `platform` | rarely | one site, total | change advisory |

`local-tags` is separate from `local-security` for the same reason: tagging
churns daily, and sharing a state would mean every tag edit refreshes every
policy. Nothing depends on it in Terraform — NSX evaluates dynamic group
membership server-side, so a tag lands and membership follows.

## Adding a manager

1. Add an entry to `inventory/managers.yaml`.
2. Add `envs/<id>.backend.hcl` (copy `envs/example.backend.hcl.example`).
3. Nothing else. CI derives its matrix from the inventory.

## Adding a rule

Edit one file under `data/policies/`. No HCL changes. `make validate` then a PR.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 3. Schemas and the tag vocabulary
# ---------------------------------------------------------------------------

write_file data/schema/tag-scopes.yaml <<'SCAFFOLD_EOF'
# Closed vocabulary of NSX tag scopes.
#
# A tag scope is an API contract between whatever system tags workloads and the
# group criteria in this repository. Renaming a scope silently empties every
# group that matches it, which silently drops traffic — that is a RESTRICTED
# change (docs/ARCHITECTURE.md section 11), not a routine one.
#
# Adding a scope is a reviewed change. Removing or renaming one requires proving
# that no group criteria reference it:
#   grep -R "<scope>|" data/groups/
#
# scopes:
#   <scope>:
#     description: what the scope means
#     owner:       the system that authoritatively writes this tag
#     values:      optional closed list; omit for free-form values
#     applies_to:  VirtualMachine | Segment | ... (member types that carry it)
#
# owner is load-bearing, not a comment. 'owner: terraform' is the one value that
# lets data/vm-tags/ write the scope, because nsxt_policy_vm_tags replaces a
# VM's ENTIRE tag set — writing a scope another system owns means the two
# overwrite each other forever (docs/ARCHITECTURE.md section 7). Moving a scope
# to terraform is a reviewed change: you are declaring that nothing else tags
# those VMs.

scopes:
  env:
    description: Deployment environment.
    owner: vcf-automation
    applies_to: [VirtualMachine, Segment]
    values: [prod, preprod, nonprod, dev]
  app:
    description: Application identity.
    owner: cmdb-sync
    applies_to: [VirtualMachine, Segment]
  tier:
    description: Role of the workload within its application.
    owner: cmdb-sync
    applies_to: [VirtualMachine]
    values: [web, app, db, mgmt]
  zone:
    description: Trust zone.
    owner: network-team
    applies_to: [VirtualMachine, Segment]
    values: [dmz, internal, restricted]
  owner:
    description: Accountable team.
    owner: cmdb-sync
    applies_to: [VirtualMachine, Segment]
  compliance:
    description: Regulatory scope.
    owner: grc-sync
    applies_to: [VirtualMachine]
    values: [pci, sox, none]
  quarantine:
    description: >
      Incident response, via the Emergency-category mechanism in
      docs/ARCHITECTURE.md section 11. Terraform-owned so that isolating a
      workload is a reviewed data edit rather than a click in the NSX UI — but
      the tag can always be applied by hand first and reconciled afterwards,
      because incident response must not depend on a healthy pipeline.
    owner: terraform
    applies_to: [VirtualMachine]
    values: [active]
  workload:
    description: >
      Workload identity for VMs this repository tags itself, in estates where no
      CMDB or VCF automation writes NSX tags. Terraform owns the COMPLETE tag set
      of every VM listed in data/vm-tags/ — see docs/TAGGING.md before adding to
      this scope.
    owner: terraform
    applies_to: [VirtualMachine]
SCAFFOLD_EOF

write_file data/schema/managers.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/managers.json",
  "title": "Manager inventory",
  "type": "object",
  "required": ["managers"],
  "additionalProperties": false,
  "properties": {
    "managers": {
      "type": "object",
      "minProperties": 1,
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["role", "host", "site", "vcf_instance", "vault_path", "tier"],
        "additionalProperties": false,
        "properties": {
          "role": { "enum": ["gm", "lm"] },
          "host": { "type": "string", "minLength": 1 },
          "site": { "type": "string", "minLength": 1 },
          "region": { "type": "string" },
          "vcf_instance": { "type": "string", "minLength": 1 },
          "sddc_manager": { "type": "string" },
          "vault_path": {
            "type": "string",
            "minLength": 1,
            "description": "Path only. Never the secret itself."
          },
          "tier": { "enum": ["prod", "preprod", "nonprod", "lab"] },
          "domain": { "type": "string" },
          "standby_for": { "type": "string" },
          "enabled": { "type": "boolean" },
          "mode": {
            "enum": ["managed", "mirror"],
            "description": "managed (the default): the pipeline plans and applies. mirror: scripts/mirror.sh keeps data/ a copy of the manager, and only its state is updated (imports and refreshes, read-only); nothing is applied to NSX. docs/IMPORT.md."
          },
          "stacks": {
            "type": "array",
            "items": {
              "enum": ["global-security", "local-security", "local-network", "platform", "local-tags"]
            }
          },
          "description": { "type": "string" }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/group.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/group.json",
  "title": "Group definitions",
  "type": "object",
  "required": ["groups"],
  "additionalProperties": false,
  "properties": {
    "groups": {
      "type": "object",
      "propertyNames": { "pattern": "^[^/]{1,255}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "owner"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "owner": {
            "enum": ["gm", "lm"],
            "description": "gm: created on the Global Manager, usable by GM policies. lm: site-local."
          },
          "domain": { "type": "string" },
          "sites": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Required for owner=lm. Site ids from inventory/managers.yaml."
          },
          "why_static": {
            "type": "string",
            "description": "Required when the group has static membership. Explain what would let it become dynamic."
          },
          "why_empty": {
            "type": "string",
            "minLength": 1,
            "description": "A group with no criteria matches nothing; only with this note saying why it exists."
          },
          "group_type": {
            "enum": ["IPAddress"],
            "description": "IPAddress: an 'IP Addresses Only' group (IP addresses and nested groups of the same type)."
          },
          "conjunction": { "enum": ["AND", "OR"] },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          },
          "criteria": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "conditions": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["key", "member_type", "operator", "value"],
                    "additionalProperties": false,
                    "properties": {
                      "key": {
                        "enum": ["Tag", "Name", "OSName", "ComputerName", "NodeType", "GroupType"]
                      },
                      "member_type": {
                        "enum": [
                          "VirtualMachine", "Segment", "SegmentPort", "LogicalPort",
                          "LogicalSwitch", "IPSet", "IPAddress", "Group", "DVPG",
                          "DVPort", "TransportNode", "BareMetalServer"
                        ]
                      },
                      "operator": {
                        "enum": [
                          "EQUALS", "NOTEQUALS", "CONTAINS", "STARTSWITH",
                          "ENDSWITH", "IN", "NOTIN", "MATCHES"
                        ]
                      },
                      "value": { "type": "string", "minLength": 1 }
                    }
                  }
                },
                "ip_addresses": {
                  "type": "array",
                  "items": { "type": "string" }
                },
                "mac_addresses": {
                  "type": "array",
                  "minItems": 1,
                  "items": { "type": "string" }
                },
                "external_ids": {
                  "type": "array",
                  "minItems": 1,
                  "items": { "type": "string", "minLength": 1 },
                  "description": "Static members by external id (a VM's instance UUID); needs member_type and why_static."
                },
                "member_type": {
                  "enum": ["VirtualMachine", "VirtualNetworkInterface", "CloudNativeServiceInstance", "PhysicalServer"],
                  "description": "What external_ids name."
                },
                "member_groups": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "Logical group names, resolved to paths by the module."
                }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/policy.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/policy.json",
  "title": "DFW policy and rules",
  "type": "object",
  "required": ["policy", "rules"],
  "additionalProperties": false,
  "properties": {
    "policy": {
      "type": "object",
      "required": ["id", "name", "category", "owner", "scope", "rule_management"],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[^/]{1,255}$",
          "description": "Deterministic nsx_id, adopted verbatim when imported. Never changes; renaming display_name stays metadata-only."
        },
        "name": { "type": "string", "minLength": 1 },
        "description": { "type": "string" },
        "category": {
          "enum": ["Ethernet", "Emergency", "Infrastructure", "Environment", "Application"]
        },
        "owner": { "enum": ["gm", "lm"] },
        "domain": { "type": "string" },
        "sites": { "type": "array", "items": { "type": "string" } },
        "sequence_number": { "type": "integer", "minimum": 0 },
        "stateful": { "type": "boolean" },
        "tcp_strict": { "type": "boolean" },
        "allow_duplicate_sequence": {
          "type": "boolean",
          "description": "Set by the importer when NSX holds rules of this policy with equal sequence numbers; they are kept as they are."
        },
        "locked": { "type": "boolean" },
        "comments": { "type": "string" },
        "tags": { "type": "array", "items": { "type": "object", "required": ["scope", "tag"], "additionalProperties": false, "properties": { "scope": { "type": "string" }, "tag": { "type": "string" } } } },
        "scope": {
          "type": "array",
          "minItems": 1,
          "items": { "type": "string" },
          "description": "Mandatory Apply To. Logical group names."
        },
        "rule_management": {
          "enum": ["standalone", "inline"],
          "description": "Never both on one policy — the provider forbids it."
        }
      }
    },
    "rules": {
      "type": "object",
      "minProperties": 1,
      "propertyNames": { "pattern": "^[^/]{1,255}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["sequence_number", "action", "direction", "scope"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "description": { "type": "string" },
          "sequence_number": { "type": "integer", "minimum": 0 },
          "action": { "enum": ["ALLOW", "DROP", "REJECT", "JUMP_TO_APPLICATION"] },
          "direction": { "enum": ["IN", "OUT", "IN_OUT"] },
          "ip_version": { "enum": ["IPV4", "IPV6", "IPV4_IPV6"] },
          "disabled": { "type": "boolean" },
          "logged": { "type": "boolean" },
          "notes": { "type": "string" },
          "log_label": { "type": "string" },
          "profiles": { "type": "array", "items": { "type": "string" } },
          "tags": { "type": "array", "items": { "type": "object", "required": ["scope", "tag"], "additionalProperties": false, "properties": { "scope": { "type": "string" }, "tag": { "type": "string" } } } },
          "source_groups": { "type": "array", "items": { "type": "string" } },
          "destination_groups": { "type": "array", "items": { "type": "string" } },
          "sources_excluded": { "type": "boolean" },
          "destinations_excluded": { "type": "boolean" },
          "services": { "type": "array", "items": { "type": "string" } },
          "scope": {
            "type": "array",
            "minItems": 1,
            "items": { "type": "string" },
            "description": "Mandatory. An unscoped rule is pushed to every host in the span."
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/service.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/service.json",
  "title": "Service definitions",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "predefined": {
      "type": "object",
      "propertyNames": { "pattern": "^[^/]{1,255}$" },
      "additionalProperties": {
        "type": "string",
        "description": "display_name of a service that already exists in NSX; looked up, not created."
      }
    },
    "predefined_ids": {
      "type": "object",
      "propertyNames": { "pattern": "^[^/]{1,255}$" },
      "additionalProperties": {
        "type": "string",
        "description": "A service NSX ships with, by its id (the key); the value is its display name, for the reader. Used by its path on the manager, never looked up by name."
      }
    },
    "custom": {
      "type": "object",
      "propertyNames": { "pattern": "^[^/]{1,255}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "owner": { "enum": ["gm", "lm"] },
          "sites": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Required for owner=lm: the Local Managers it is created on, or [\"*\"] for all."
          },
          "l4_port_set": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["protocol", "destination_ports"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "protocol": { "enum": ["TCP", "UDP"] },
                "destination_ports": { "type": "array", "items": { "type": "string" } },
                "source_ports": { "type": "array", "items": { "type": "string" } }
              }
            }
          },
          "icmp": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["protocol"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "protocol": { "enum": ["ICMPv4", "ICMPv6"] },
                "icmp_type": { "type": "string" },
                "icmp_code": { "type": "string" }
              }
            }
          },
          "ip_protocol": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["protocol"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "protocol": { "type": "integer", "minimum": 0 }
              }
            }
          },
          "algorithm": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["algorithm", "destination_port"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "algorithm": { "enum": ["ORACLE_TNS", "FTP", "SUN_RPC_TCP", "SUN_RPC_UDP", "MS_RPC_TCP", "MS_RPC_UDP", "NBNS_BROADCAST", "NBDG_BROADCAST", "TFTP"] },
                "destination_port": { "type": "string" },
                "source_ports": { "type": "array", "items": { "type": "string" } }
              }
            }
          },
          "igmp": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": { "display_name": { "type": "string" } }
            }
          },
          "ether_type": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["ether_type"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "ether_type": { "type": "integer", "minimum": 0 }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/vm-tags.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/vm-tags.json",
  "title": "VM tag assignments for one site",
  "description": "nsxt_policy_vm_tags replaces a VM's entire tag set, so the tags listed here are the complete and authoritative set for each VM.",
  "type": "object",
  "required": ["site", "sole_tagger", "vms"],
  "additionalProperties": false,
  "properties": {
    "site": {
      "type": "string",
      "minLength": 1,
      "description": "Must match the filename and a key in inventory/managers.yaml."
    },
    "sole_tagger": {
      "type": "string",
      "minLength": 20,
      "description": "Why no other system tags these VMs. Terraform takes the whole tag set; if VCF automation or a CMDB also writes it, the two overwrite each other forever."
    },
    "vms": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,253}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["tags"],
        "additionalProperties": false,
        "properties": {
          "display_name": {
            "type": "string",
            "minLength": 1,
            "description": "vCenter VM name, resolved to an external id at plan time. Convenient, but not unique across vCenters — prefer external_id in production."
          },
          "external_id": {
            "type": "string",
            "minLength": 1,
            "description": "The VM's NSX external id. Stable across renames and unambiguous; this is what the resource actually keys on."
          },
          "description": { "type": "string" },
          "tags": {
            "type": "array",
            "minItems": 1,
            "description": "The COMPLETE tag set for this VM. Anything not listed is removed on apply.",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string", "minLength": 1 },
                "tag": { "type": "string", "minLength": 1 }
              }
            }
          },
          "ports": {
            "type": "array",
            "description": "Optional per-segment-port tags for this VM's interfaces.",
            "items": {
              "type": "object",
              "required": ["segment", "tags"],
              "additionalProperties": false,
              "properties": {
                "segment": {
                  "type": "string",
                  "minLength": 1,
                  "description": "Logical segment name from data/network/<site>.yaml."
                },
                "tags": {
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "type": "object",
                    "required": ["scope", "tag"],
                    "additionalProperties": false,
                    "properties": {
                      "scope": { "type": "string", "minLength": 1 },
                      "tag": { "type": "string", "minLength": 1 }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/network.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/network.json",
  "title": "Per-site segments and tier-1 gateways",
  "type": "object",
  "required": ["site"],
  "additionalProperties": false,
  "properties": {
    "site": { "type": "string", "minLength": 1 },
    "tier1s": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "tier0_display_name": { "type": "string" },
          "edge_cluster_display_name": { "type": "string" },
          "failover_mode": { "enum": ["PREEMPTIVE", "NON_PREEMPTIVE"] },
          "route_advertisement_types": { "type": "array", "items": { "type": "string" } },
          "enable_standby_relocation": { "type": "boolean" },
          "pool_allocation": { "type": "string" },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    },
    "segments": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "transport_zone_display_name", "tags"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "tier1": { "type": "string", "description": "Logical tier1 key from this file." },
          "transport_zone_display_name": { "type": "string", "minLength": 1 },
          "vlan_ids": { "type": "array", "items": { "type": "string" } },
          "domain_name": { "type": "string" },
          "subnets": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["cidr"],
              "additionalProperties": false,
              "properties": {
                "cidr": { "type": "string", "minLength": 1 },
                "dhcp_ranges": { "type": "array", "items": { "type": "string" } }
              }
            }
          },
          "tags": {
            "type": "array",
            "minItems": 1,
            "description": "Segments are Terraform-owned, so their tags live here and drive subnet-based group membership.",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/platform.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/platform.json",
  "title": "Per-site platform objects (RESTRICTED — docs/ARCHITECTURE.md section 11)",
  "type": "object",
  "required": ["site"],
  "additionalProperties": false,
  "properties": {
    "site": { "type": "string", "minLength": 1 },
    "tier0s": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "edge_cluster_display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "ha_mode": { "enum": ["ACTIVE_ACTIVE", "ACTIVE_STANDBY"] },
          "failover_mode": { "enum": ["PREEMPTIVE", "NON_PREEMPTIVE"] },
          "transit_subnets": { "type": "array", "items": { "type": "string" } },
          "edge_cluster_display_name": { "type": "string", "minLength": 1 },
          "bgp": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "enabled": { "type": "boolean" },
              "local_as_num": { "type": "string" },
              "ecmp": { "type": "boolean" },
              "inter_sr_ibgp": { "type": "boolean" },
              "graceful_restart_mode": { "type": "string" }
            }
          },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 4. Modules
# ---------------------------------------------------------------------------

for m in dfw-policy group service segment tier1 tier0 vm-tags; do
	write_file "modules/$m/versions.tf" <<'SCAFFOLD_EOF'
terraform {
  required_version = ">= 1.9"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.9"
    }
  }
}
SCAFFOLD_EOF
done

# --- modules/group ---------------------------------------------------------

write_file modules/group/variables.tf <<'SCAFFOLD_EOF'
variable "groups" {
  description = <<-EOT
    Map of group definitions keyed by stable logical name. The key is the
    Terraform address and the nsx_id — renaming it destroys and recreates the
    group, which drops it out of every policy that references it. Never rename.
  EOT
  type        = any

  validation {
    condition     = alltrue([for k, v in var.groups : can(v.display_name)])
    error_message = "Every group needs a display_name."
  }
}

variable "domain" {
  description = "Default NSX domain. On a Global Manager this is a domain id or a site id; set it explicitly, an accidental 'default' has estate-wide span."
  type        = string
}

variable "group_paths" {
  description = "Paths of groups defined elsewhere, for nested group membership. Logical name => policy path."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/group/main.tf <<'SCAFFOLD_EOF'
# Groups, built from data. Membership is dynamic wherever it can be: tags are
# written by the system that owns the workload, and this repository only
# consumes them (docs/ARCHITECTURE.md section 7).

locals {
  # Nested group references arrive as logical names and are resolved to policy
  # paths from var.group_paths, so no data file ever contains a raw /infra/...
  # path. A name nothing supplies is a plan-time error, not an API rejection.
  unresolved_member_groups = {
    for k, g in var.groups : k => sort(tolist(setsubtract(
      toset(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])),
      toset(keys(var.group_paths)),
    )))
  }
}

resource "nsxt_policy_group" "this" {
  for_each = var.groups

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)
  domain       = try(each.value.domain, var.domain)
  group_type   = try(each.value.group_type, null)

  dynamic "criteria" {
    for_each = try(each.value.criteria, [])

    content {
      dynamic "condition" {
        for_each = try(criteria.value.conditions, [])

        content {
          key         = condition.value.key
          member_type = condition.value.member_type
          operator    = condition.value.operator
          value       = condition.value.value
        }
      }

      dynamic "ipaddress_expression" {
        for_each = length(try(criteria.value.ip_addresses, [])) > 0 ? [1] : []

        content {
          ip_addresses = criteria.value.ip_addresses
        }
      }

      dynamic "macaddress_expression" {
        for_each = length(try(criteria.value.mac_addresses, [])) > 0 ? [1] : []

        content {
          mac_addresses = criteria.value.mac_addresses
        }
      }

      dynamic "external_id_expression" {
        for_each = length(try(criteria.value.external_ids, [])) > 0 ? [1] : []

        content {
          member_type  = criteria.value.member_type
          external_ids = criteria.value.external_ids
        }
      }

      dynamic "path_expression" {
        for_each = length(try(criteria.value.member_groups, [])) > 0 ? [1] : []

        content {
          member_paths = [
            for name in criteria.value.member_groups : lookup(var.group_paths, name, name)
          ]
        }
      }
    }
  }

  # The provider pairs criteria[i] with conjunction[i] in order, so one
  # conjunction is needed between every adjacent pair of criteria blocks.
  dynamic "conjunction" {
    for_each = range(max(length(try(each.value.criteria, [])) - 1, 0))

    content {
      operator = try(each.value.conjunction, "OR")
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  lifecycle {
    precondition {
      condition     = length(try(each.value.criteria, [])) > 0 || try(each.value.why_empty, "") != ""
      error_message = "Group ${each.key} has no criteria. A group with no membership matches nothing and silently drops traffic; give it criteria, or a why_empty note saying why it exists."
    }

    precondition {
      condition     = length(local.unresolved_member_groups[each.key]) == 0
      error_message = "Group ${each.key} nests undefined group(s): ${join(", ", local.unresolved_member_groups[each.key])}."
    }
  }
}
SCAFFOLD_EOF

write_file modules/group/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical group name => NSX policy path. Feed this to the dfw-policy module so data files can reference groups by name."
  value       = { for k, g in nsxt_policy_group.this : k => g.path }
}

output "ids" {
  description = "Logical group name => nsx_id."
  value       = { for k, g in nsxt_policy_group.this : k => g.nsx_id }
}
SCAFFOLD_EOF

write_file modules/group/README.md <<'SCAFFOLD_EOF'
# module: group

Creates NSX policy groups from data. Keyed by `for_each` over a map with stable
string keys — never `count`.

## Input shape

```yaml
prod-payments-web:
  display_name: prod-payments-web
  owner: gm
  conjunction: AND          # joins adjacent criteria blocks; default OR
  criteria:
    - conditions:
        - key: Tag
          member_type: VirtualMachine
          operator: EQUALS
          value: "app|payments"   # scope|value
        - key: Tag
          member_type: VirtualMachine
          operator: EQUALS
          value: "tier|web"
```

Conditions inside one `criteria` block are ANDed by NSX. Separate `criteria`
blocks are joined by `conjunction`.

## Notes

- `nsx_id` is the map key, so a `display_name` change is metadata-only rather
  than a destroy-and-recreate.
- Prefer `EQUALS` over `CONTAINS`/`STARTSWITH`: `app|payments` must not also
  match `app|payments-test`.
- For subnet-based membership match `member_type: Segment` against a segment
  tag instead of hardcoding a CIDR. Segments are Terraform-owned, so their tags
  are reliable and a CIDR here would be a duplicated fact.
- Static membership (`ip_addresses`, `external_ids`, `member_groups`) requires
  `why_static` in the data file; CI enforces it.
- `external_ids` names members one by one, as the UI's "Members" tab does for
  virtual machines: `member_type: VirtualMachine` and each VM's instance UUID.
  A rebuilt VM gets a new UUID and silently leaves the group.
SCAFFOLD_EOF

# --- modules/service -------------------------------------------------------

write_file modules/service/variables.tf <<'SCAFFOLD_EOF'
variable "services" {
  description = "Map of custom service definitions keyed by stable logical name."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/service/main.tf <<'SCAFFOLD_EOF'
# Custom services. Anything NSX ships with is looked up as a data source in the
# stack instead of being recreated here.

resource "nsxt_policy_service" "this" {
  for_each = var.services

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  dynamic "l4_port_set_entry" {
    for_each = try(each.value.l4_port_set, [])

    content {
      display_name      = try(l4_port_set_entry.value.display_name, "${each.key}-${l4_port_set_entry.key}")
      protocol          = l4_port_set_entry.value.protocol
      destination_ports = l4_port_set_entry.value.destination_ports
      source_ports      = try(l4_port_set_entry.value.source_ports, null)
    }
  }

  dynamic "icmp_entry" {
    for_each = try(each.value.icmp, [])

    content {
      display_name = try(icmp_entry.value.display_name, "${each.key}-icmp-${icmp_entry.key}")
      protocol     = icmp_entry.value.protocol
      icmp_type    = try(icmp_entry.value.icmp_type, null)
      icmp_code    = try(icmp_entry.value.icmp_code, null)
    }
  }

  dynamic "ip_protocol_entry" {
    for_each = try(each.value.ip_protocol, [])

    content {
      display_name = try(ip_protocol_entry.value.display_name, "${each.key}-ip-${ip_protocol_entry.key}")
      protocol     = ip_protocol_entry.value.protocol
    }
  }

  dynamic "algorithm_entry" {
    for_each = try(each.value.algorithm, [])

    content {
      display_name     = try(algorithm_entry.value.display_name, "${each.key}-alg-${algorithm_entry.key}")
      algorithm        = algorithm_entry.value.algorithm
      destination_port = algorithm_entry.value.destination_port
      source_ports     = try(algorithm_entry.value.source_ports, null)
    }
  }

  dynamic "igmp_entry" {
    for_each = try(each.value.igmp, [])

    content {
      display_name = try(igmp_entry.value.display_name, "${each.key}-igmp-${igmp_entry.key}")
    }
  }

  dynamic "ether_type_entry" {
    for_each = try(each.value.ether_type, [])

    content {
      display_name = try(ether_type_entry.value.display_name, "${each.key}-ether-${ether_type_entry.key}")
      ether_type   = ether_type_entry.value.ether_type
    }
  }
}
SCAFFOLD_EOF

write_file modules/service/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical service name => NSX policy path."
  value       = { for k, s in nsxt_policy_service.this : k => s.path }
}
SCAFFOLD_EOF

write_file modules/service/README.md <<'SCAFFOLD_EOF'
# module: service

Creates custom NSX services (L4 port sets, ICMP entries) from
`data/services/*.yaml`.

Predefined NSX services (HTTPS, SSH, …) are *not* created here — the stack
resolves them with a `nsxt_policy_service` data source, so there is one
definition of HTTPS in the estate rather than one per repository.

```yaml
custom:
  payments-api:
    display_name: payments-api
    l4_port_set:
      - protocol: TCP
        destination_ports: ["8443"]
```
SCAFFOLD_EOF

# --- modules/dfw-policy ----------------------------------------------------

write_file modules/dfw-policy/variables.tf <<'SCAFFOLD_EOF'
variable "policy" {
  description = "Policy header from the data file: id, name, category, scope, and options."
  type        = any

  validation {
    condition     = length(try(var.policy.scope, [])) > 0
    error_message = "policy.scope is mandatory. An unscoped policy is pushed to every hypervisor in its span."
  }

  validation {
    condition     = try(var.policy.rule_management, "standalone") == "standalone"
    error_message = "This module implements the parent-policy + standalone-rule pattern. Set rule_management: standalone, or manage the policy elsewhere — the provider forbids mixing the two on one policy."
  }
}

variable "rules" {
  description = <<-EOT
    Map of rules keyed by stable rule id. The key is the Terraform address:
    changing a value updates the rule in place, renaming a key destroys and
    recreates it. Never use count or list indices here — inserting a rule in
    the middle of an indexed list recreates every rule below it, which on a
    live DFW is a traffic outage.
  EOT
  type        = any
}

variable "domain" {
  description = "NSX domain for this policy. On a Global Manager, a domain id or a site id — set it explicitly."
  type        = string
}

variable "group_paths" {
  description = "Logical group name => NSX policy path. Data files reference groups by name only."
  type        = map(string)
}

variable "service_paths" {
  description = "Logical service name => NSX policy path."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/dfw-policy/main.tf <<'SCAFFOLD_EOF'
# Parent policy + one resource per rule.
#
# This is what makes daily rule churn safe: adding or removing a single rule
# touches exactly one resource. The alternative — nsxt_policy_security_policy
# with inline rule blocks — rewrites the whole policy on every change. The two
# must never be mixed on the same policy; the provider says so explicitly.

locals {
  # "ANY" and IP literals (an address, CIDR or range, as a rule's source or
  # destination) are the literals allowed in a data file. Everything else is a
  # logical name resolved to a policy path here, so no raw /infra/... path ever
  # appears in data/. A group of the same name wins over a literal.
  resolvable = concat(keys(var.group_paths), ["ANY"])
  ip_literal = "^([0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?(-[0-9]{1,3}(\\.[0-9]{1,3}){3})?|[0-9A-Fa-f]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?(-[0-9A-Fa-f]*:[0-9A-Fa-f:.]*)?)$"

  policy_scope = [for g in var.policy.scope : var.group_paths[g] if g != "ANY"]

  rule_sources = {
    for k, r in var.rules : k => [
      for g in try(r.source_groups, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_destinations = {
    for k, r in var.rules : k => [
      for g in try(r.destination_groups, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_scopes = {
    for k, r in var.rules : k => [
      for g in try(r.scope, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_services = {
    for k, r in var.rules : k => [
      for s in try(r.services, []) : lookup(var.service_paths, s, s) if s != "ANY"
    ]
  }

  # Names referenced by a rule that nothing in this stack defines. Surfaced as a
  # plan-time error rather than a confusing API rejection at apply time.
  unresolved_groups = {
    for k, r in var.rules : k => sort(tolist(setsubtract(
      toset(concat(
        [for g in concat(try(r.source_groups, []), try(r.destination_groups, [])) : g if !can(regex(local.ip_literal, g))],
        try(r.scope, []),
      )),
      toset(local.resolvable),
    )))
  }

  unresolved_services = {
    for k, r in var.rules : k => sort(tolist(setsubtract(
      toset(try(r.services, [])),
      toset(concat(keys(var.service_paths), ["ANY"])),
    )))
  }

  sequence_numbers = [for k, r in var.rules : r.sequence_number]
}

resource "nsxt_policy_parent_security_policy" "this" {
  nsx_id       = var.policy.id
  display_name = var.policy.name
  description  = try(var.policy.description, null)
  domain       = try(var.policy.domain, var.domain)
  category     = var.policy.category

  sequence_number = try(var.policy.sequence_number, 100)
  stateful        = try(var.policy.stateful, true)
  tcp_strict      = try(var.policy.tcp_strict, null)
  locked          = try(var.policy.locked, false)
  comments        = try(var.policy.comments, null)

  # Tags are part of the object: a tag not listed here is removed on apply.
  dynamic "tag" {
    for_each = try(var.policy.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  # Apply To. Mandatory — see the validation on var.policy.
  scope = local.policy_scope

  lifecycle {
    # A policy is reused, never recreated. Adding a rule must land inside the
    # existing policy; nothing routine may destroy this resource and build a
    # second one beside it. A destroy here would take every rule in the policy
    # with it, and on a live DFW that is an outage.
    #
    # This also blocks the silent replacements: changing category or domain
    # forces a new policy, which would drop and rebuild the whole ruleset.
    #
    # To genuinely retire a policy: remove this line in a reviewed commit,
    # apply the destroy, then restore it. That friction is deliberate — policy
    # deletion is not a routine change.
    prevent_destroy = true

    precondition {
      # allow_duplicate_sequence: set by the importer on a policy whose rules
      # NSX itself numbered with duplicates; adopted as they are.
      condition     = try(var.policy.allow_duplicate_sequence, false) || length(local.sequence_numbers) == length(distinct(local.sequence_numbers))
      error_message = "Duplicate sequence_number in policy ${var.policy.id}. Sequence numbers are allocated, not guessed."
    }
  }
}

resource "nsxt_policy_security_policy_rule" "this" {
  for_each = var.rules

  nsx_id       = each.key
  display_name = try(each.value.name, each.key)
  description  = try(each.value.description, null)
  policy_path  = nsxt_policy_parent_security_policy.this.path

  sequence_number = each.value.sequence_number
  action          = each.value.action
  direction       = each.value.direction
  ip_version      = try(each.value.ip_version, "IPV4_IPV6")
  disabled        = try(each.value.disabled, false)
  logged          = try(each.value.logged, true)
  notes           = try(each.value.notes, null)
  log_label       = try(each.value.log_label, null)

  source_groups         = local.rule_sources[each.key]
  destination_groups    = local.rule_destinations[each.key]
  sources_excluded      = try(each.value.sources_excluded, false)
  destinations_excluded = try(each.value.destinations_excluded, false)
  services              = local.rule_services[each.key]
  profiles              = try(each.value.profiles, null)

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  # Apply To. Without it the rule is distributed to every hypervisor in the
  # policy's span; host rule capacity is finite and this is a multi-site span.
  scope = local.rule_scopes[each.key]

  lifecycle {
    precondition {
      condition     = length(try(each.value.scope, [])) > 0
      error_message = "Rule ${each.key} in policy ${var.policy.id} has an empty scope. Every rule must set Apply To."
    }

    precondition {
      condition     = length(local.unresolved_groups[each.key]) == 0
      error_message = "Rule ${each.key} references undefined group(s): ${join(", ", local.unresolved_groups[each.key])}. Groups referenced by a Global Manager policy must be created on the Global Manager."
    }

    precondition {
      condition     = length(local.unresolved_services[each.key]) == 0
      error_message = "Rule ${each.key} references undefined service(s): ${join(", ", local.unresolved_services[each.key])}."
    }
  }
}
SCAFFOLD_EOF

write_file modules/dfw-policy/outputs.tf <<'SCAFFOLD_EOF'
output "policy_path" {
  description = "Policy path of the parent security policy."
  value       = nsxt_policy_parent_security_policy.this.path
}

output "rule_paths" {
  description = "Rule key => NSX policy path."
  value       = { for k, r in nsxt_policy_security_policy_rule.this : k => r.path }
}

output "rule_count" {
  description = "Number of rules under this policy. Compare against the plan's count delta."
  value       = length(nsxt_policy_security_policy_rule.this)
}
SCAFFOLD_EOF

write_file modules/dfw-policy/README.md <<'SCAFFOLD_EOF'
# module: dfw-policy

One `nsxt_policy_parent_security_policy` plus one
`nsxt_policy_security_policy_rule` per rule, built from a data file.

## Why standalone rules

Inline `rule` blocks on `nsxt_policy_security_policy` rewrite the entire policy
on every change. With one resource per rule, adding or removing a rule touches
exactly that rule. The provider forbids managing the same policy both ways —
choose per policy and record it as `rule_management` in the data file.

## Contract

- Rules arrive as a **map** keyed by stable rule id. Never a list, never
  `count`. Rename a key only if you intend a destroy-and-recreate.
- `scope` is mandatory at policy and rule level, enforced by a variable
  validation and a per-rule precondition.
- Groups and services are referenced by **logical name**; this module resolves
  them to policy paths from `group_paths` / `service_paths`. A name nothing
  defines fails at plan time with the offending rule named — in particular this
  is what catches a Global Manager policy referencing a site-local group, which
  Federation cannot span.
- `nsx_id` is set from the data key, so renaming `display_name` is
  metadata-only rather than a destroy-and-recreate.
- Sequence numbers are checked for duplicates within the policy at plan time.

## Not handled here

The **default rule** is deliberately not managed by this module. Flipping it
from ALLOW to DROP, or deleting it, black-holes a datacenter; it is a
restricted change with its own review path.
SCAFFOLD_EOF

# --- modules/segment -------------------------------------------------------

write_file modules/segment/variables.tf <<'SCAFFOLD_EOF'
variable "segments" {
  description = "Map of segment definitions keyed by stable logical name."
  type        = any
  default     = {}
}

variable "tier1_paths" {
  description = "Logical tier-1 name => NSX policy path, for segment connectivity."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/segment/main.tf <<'SCAFFOLD_EOF'
# Segments are Terraform-owned infrastructure, so tagging them here is correct —
# unlike VM tags, which belong to whatever system provisions the VM.
#
# Segment tags are what makes subnet-based group membership possible without
# hardcoding CIDRs into group criteria.

data "nsxt_policy_transport_zone" "this" {
  for_each = toset([for k, s in var.segments : s.transport_zone_display_name])

  display_name = each.value
}

resource "nsxt_policy_segment" "this" {
  for_each = var.segments

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  transport_zone_path = data.nsxt_policy_transport_zone.this[each.value.transport_zone_display_name].path
  connectivity_path   = try(var.tier1_paths[each.value.tier1], null)
  domain_name         = try(each.value.domain_name, null)
  vlan_ids            = try(each.value.vlan_ids, null)

  dynamic "subnet" {
    for_each = try(each.value.subnets, [])

    content {
      cidr        = subnet.value.cidr
      dhcp_ranges = try(subnet.value.dhcp_ranges, null)
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  lifecycle {
    precondition {
      condition     = length(try(each.value.tags, [])) > 0
      error_message = "Segment ${each.key} has no tags. Segment tags drive subnet-based group membership; an untagged segment cannot be matched by a group."
    }
  }
}
SCAFFOLD_EOF

write_file modules/segment/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical segment name => NSX policy path."
  value       = { for k, s in nsxt_policy_segment.this : k => s.path }
}
SCAFFOLD_EOF

write_file modules/segment/README.md <<'SCAFFOLD_EOF'
# module: segment

Creates NSX segments from `data/network/<site>.yaml`.

Transport zones are resolved by display name through a data source, so no raw
policy path appears in a data file and the same data works against any manager.

Tags are mandatory: a group that selects workloads by subnet does it by matching
`member_type: Segment` against a segment tag, never by embedding a CIDR. A CIDR
in a group is a duplicated fact that drifts from the segment's real definition.
SCAFFOLD_EOF

# --- modules/tier1 ---------------------------------------------------------

write_file modules/tier1/variables.tf <<'SCAFFOLD_EOF'
variable "tier1s" {
  description = "Map of tier-1 gateway definitions keyed by stable logical name."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/tier1/main.tf <<'SCAFFOLD_EOF'
data "nsxt_policy_tier0_gateway" "this" {
  for_each = toset(compact([for k, t in var.tier1s : try(t.tier0_display_name, "")]))

  display_name = each.value
}

data "nsxt_policy_edge_cluster" "this" {
  for_each = toset(compact([for k, t in var.tier1s : try(t.edge_cluster_display_name, "")]))

  display_name = each.value
}

resource "nsxt_policy_tier1_gateway" "this" {
  for_each = var.tier1s

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  tier0_path        = try(data.nsxt_policy_tier0_gateway.this[each.value.tier0_display_name].path, null)
  edge_cluster_path = try(data.nsxt_policy_edge_cluster.this[each.value.edge_cluster_display_name].path, null)

  failover_mode             = try(each.value.failover_mode, null)
  route_advertisement_types = try(each.value.route_advertisement_types, null)
  enable_standby_relocation = try(each.value.enable_standby_relocation, null)
  pool_allocation           = try(each.value.pool_allocation, null)

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }
}
SCAFFOLD_EOF

write_file modules/tier1/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical tier-1 name => NSX policy path."
  value       = { for k, t in nsxt_policy_tier1_gateway.this : k => t.path }
}
SCAFFOLD_EOF

write_file modules/tier1/README.md <<'SCAFFOLD_EOF'
# module: tier1

Tier-1 gateways for one site, from `data/network/<site>.yaml`.

T0 gateways and edge clusters are referenced by display name and resolved
through data sources — they are owned by the `platform` stack and read here.
That read is a data-source lookup against the live manager, not a
`terraform_remote_state` read: a network change must not depend on the platform
state being available or correct.
SCAFFOLD_EOF

# --- modules/tier0 ---------------------------------------------------------

write_file modules/tier0/variables.tf <<'SCAFFOLD_EOF'
variable "tier0s" {
  description = "Map of tier-0 gateway definitions keyed by stable logical name. RESTRICTED — see docs/ARCHITECTURE.md section 11."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/tier0/main.tf <<'SCAFFOLD_EOF'
# Tier-0 gateways. This is the platform layer: the slowest thing in the estate
# and the most dangerous. Every change here is a restricted change.

data "nsxt_policy_edge_cluster" "this" {
  for_each = toset([for k, t in var.tier0s : t.edge_cluster_display_name])

  display_name = each.value
}

resource "nsxt_policy_tier0_gateway" "this" {
  for_each = var.tier0s

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  ha_mode           = try(each.value.ha_mode, "ACTIVE_ACTIVE")
  failover_mode     = try(each.value.failover_mode, null)
  transit_subnets   = try(each.value.transit_subnets, null)
  edge_cluster_path = data.nsxt_policy_edge_cluster.this[each.value.edge_cluster_display_name].path

  dynamic "bgp_config" {
    for_each = try(each.value.bgp, null) == null ? [] : [each.value.bgp]

    content {
      enabled               = try(bgp_config.value.enabled, true)
      local_as_num          = try(bgp_config.value.local_as_num, null)
      ecmp                  = try(bgp_config.value.ecmp, true)
      inter_sr_ibgp         = try(bgp_config.value.inter_sr_ibgp, null)
      graceful_restart_mode = try(bgp_config.value.graceful_restart_mode, null)
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }
}
SCAFFOLD_EOF

write_file modules/tier0/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical tier-0 name => NSX policy path."
  value       = { for k, t in nsxt_policy_tier0_gateway.this : k => t.path }
}
SCAFFOLD_EOF

write_file modules/tier0/README.md <<'SCAFFOLD_EOF'
# module: tier0

Tier-0 gateways for one site, from `data/platform/<site>.yaml`.

Used only by the `platform` stack. Nothing with a daily cadence may share this
state: a rule edit must never require Terraform to refresh a T0 or a transport
zone.

Every change here is **restricted** — change advisory, named approver, rollback
plan, out-of-hours.
SCAFFOLD_EOF

# --- modules/vm-tags -------------------------------------------------------

write_file modules/vm-tags/variables.tf <<'SCAFFOLD_EOF'
variable "assignments" {
  description = <<-EOT
    VM tag assignments keyed by stable logical name. The tag list for each VM is
    its COMPLETE tag set: nsxt_policy_vm_tags replaces every tag on the VM, so
    anything omitted here is removed on apply.
  EOT
  type        = any
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.assignments : length(try(v.tags, [])) > 0])
    error_message = "Every VM needs at least one tag. An empty list strips all tags from the VM, which is never what a data edit meant to say — remove the entry instead."
  }

  validation {
    condition     = alltrue([for k, v in var.assignments : can(v.display_name) || can(v.external_id)])
    error_message = "Every VM needs either display_name or external_id to identify it."
  }
}

variable "vm_index" {
  description = "VM display name => external id, from the nsxt_policy_vms data source in the stack. One API call resolves every name; a per-VM data source would be one call each."
  type        = map(string)
  default     = {}
}

variable "segment_paths" {
  description = "Logical segment name => NSX policy path, for per-port tags."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/vm-tags/main.tf <<'SCAFFOLD_EOF'
# VM tags written by Terraform.
#
# READ docs/ARCHITECTURE.md section 7 BEFORE ADDING TO THIS.
#
# nsxt_policy_vm_tags takes ownership of a VM's ENTIRE tag set — the provider
# removes every tag on the VM when the resource is destroyed, and replaces the
# whole set on every change. There is no per-tag ownership. So this module is
# only correct for VMs that nothing else tags: no VCF automation, no vSphere tag
# sync, no CMDB write-back. The validator enforces that by refusing any scope
# whose owner in data/schema/tag-scopes.yaml is not 'terraform'.
#
# What this module deliberately does NOT do is merge with the tags already on
# the VM. Reading current tags and unioning them into the desired set would make
# removal impossible and produce a permanent diff; a tag that cannot be removed
# is worse than one that was never managed.

locals {
  # display_name is resolved through the stack's single nsxt_policy_vms lookup.
  # external_id, when given, wins: it is stable across a rename and unambiguous
  # where two vCenters hold VMs of the same name.
  resolved = {
    for k, v in var.assignments : k => try(
      v.external_id,
      lookup(var.vm_index, try(v.display_name, ""), ""),
    )
  }

  unresolved = sort([for k, id in local.resolved : k if id == ""])

  unknown_segments = {
    for k, v in var.assignments : k => sort(tolist(setsubtract(
      toset([for p in try(v.ports, []) : p.segment]),
      toset(keys(var.segment_paths)),
    )))
  }
}

resource "nsxt_policy_vm_tags" "this" {
  for_each = var.assignments

  instance_id = local.resolved[each.key]

  dynamic "tag" {
    for_each = each.value.tags

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  dynamic "port" {
    for_each = try(each.value.ports, [])

    content {
      segment_path = var.segment_paths[port.value.segment]

      dynamic "tag" {
        for_each = port.value.tags

        content {
          scope = tag.value.scope
          tag   = tag.value.tag
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.resolved[each.key] != ""
      error_message = "VM ${each.key}: no VM named '${try(each.value.display_name, "")}' exists on this manager. A name that does not resolve would otherwise be applied as an empty instance_id."
    }

    precondition {
      condition     = length(local.unknown_segments[each.key]) == 0
      error_message = "VM ${each.key}: port tags reference segment(s) not defined for this site: ${join(", ", local.unknown_segments[each.key])}."
    }
  }
}
SCAFFOLD_EOF

write_file modules/vm-tags/outputs.tf <<'SCAFFOLD_EOF'
output "tagged" {
  description = "Logical VM name => external id actually tagged. Compare against the data file when a plan surprises you."
  value       = { for k, r in nsxt_policy_vm_tags.this : k => r.instance_id }
}

output "count" {
  description = "Number of VMs whose tag set this module owns."
  value       = length(nsxt_policy_vm_tags.this)
}

output "unresolved" {
  description = "VMs whose display_name matched nothing on this manager. Empty unless a precondition is disabled."
  value       = local.unresolved
}
SCAFFOLD_EOF

write_file modules/vm-tags/README.md <<'SCAFFOLD_EOF'
# module: vm-tags

Writes NSX tags onto virtual machines, so that tagging a workload is a reviewed
data edit rather than a click in the NSX UI.

**This module owns the whole tag set of every VM it touches.** `nsxt_policy_vm_tags`
has no per-tag ownership: it replaces every tag on the VM on each change and
removes every tag when destroyed. Use it only where nothing else tags the VM.

## Input shape

```yaml
site: lon1
sole_tagger: >
  These VMs are hand-built and are not in the CMDB; nothing else writes their
  NSX tags.
vms:
  payments-web-01:
    display_name: payments-web-01     # or external_id, which is preferred
    tags:
      - { scope: workload, tag: payments-web }
      - { scope: quarantine, tag: active }   # complete set — omissions are removals
```

## Notes

- `external_id` beats `display_name`: it survives a rename and is unambiguous
  when two vCenters hold VMs of the same name. `display_name` is resolved
  through one `nsxt_policy_vms` call in the stack, not one call per VM.
- An unresolvable name is a **plan-time** failure, not a silent no-op.
- A scope may only be used here if `data/schema/tag-scopes.yaml` records its
  `owner` as `terraform`. That is the mechanism that keeps this module from
  fighting VCF automation or a CMDB.
- Groups consume these tags through dynamic criteria exactly as they consume
  tags from any other source — nothing in `modules/group` changes.
- This runs on a Local Manager. A Global Manager has no VM inventory.

## Scale

One resource per VM. That is fine for hundreds of exception workloads and wrong
for tens of thousands: at estate scale the tags belong in the provisioning
system, and this repository consumes them. See `docs/TAGGING.md`.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 5. Stacks
#
# One root module per stack, instantiated once per manager by the pipeline with
# partial backend config — not 10+ aliased providers in a single root module.
# ---------------------------------------------------------------------------

# Shared: data-loading locals, identical in every security stack.
gen_versions() {
	write_file "stacks/$1/versions.tf" <<'SCAFFOLD_EOF'
terraform {
  required_version = ">= 1.9"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.9"
    }
  }
}
SCAFFOLD_EOF
}

gen_backend() {
	case "$BACKEND" in
	http)
		write_file "stacks/$1/backend.tf" <<'SCAFFOLD_EOF'
# Partial backend configuration. Values come from envs/<site>.backend.hcl:
#
#   terraform init -backend-config=../../envs/${SITE}.backend.hcl
#
# GitLab-managed Terraform state. GitLab provides locking, encryption at rest
# and version history, so this satisfies what section 9 requires of a backend
# without standing up an object store.
#
# CREDENTIALS DO NOT GO IN THE .hcl FILE. envs/*.backend.hcl is committed, so
# the token would be committed with it. Terraform reads them from the
# environment instead:
#
#   in GitLab CI scripts/tf.sh sets TF_HTTP_USERNAME=gitlab-ci-token and
#   TF_HTTP_PASSWORD=$CI_JOB_TOKEN itself; set them only to override that
#
# Outside CI use a personal or project access token with the api scope, sourced
# the same way the NSX credentials are — never written to disk.

terraform {
  backend "http" {}
}
SCAFFOLD_EOF
		;;
	s3)
		write_file "stacks/$1/backend.tf" <<'SCAFFOLD_EOF'
# Partial backend configuration. Values come from envs/<site>.backend.hcl:
#
#   terraform init -backend-config=../../envs/${SITE}.backend.hcl
#
# S3 or an S3-compatible store (MinIO, Ceph RGW). The bucket must have
# versioning and encryption enabled, and locking must be configured — either a
# DynamoDB table or the provider's native lock support. State without locking is
# state that two concurrent runs will corrupt.
#
# Credentials come from the environment or an instance role, never from this
# file: envs/*.backend.hcl is committed.

terraform {
  backend "s3" {}
}
SCAFFOLD_EOF
		;;
	azurerm)
		write_file "stacks/$1/backend.tf" <<'SCAFFOLD_EOF'
# Partial backend configuration. Values come from envs/<site>.backend.hcl:
#
#   terraform init -backend-config=../../envs/${SITE}.backend.hcl
#
# Azure blob storage. The container must have soft delete and versioning
# enabled; blob leases provide the locking.
#
# Credentials come from the environment or a managed identity, never from this
# file: envs/*.backend.hcl is committed.

terraform {
  backend "azurerm" {}
}
SCAFFOLD_EOF
		;;
	*)
		write_file "stacks/$1/backend.tf" <<'SCAFFOLD_EOF'
# Partial backend configuration. Values come from envs/<site>.backend.hcl:
#
#   terraform init -backend-config=../../envs/${SITE}.backend.hcl
#
# OPEN DECISION (docs/ARCHITECTURE.md section 14.1): the backend type is the owner's call
# and has not been made. Until it is, this is the local backend so the stack
# initialises out of the box for validation and dry runs.
#
# The local backend is NOT acceptable for a real manager. Two reasons, and the
# second is the one that bites:
#
#   * State carries the full security posture of the estate, so it needs
#     encryption at rest and access restricted to the pipeline identity.
#   * The local backend HAS NO LOCKING. Two runs against one site at the same
#     time — a pipeline and an engineer, or two pipeline jobs — will corrupt the
#     state file, and Terraform will not warn you.
#
# scripts/tf.sh refuses to apply through it unless ALLOW_LOCAL_STATE=1 is set.
#
# Regenerate with the backend you want rather than editing this by hand:
#
#   scripts/bootstrap.sh --force --backend http      # GitLab-managed state
#   scripts/bootstrap.sh --force --backend s3        # S3 or MinIO/Ceph
#   scripts/bootstrap.sh --force --backend azurerm
#
# and fill in envs/<site>.backend.hcl to match.

terraform {
  backend "local" {}
}
SCAFFOLD_EOF
		;;
	esac
}

for s in global-security local-security local-network platform local-tags; do
	gen_versions "$s"
	gen_backend "$s"
done

# --- stacks/global-security ------------------------------------------------

write_file stacks/global-security/providers.tf <<'SCAFFOLD_EOF'
# host / username / password come from NSXT_MANAGER_HOST, NSXT_USERNAME and
# NSXT_PASSWORD, exported by the pipeline from Vault. Nothing sensitive is ever
# written into a .tf file, a variable, or state.
provider "nsxt" {
  global_manager = true

  # Federation realization is slower than a Local Manager's: the GM accepts a
  # policy before every site has realized it. Under-tuned retries surface that
  # as spurious errors.
  max_retries     = 6
  retry_min_delay = 500
  retry_max_delay = 5000
}
SCAFFOLD_EOF

write_file stacks/global-security/variables.tf <<'SCAFFOLD_EOF'
variable "domain" {
  description = <<-EOT
    NSX domain for objects created by this stack. On a Global Manager this is a
    domain id or a site id, and it determines the object's span. There is no
    default on purpose: an accidental 'default' domain gives estate-wide span.
  EOT
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/global-security/main.tf <<'SCAFFOLD_EOF'
# global-security — the federated DFW, owned by the Global Manager.
#
# Objects created here are read-only on every Local Manager. Nothing in a
# local-* stack may manage the same object; two stacks pointed at one object
# produces permanent drift and failed applies.

locals {
  data_root = "${path.module}/${var.data_root}"

  # --- groups -------------------------------------------------------------
  group_files = fileset("${local.data_root}/groups", "*.yaml")

  groups_all = merge([
    for f in local.group_files : try(yamldecode(file("${local.data_root}/groups/${f}")).groups, {})
  ]...)

  groups = { for k, g in local.groups_all : k => g if try(g.owner, "lm") == "gm" }

  # Groups that reference other groups are created in a second pass so their
  # member paths can be resolved. A group cannot reference itself into
  # existence.
  composite_group_keys = [
    for k, g in local.groups : k
    if length(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])) > 0
  ]

  base_groups      = { for k, g in local.groups : k => g if !contains(local.composite_group_keys, k) }
  composite_groups = { for k, g in local.groups : k => g if contains(local.composite_group_keys, k) }

  group_paths = merge(module.base_groups.paths, module.composite_groups.paths)

  # --- services -----------------------------------------------------------
  service_files = fileset("${local.data_root}/services", "*.yaml")
  service_docs  = [for f in local.service_files : yamldecode(file("${local.data_root}/services/${f}"))]

  predefined_services = merge([for d in local.service_docs : try(d.predefined, {})]...)
  # Services NSX ships with, by id: their path is known, so nothing is looked up
  # (a lookup by display name can match more than one).
  predefined_service_ids = merge([for d in local.service_docs : try(d.predefined_ids, {})]...)
  custom_services_all    = merge([for d in local.service_docs : try(d.custom, {})]...)
  custom_services        = { for k, v in local.custom_services_all : k => v if try(v.owner, "gm") == "gm" }

  service_paths = merge(
    { for k, _ in local.predefined_service_ids : k => "/global-infra/services/${k}" },
    { for k, s in data.nsxt_policy_service.predefined : k => s.path },
    module.services.paths,
  )

  # --- policies -----------------------------------------------------------
  policy_files = fileset("${local.data_root}/policies", "*.yaml")

  policy_docs = {
    for f in local.policy_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.data_root}/policies/${f}"))
  }

  policies = {
    for k, d in local.policy_docs : k => d
    if try(d.policy.owner, "lm") == "gm" && try(d.policy.rule_management, "standalone") == "standalone"
  }
}

module "base_groups" {
  source = "../../modules/group"

  groups = local.base_groups
  domain = var.domain
}

module "composite_groups" {
  source = "../../modules/group"

  groups      = local.composite_groups
  domain      = var.domain
  group_paths = module.base_groups.paths
}

# Services NSX already ships with are looked up, never recreated.
data "nsxt_policy_service" "predefined" {
  for_each = local.predefined_services

  display_name = each.value
}

module "services" {
  source = "../../modules/service"

  services = local.custom_services
}

module "policies" {
  source   = "../../modules/dfw-policy"
  for_each = local.policies

  policy        = each.value.policy
  rules         = each.value.rules
  domain        = var.domain
  group_paths   = local.group_paths
  service_paths = local.service_paths
}
SCAFFOLD_EOF

write_file stacks/global-security/outputs.tf <<'SCAFFOLD_EOF'
output "policy_count" {
  description = "Policies managed by this stack."
  value       = length(local.policies)
}

output "rule_count" {
  description = "Total rules across all policies. Compare against the plan's count delta before approving."
  value       = sum(concat([0], [for k, m in module.policies : m.rule_count]))
}

output "group_count" {
  description = "Groups managed by this stack."
  value       = length(local.groups)
}

output "policy_paths" {
  description = "Policy key => NSX policy path."
  value       = { for k, m in module.policies : k => m.policy_path }
}
SCAFFOLD_EOF

write_file stacks/global-security/README.md <<'SCAFFOLD_EOF'
# stack: global-security

The federated DFW. One state for the federation.

- Cadence: **daily**. Blast radius: **all sites**. Approver: **security review**.
- Provider runs with `global_manager = true` and raised retries.
- Consumes every `data/policies/*.yaml` and `data/groups/*.yaml` entry marked
  `owner: gm`.

## Boundary

Objects created here are read-only on the Local Managers. A group referenced by
a policy in this stack must also be `owner: gm` — a site-local group cannot be
referenced across the span, and the dfw-policy module fails the plan if you try.

## Run

```bash
export TF_VAR_domain=default         # the global domain; a location's domain only for location-specific objects
terraform init -backend-config=../../envs/gm1.backend.hcl
terraform plan -out=tfplan -parallelism=5
```

Or from the repository root: `make plan STACK=global-security SITE=gm1`.
SCAFFOLD_EOF

# --- stacks/local-security -------------------------------------------------

write_file stacks/local-security/providers.tf <<'SCAFFOLD_EOF'
# Credentials arrive as NSXT_* environment variables from the pipeline.
provider "nsxt" {
  # global_manager stays false: this stack talks to a Local Manager.
  max_retries     = 4
  retry_min_delay = 200
  retry_max_delay = 1000
}
SCAFFOLD_EOF

write_file stacks/local-security/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "domain" {
  description = "NSX domain on the Local Manager. 'default' is the only domain on a standard LM."
  type        = string
  default     = "default"
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/local-security/main.tf <<'SCAFFOLD_EOF'
# local-security — site-local DFW exceptions for one Local Manager.
#
# One state per LM. Anything federated belongs in global-security; this stack
# must never manage a GM-owned object, which the Local Manager would reject as
# read-only anyway.

locals {
  data_root = "${path.module}/${var.data_root}"

  # --- groups -------------------------------------------------------------
  group_files = fileset("${local.data_root}/groups", "*.yaml")

  groups_all = merge([
    for f in local.group_files : try(yamldecode(file("${local.data_root}/groups/${f}")).groups, {})
  ]...)

  groups = {
    for k, g in local.groups_all : k => g
    if try(g.owner, "lm") == "lm" && (
      contains(try(g.sites, []), var.site) || contains(try(g.sites, []), "*")
    )
  }

  composite_group_keys = [
    for k, g in local.groups : k
    if length(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])) > 0
  ]

  base_groups      = { for k, g in local.groups : k => g if !contains(local.composite_group_keys, k) }
  composite_groups = { for k, g in local.groups : k => g if contains(local.composite_group_keys, k) }

  # The Global Manager's groups, as a Local Manager sees them: read-only, under
  # /global-infra. A site-local rule may use one by name; this stack never
  # manages it (owner: gm is filtered out above), so it cannot fight the GM.
  global_group_paths = {
    for k, g in local.groups_all : k => "/global-infra/domains/${try(g.domain, "default")}/groups/${k}"
    if try(g.owner, "lm") == "gm"
  }

  group_paths = merge(local.global_group_paths, module.base_groups.paths, module.composite_groups.paths)

  # --- services -----------------------------------------------------------
  service_files = fileset("${local.data_root}/services", "*.yaml")
  service_docs  = [for f in local.service_files : yamldecode(file("${local.data_root}/services/${f}"))]

  predefined_services = merge([for d in local.service_docs : try(d.predefined, {})]...)
  # Services NSX ships with, by id: their path is known, so nothing is looked up
  # (a lookup by display name can match the Global Manager's copy too).
  predefined_service_ids = merge([for d in local.service_docs : try(d.predefined_ids, {})]...)
  custom_services_all    = merge([for d in local.service_docs : try(d.custom, {})]...)
  # A site-local service is created only on the Local Managers it lists. One with
  # no sites keeps the old meaning, every Local Manager; the validator asks for
  # the list to be explicit.
  custom_services = {
    for k, v in local.custom_services_all : k => v
    if try(v.owner, "gm") == "lm" && (contains(try(v.sites, ["*"]), var.site) || contains(try(v.sites, ["*"]), "*"))
  }

  # The Global Manager's custom services, likewise: used by name, never managed here.
  global_service_paths = {
    for k, v in local.custom_services_all : k => "/global-infra/services/${k}"
    if try(v.owner, "gm") == "gm"
  }

  service_paths = merge(
    local.global_service_paths,
    { for k, _ in local.predefined_service_ids : k => "/infra/services/${k}" },
    { for k, s in data.nsxt_policy_service.predefined : k => s.path },
    module.services.paths,
  )

  # --- policies -----------------------------------------------------------
  policy_files = fileset("${local.data_root}/policies", "*.yaml")

  policy_docs = {
    for f in local.policy_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.data_root}/policies/${f}"))
  }

  policies = {
    for k, d in local.policy_docs : k => d
    if try(d.policy.owner, "lm") == "lm"
    && try(d.policy.rule_management, "standalone") == "standalone"
    && (contains(try(d.policy.sites, []), var.site) || contains(try(d.policy.sites, []), "*"))
  }
}

module "base_groups" {
  source = "../../modules/group"

  groups = local.base_groups
  domain = var.domain
}

module "composite_groups" {
  source = "../../modules/group"

  groups      = local.composite_groups
  domain      = var.domain
  group_paths = module.base_groups.paths
}

data "nsxt_policy_service" "predefined" {
  for_each = local.predefined_services

  display_name = each.value
}

module "services" {
  source = "../../modules/service"

  services = local.custom_services
}

module "policies" {
  source   = "../../modules/dfw-policy"
  for_each = local.policies

  policy        = each.value.policy
  rules         = each.value.rules
  domain        = var.domain
  group_paths   = local.group_paths
  service_paths = local.service_paths
}
SCAFFOLD_EOF

write_file stacks/local-security/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "policy_count" {
  description = "Policies managed by this stack at this site."
  value       = length(local.policies)
}

output "rule_count" {
  description = "Total rules at this site. Compare against the plan's count delta before approving."
  value       = sum(concat([0], [for k, m in module.policies : m.rule_count]))
}

output "group_count" {
  description = "Site-local groups managed by this stack."
  value       = length(local.groups)
}
SCAFFOLD_EOF

write_file stacks/local-security/README.md <<'SCAFFOLD_EOF'
# stack: local-security

Site-local DFW exceptions. **One state per Local Manager.**

- Cadence: weekly. Blast radius: one site. Approver: site owner.
- Consumes `data/policies/*.yaml` and `data/groups/*.yaml` entries marked
  `owner: lm` whose `sites` list contains this site (or `"*"`).

GM and LM policies coexist within the same categories. Confirm the exact
precedence between GM and LM sections for your NSX version before relying on
cross-boundary rule ordering — do not assume it.

```bash
make plan STACK=local-security SITE=lon1
```
SCAFFOLD_EOF

# --- stacks/local-network --------------------------------------------------

write_file stacks/local-network/providers.tf <<'SCAFFOLD_EOF'
provider "nsxt" {
  max_retries     = 4
  retry_min_delay = 200
  retry_max_delay = 1000
}
SCAFFOLD_EOF

write_file stacks/local-network/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/local-network/main.tf <<'SCAFFOLD_EOF'
# local-network — segments and tier-1 gateways for one site. One state per LM.
#
# Separate from local-security because the cadences differ and a DFW edit must
# never refresh network objects.

locals {
  data_file = "${path.module}/${var.data_root}/network/${var.site}.yaml"
  # Both branches must be the same type, so the fallback is an empty YAML
  # document rather than an empty object: a conditional whose branches differ
  # in type fails at plan time on exactly the sites that do have a data file.
  data = yamldecode(fileexists(local.data_file) ? file(local.data_file) : "{}")

  tier1s   = try(local.data.tier1s, {})
  segments = try(local.data.segments, {})
}

module "tier1" {
  source = "../../modules/tier1"

  tier1s = local.tier1s
}

module "segment" {
  source = "../../modules/segment"

  segments    = local.segments
  tier1_paths = module.tier1.paths
}
SCAFFOLD_EOF

write_file stacks/local-network/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "segment_paths" {
  description = "Logical segment name => NSX policy path."
  value       = module.segment.paths
}

output "tier1_paths" {
  description = "Logical tier-1 name => NSX policy path."
  value       = module.tier1.paths
}
SCAFFOLD_EOF

write_file stacks/local-network/README.md <<'SCAFFOLD_EOF'
# stack: local-network

Segments and tier-1 gateways for one site. **One state per Local Manager.**

- Cadence: weekly. Blast radius: one site. Approver: network owner.
- Reads `data/network/<site>.yaml`. A site with no such file plans clean and
  manages nothing.

Segment tags are set here because segments are Terraform-owned. Those tags are
what lets a group select workloads by subnet without embedding a CIDR.
SCAFFOLD_EOF

# --- stacks/local-tags -----------------------------------------------------

write_file stacks/local-tags/providers.tf <<'SCAFFOLD_EOF'
provider "nsxt" {
  # A Local Manager: VM inventory is local, so a Global Manager cannot run this.
  max_retries     = 4
  retry_min_delay = 200
  retry_max_delay = 1000
}
SCAFFOLD_EOF

write_file stacks/local-tags/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}

variable "resolve_names" {
  description = "Look up VMs by display_name via the nsxt_policy_vms inventory. Set false in an estate that keys entirely on external_id — it removes an inventory-wide read from every plan."
  type        = bool
  default     = true
}
SCAFFOLD_EOF

write_file stacks/local-tags/main.tf <<'SCAFFOLD_EOF'
# local-tags — VM tags for one site. One state per Local Manager.
#
# Separate from local-security on purpose. Tagging churns daily and its blast
# radius is the listed VMs; DFW policies churn weekly and their blast radius is
# the site. Sharing a state would mean every tag edit refreshes every policy.
#
# There is no Terraform dependency between the two: NSX evaluates dynamic group
# membership server-side, so a tag applied here changes group membership without
# local-security running at all. Tag first, then confirm membership in NSX.

locals {
  data_file = "${path.module}/${var.data_root}/vm-tags/${var.site}.yaml"
  # Both branches must be the same type, so the fallback is an empty YAML
  # document rather than an empty object.
  data = yamldecode(fileexists(local.data_file) ? file(local.data_file) : "{}")

  assignments = try(local.data.vms, {})

  # Per-port tags reference segments by logical name. The segments themselves
  # belong to local-network; this stack only needs their paths, so it reads them
  # from the inventory rather than taking a state dependency on that stack.
  segment_names = toset(flatten([
    for k, v in local.assignments : [for p in try(v.ports, []) : p.segment]
  ]))

  needs_name_lookup = var.resolve_names && length([
    for k, v in local.assignments : k if !can(v.external_id)
  ]) > 0
}

# One inventory read resolves every display_name in the data file. value_type
# external_id matches what nsxt_policy_vm_tags.instance_id expects.
data "nsxt_policy_vms" "inventory" {
  count = local.needs_name_lookup ? 1 : 0

  value_type = "external_id"
}

data "nsxt_policy_segment" "referenced" {
  for_each = local.segment_names

  display_name = each.value
}

module "vm_tags" {
  source = "../../modules/vm-tags"

  assignments   = local.assignments
  vm_index      = local.needs_name_lookup ? data.nsxt_policy_vms.inventory[0].items : {}
  segment_paths = { for k, s in data.nsxt_policy_segment.referenced : k => s.path }
}
SCAFFOLD_EOF

write_file stacks/local-tags/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "vm_count" {
  description = "VMs whose complete tag set this stack owns at this site. Compare against the plan's count delta before approving."
  value       = module.vm_tags.count
}

output "tagged" {
  description = "Logical VM name => external id actually tagged."
  value       = module.vm_tags.tagged
}
SCAFFOLD_EOF

write_file stacks/local-tags/README.md <<'SCAFFOLD_EOF'
# stack: local-tags

VM tags for one site. **One state per Local Manager.**

- Cadence: daily. Blast radius: the VMs listed. Approver: site owner.
- Reads `data/vm-tags/<site>.yaml`. A site with no such file plans clean and
  manages nothing — which is the correct posture for most estates.

```bash
make plan STACK=local-tags SITE=lon1
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
```

**Before you put a VM in here, read `docs/TAGGING.md`.** This stack takes
ownership of the entire tag set of every VM it lists, because the underlying
resource has no per-tag ownership. In an estate where VCF automation or a CMDB
also writes NSX tags, that is a fight Terraform loses slowly and silently.

A Global Manager cannot run this stack: VM inventory is local to each Local
Manager.
SCAFFOLD_EOF

# --- stacks/platform -------------------------------------------------------

write_file stacks/platform/providers.tf <<'SCAFFOLD_EOF'
provider "nsxt" {
  max_retries     = 4
  retry_min_delay = 500
  retry_max_delay = 2000
}
SCAFFOLD_EOF

write_file stacks/platform/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/platform/main.tf <<'SCAFFOLD_EOF'
# platform — tier-0 gateways and the objects underneath them, for one site.
#
# The slowest and most dangerous state in the estate. Every change here is
# RESTRICTED: change advisory, named approver, rollback plan, out-of-hours.
# Nothing with a daily cadence may ever be added to this stack.

locals {
  data_file = "${path.module}/${var.data_root}/platform/${var.site}.yaml"
  # Both branches must be the same type, so the fallback is an empty YAML
  # document rather than an empty object: a conditional whose branches differ
  # in type fails at plan time on exactly the sites that do have a data file.
  data = yamldecode(fileexists(local.data_file) ? file(local.data_file) : "{}")

  tier0s = try(local.data.tier0s, {})
}

module "tier0" {
  source = "../../modules/tier0"

  tier0s = local.tier0s
}
SCAFFOLD_EOF

write_file stacks/platform/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "tier0_paths" {
  description = "Logical tier-0 name => NSX policy path."
  value       = module.tier0.paths
}
SCAFFOLD_EOF

write_file stacks/platform/README.md <<'SCAFFOLD_EOF'
# stack: platform

Tier-0 gateways, and in time transport zones and edge clusters, for one site.
**One state per Local Manager.**

- Cadence: rarely. Blast radius: one site, total. Approver: change advisory.
- Reads `data/platform/<site>.yaml`.

Every change here is **restricted**. Automation may prepare one; it may
never apply one.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 6. Tooling
# ---------------------------------------------------------------------------

write_file scripts/preflight.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Report which tools this repository needs and which are present. Read-only.

set -uo pipefail

status=0

check() {
	local name="$1" why="$2" required="$3"
	if command -v "$name" >/dev/null 2>&1; then
		printf '  ok       %-12s %s\n' "$name" "$($name --version 2>/dev/null | head -1)"
	elif [ "$required" = required ]; then
		printf '  MISSING  %-12s %s\n' "$name" "$why"
		status=1
	else
		printf '  absent   %-12s %s (optional)\n' "$name" "$why"
	fi
}

echo "tools"
check terraform "plan and apply" required
check python3 "data validation and the CI matrix" required
check git "everything" required
check curl "fetching credentials from Vault or SDDC Manager" optional
check tflint "extra Terraform linting" optional

echo
echo "repository"
for f in inventory/managers.yaml data/schema/tag-scopes.yaml Makefile; do
	if [ -e "$f" ]; then
		printf '  ok       %s\n' "$f"
	else
		printf '  MISSING  %s\n' "$f"
		status=1
	fi
done

if [ -n "$(find stacks -name '.terraform.lock.hcl' -print -quit 2>/dev/null)" ]; then
	printf '  ok       provider lock files present\n'
else
	printf '  absent   no .terraform.lock.hcl yet — run terraform init in a stack and commit it\n'
fi

echo
if [ "$status" = 0 ]; then
	echo "preflight passed"
else
	echo "preflight found missing requirements"
fi
exit "$status"
SCAFFOLD_EOF
mark_executable scripts/preflight.sh

write_file scripts/tf.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Terraform wrapper: one stack, one manager, one state.
#
#   scripts/tf.sh init   <stack> <site>
#   scripts/tf.sh plan   <stack> <site>
#   scripts/tf.sh show   <stack> <site>
#   scripts/tf.sh apply  <stack> <site>     # requires APPROVE=yes
#   scripts/tf.sh drift  <stack> <site>     # refresh-only plan: exit 2 on drift
#
# Credentials are never read from a file here. Either they are already in the
# environment as NSXT_MANAGER_HOST / NSXT_USERNAME / NSXT_PASSWORD, or you wrap
# the call:
#
#   scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARALLELISM="${PARALLELISM:-5}"

usage() {
	sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-1}"
}

[ $# -ge 3 ] || usage 1

cmd="$1"
stack="$2"
site="$3"
shift 3

stack_dir="$REPO_ROOT/stacks/$stack"
backend_file="$REPO_ROOT/envs/${site}.backend.hcl"
plan_file="$stack_dir/tfplan"

[ -d "$stack_dir" ] || {
	echo "error: no such stack: $stack" >&2
	exit 1
}
[ -f "$backend_file" ] || {
	echo "error: missing backend config: envs/${site}.backend.hcl" >&2
	exit 1
}

# Site and domain come from the inventory, so a manager is added by editing data.
# Captured first: a failure inside eval "$(...)" would go unnoticed, and this
# carries the manager's mode, which decides whether anything may be applied.
exports="$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$site")" || {
	echo "error: cannot read manager '$site' from inventory/managers.yaml (above)" >&2
	exit 1
}
eval "$exports"

export TF_VAR_site="$site"
export TF_VAR_domain="${TF_VAR_domain:-${NSX_DOMAIN:-default}}"
export TF_IN_AUTOMATION=1
# GitLab-managed state: inside a GitLab job, authenticate to the state API with
# the job's own token, so no state credential is stored anywhere. Credentials
# set explicitly (TF_HTTP_USERNAME / TF_HTTP_PASSWORD) are left alone; run by
# hand outside CI, set them to a token with the api scope.
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -z "${TF_HTTP_PASSWORD:-}" ]; then
	export TF_HTTP_USERNAME=gitlab-ci-token
	export TF_HTTP_PASSWORD="$CI_JOB_TOKEN"
fi
# Certificate authorities Terraform must trust, beyond the system roots:
#
#   CI_SERVER_TLS_CA_FILE  the CA of a GitLab that serves its own certificate.
#                          The runner gives every job this file and git and curl
#                          use it, but Terraform reads state over HTTPS too and
#                          otherwise fails with "x509: certificate signed by
#                          unknown authority".
#   NSX_CA_FILE_<SITE>     the CA that signed THIS manager's certificate, or the
#                          manager's own certificate if it is self-signed. SITE
#                          is the manager key upper-cased, as for credentials
#                          (hyd-gm01 is NSX_CA_FILE_HYD_GM01). In GitLab, a CI/CD
#                          variable of type File holding the PEM.
#   NSX_CA_FILE            the same, for every manager without its own. Several
#                          PEMs in one file trust all of them.
#
# A per-manager file wins, so each manager's run trusts only its own CA. Without
# either, the NSX provider fails with "x509: certificate signed by unknown
# authority" against any manager with an internal or self-signed certificate.
#
# Go replaces its default root file when SSL_CERT_FILE is set, so the bundle is
# the system roots plus those CAs. An SSL_CERT_FILE you set yourself is left
# alone, and then no NSX CA file is used.
site_key="$(printf '%s' "$site" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')"
nsx_ca_var="NSX_CA_FILE_${site_key}"
[ -n "${!nsx_ca_var:-}" ] || nsx_ca_var=NSX_CA_FILE
nsx_ca_file="${!nsx_ca_var:-}"
if [ -n "$nsx_ca_file" ]; then
	[ -f "$nsx_ca_file" ] && [ -r "$nsx_ca_file" ] || {
		echo "error: $nsx_ca_var is set to '$nsx_ca_file', which is not a readable file." >&2
		exit 1
	}
	grep -q 'BEGIN CERTIFICATE' "$nsx_ca_file" || {
		echo "error: $nsx_ca_var ($nsx_ca_file) holds no PEM certificate." >&2
		exit 1
	}
fi
gitlab_ca_file=""
if [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then
	gitlab_ca_file="$CI_SERVER_TLS_CA_FILE"
fi
if [ -n "${SSL_CERT_FILE:-}" ]; then
	[ -z "$nsx_ca_file" ] || echo "note: SSL_CERT_FILE is already set, so $nsx_ca_var is not added to it." >&2
elif [ -n "$gitlab_ca_file$nsx_ca_file" ]; then
	ca_bundle="$(mktemp "${TMPDIR:-/tmp}/nsx-ca.XXXXXX")"
	trap 'rm -f "$ca_bundle"' EXIT
	for roots in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
		if [ -r "$roots" ]; then
			cat "$roots" >>"$ca_bundle"
			break
		fi
	done
	for extra in "$gitlab_ca_file" "$nsx_ca_file"; do
		[ -z "$extra" ] || printf '\n' >>"$ca_bundle"
		[ -z "$extra" ] || cat "$extra" >>"$ca_bundle"
	done
	export SSL_CERT_FILE="$ca_bundle"
fi
# Provider mirror, for networks that cannot reach registry.terraform.io (scripts/tf-mirror.sh).
if [ -f "$REPO_ROOT/scripts/tf-mirror.sh" ]; then
	# shellcheck source=scripts/tf-mirror.sh
	. "$REPO_ROOT/scripts/tf-mirror.sh"
	nsx_tf_mirror_setup
fi

# global-security takes no site variable; the other stacks require one.
if [ "$stack" = global-security ]; then
	unset TF_VAR_site
fi

run() {
	echo "+ terraform $*" >&2
	(cd "$stack_dir" && terraform "$@")
}

# One state per stack per manager. While the stacks are on the placeholder local
# backend, the path is derived here so two stacks at the same site cannot end up
# sharing one state file.
uses_local_backend() { grep -q 'backend "local"' "$stack_dir/backend.tf" 2>/dev/null; }

# Every saved plan passes scripts/plan-guard.py: nothing live is destroyed unless
# allow-destroy.txt approves it, and an import tranche only imports. Run after
# each plan and again before each apply, so a hand-run apply is held to it too.
guard() {
	(cd "$stack_dir" && terraform show -json tfplan) |
		python3 "$REPO_ROOT/scripts/plan-guard.py" --site "$site" --stack "$stack" "$@"
}

backend_args=(-backend-config="$backend_file")
if uses_local_backend; then
	mkdir -p "$REPO_ROOT/.local-state"
	backend_args+=(-backend-config="path=$REPO_ROOT/.local-state/${site}-${stack}.tfstate")
fi

# Every manager has its own state, but they share the stack directory. So the
# working directory records which manager it was initialised for, and is
# initialised again whenever that changes. Without this, planning a second
# manager from the same checkout reuses the first one's state: the second plan
# then destroys the first manager's objects, through the second's credentials.
site_marker="$stack_dir/.terraform/nsx-site"
init_for_site() {
	run init -reconfigure -input=false "${backend_args[@]}" "$@"
	printf '%s\n' "$site" >"$site_marker"
}
ensure_init() {
	if [ "$(cat "$site_marker" 2>/dev/null)" != "$site" ]; then
		init_for_site
	fi
}

# A saved plan belongs to the manager it was made for. tfplan.site records that,
# and show and apply refuse a plan made for another manager, or one with no
# record, instead of applying it through this manager's credentials.
plan_site_file="$plan_file.site"
require_plan_for_site() {
	local recorded
	recorded="$(cat "$plan_site_file" 2>/dev/null || true)"
	if [ "$recorded" != "$site" ]; then
		echo "error: stacks/$stack/tfplan was made for '${recorded:-an unknown manager}', not '$site'. Run: scripts/tf.sh plan $stack $site" >&2
		exit 1
	fi
}

case "$cmd" in
init)
	init_for_site "$@"
	;;
plan)
	ensure_init
	rm -f "$plan_file" "$plan_site_file"
	run plan -out=tfplan -parallelism="$PARALLELISM" -input=false "$@"
	printf '%s\n' "$site" >"$plan_site_file"
	echo
	if ! guard; then
		echo
		echo "the plan is kept in stacks/$stack/tfplan for review, and will not be applied as it stands." >&2
		exit 2
	fi
	echo
	echo "plan written to stacks/$stack/tfplan — a sensitive artifact, not a PR attachment."
	echo "review it with: scripts/tf.sh show $stack $site"
	;;
show)
	[ -f "$plan_file" ] || {
		echo "error: no saved plan. Run: scripts/tf.sh plan $stack $site" >&2
		exit 1
	}
	require_plan_for_site
	ensure_init
	run show tfplan
	;;
apply)
	[ -f "$plan_file" ] || {
		echo "error: no saved plan. Never run a bare apply — it re-plans and can execute something nobody reviewed." >&2
		exit 1
	}
	if [ "${APPROVE:-}" != yes ]; then
		echo "error: apply requires an explicit human decision. Re-run with APPROVE=yes after reviewing the plan." >&2
		exit 1
	fi
	# A manager in mirror mode is still run from the UI; data/ is a copy of it.
	# Only its state is brought up to date: imports and refreshes, with the
	# read-only identity, so even a mistake here cannot write to NSX.
	observe=()
	if [ "${NSX_MODE:-}" = mirror ]; then
		if [ "${NSX_CRED_SCOPE:-}" != plan ]; then
			echo "error: $site is in mirror mode: only its state is updated, and only with the read-only credential (NSX_CRED_SCOPE=plan). Nothing else is applied to it until mode: managed; docs/IMPORT.md, \"Mirror mode\"." >&2
			exit 1
		fi
		observe=(--observe)
	fi
	require_plan_for_site
	ensure_init
	if ! guard ${observe[@]+"${observe[@]}"}; then
		echo "error: refusing to apply: the saved plan does not pass plan-guard (above)." >&2
		exit 2
	fi
	if uses_local_backend && [ "${ALLOW_LOCAL_STATE:-}" != 1 ]; then
		echo "error: stack $stack is still on the placeholder local backend. State carries the security posture of the estate and needs a remote, encrypted, locked backend before any real apply. Set ALLOW_LOCAL_STATE=1 only for a lab." >&2
		exit 1
	fi
	run apply -parallelism="$PARALLELISM" -input=false tfplan
	rm -f "$plan_file" "$plan_site_file"
	;;
drift)
	# Refresh-only: state against the live manager. Proposes nothing and
	# changes nothing; never touches the reviewed tfplan. With DRIFT_JSON set,
	# the plan is also written there as JSON. Exit 0 no drift, 2 drift.
	ensure_init
	set +e
	run plan -refresh-only -detailed-exitcode -input=false -out=drift.tfplan "$@"
	status=$?
	set -e
	if [ "$status" = 2 ] && [ -n "${DRIFT_JSON:-}" ]; then
		run show -json drift.tfplan >"$DRIFT_JSON" || status=1
	fi
	rm -f "$stack_dir/drift.tfplan"
	exit "$status"
	;;
*)
	usage 1
	;;
esac
SCAFFOLD_EOF
mark_executable scripts/tf.sh

write_file scripts/with-credentials.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Fetch NSX credentials and hand them to a command as environment variables.
#
#   scripts/with-credentials.sh <site> -- <command> [args...]
#
# The chain is: SDDC Manager API -> Vault -> environment -> terraform. Nothing
# is written to disk, to a Terraform variable, or to state. Reasons, in short:
#
#   * The vault_* Terraform data sources write the fetched secret into state in
#     plaintext. Never fetch a secret inside Terraform.
#   * TF_VAR_* values that reach a provider or resource argument land in state
#     and in saved plan files. 'sensitive = true' only redacts CLI output.
#
# Source of the secret, chosen with --from (default: auto):
#
#   --from auto    vault when VAULT_ADDR is set, otherwise env when a credential
#                  is found there, otherwise an error that says what to set.
#   --from env     read NSXT credentials from environment variables, which in
#                  GitLab CI are masked CI/CD variables. Nothing is stored on
#                  the runner host. The first of these that is set wins, with
#                  SITE the manager key upper-cased (hyd-gm01 -> HYD_GM01) and
#                  SCOPE the job's NSX_CRED_SCOPE (PLAN or APPLY):
#                    NSX_<SITE>_<SCOPE>_USERNAME / _PASSWORD
#                    NSX_<SITE>_USERNAME / _PASSWORD
#                    NSX_<SCOPE>_USERNAME / _PASSWORD
#                    NSX_USERNAME / _PASSWORD
#                  Plan jobs on a merge request cannot read protected
#                  variables, so give them a read-only NSX account in the PLAN
#                  variables and keep the write account in protected APPLY ones.
#   --from vault   read the KV v2 secret at the vault_path in the inventory.
#                  Needs VAULT_ADDR and VAULT_TOKEN in the environment.
#   --from vcf     ask SDDC Manager for the current NSX credentials.
#                  Needs SDDC_MANAGER_HOST, SDDC_USERNAME, SDDC_PASSWORD.
#
# Prefer short-lived credentials: Vault dynamic secrets or a rotated VCF service
# account beats a long-lived password in a KV store. Where VCF can issue client
# certificates, NSXT_CLIENT_AUTH_CERT is stronger than any password path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE=auto

die() {
	echo "error: $*" >&2
	exit 1
}

[ $# -ge 1 ] || die "usage: with-credentials.sh <site> [--from auto|vault|env|vcf] -- <command>"

SITE="$1"
shift

while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		SOURCE="${2:-}"
		shift 2
		;;
	--)
		shift
		break
		;;
	*) die "unexpected argument: $1" ;;
	esac
done

[ $# -ge 1 ] || die "no command given after --"

command -v curl >/dev/null 2>&1 || die "curl is required"

# Every NSX_* variable read here is upper-case, and names are case-sensitive:
# NSX_CA_FILE_hyd_gm01 would be silently ignored. Say so instead.
misnamed=""
while read -r v; do
	case "$v" in [Nn][Ss][Xx]_*) [ "$v" = "${v^^}" ] || misnamed="$misnamed $v->${v^^}" ;; esac
done < <(compgen -e)
[ -z "$misnamed" ] || die "CI/CD variable names are case-sensitive, so these are never read; rename them:$(printf '\n  %s' $misnamed)"

# Inventory lookup: host and vault path for this site. Never the secret.
exports="$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$SITE")" || die "cannot read manager '$SITE' from inventory/managers.yaml (above)"
eval "$exports"
[ -n "${NSX_HOST:-}" ] || die "site '$SITE' is not in inventory/managers.yaml"

export NSXT_MANAGER_HOST="$NSX_HOST"

# Managers (and SDDC Manager) sit on the management network. A job whose
# HTTPS_PROXY is set for internet access would otherwise send them through
# that proxy: Terraform and curl match NO_PROXY by name, and a CIDR entry such
# as 10.0.0.0/8 only covers IP literals, never an FQDN. The proxy then fails
# the request (often as "tls: unrecognized name" or a 403/502). Add the
# hosts themselves. NSX_MANAGER_VIA_PROXY=1 keeps the proxy for networks that
# really do reach managers through it.
bypass_proxy() {
	local h="$1" list
	h="${h#*://}"
	h="${h%%/*}"
	case "$h" in
	\[*)
		h="${h#\[}"
		h="${h%%]*}"
		;;
	*:*:*) ;;
	*) h="${h%%:*}" ;;
	esac
	[ -n "$h" ] || return 0
	list="${NO_PROXY:-${no_proxy:-}}"
	case ",${list// /}," in
	*",$h,"*) ;;
	*) list="${list:+$list,}$h" ;;
	esac
	export NO_PROXY="$list" no_proxy="$list"
}
if [ "${NSX_MANAGER_VIA_PROXY:-}" != 1 ]; then
	bypass_proxy "$NSX_HOST"
	[ -z "${SDDC_MANAGER_HOST:-}" ] || bypass_proxy "$SDDC_MANAGER_HOST"
fi

# Keep the session alive across requests — materially faster on large plans.
export NSXT_SESSION_AUTH="${NSXT_SESSION_AUTH:-true}"

# A deliberate choice, but never a silent one: every job that uses it says so.
case "${NSXT_ALLOW_UNVERIFIED_SSL:-}" in
true | TRUE | True | 1 | yes)
	echo "warning: TLS verification of $NSX_HOST is OFF (NSXT_ALLOW_UNVERIFIED_SSL): the manager's identity is not checked, and whoever answers at that address receives the credentials." >&2
	;;
esac

json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$@"; }

# Credential lookup in the environment. The prefixes are tried in this order and
# the first whose username and password are BOTH set and not blank wins. SITE is
# the manager key upper-cased, SCOPE the job's NSX_CRED_SCOPE (PLAN or APPLY).
env_credential_prefixes() {
	local key scope
	key="$(printf '%s' "$SITE" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')"
	scope="$(printf '%s' "${NSX_CRED_SCOPE:-}" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')"
	[ -z "$scope" ] || printf 'NSX_%s_%s\n' "$key" "$scope"
	printf 'NSX_%s\n' "$key"
	[ -z "$scope" ] || printf 'NSX_%s\n' "$scope"
	printf 'NSX\n'
}

# Prints "<username-var> <password-var>" for the first complete pair.
env_credential_vars() {
	local prefix u p
	while IFS= read -r prefix; do
		u="${prefix}_USERNAME"
		p="${prefix}_PASSWORD"
		if [[ "${!u:-}" =~ [^[:space:]] && "${!p:-}" =~ [^[:space:]] ]]; then
			printf '%s %s\n' "$u" "$p"
			return 0
		fi
	done < <(env_credential_prefixes)
	return 1
}

# The message an operator needs when nothing matched: what was looked for.
no_credentials_message() {
	local prefix list=""
	while IFS= read -r prefix; do
		list="${list:+$list, }${prefix}_USERNAME/_PASSWORD"
	done < <(env_credential_prefixes)
	printf "no NSX credentials for '%s'%s. Looked for %s (both of a pair, not blank). Or set VAULT_ADDR and VAULT_TOKEN. Variables must be visible to this job: protected variables are not available to merge request pipelines." \
		"$SITE" "${NSX_CRED_SCOPE:+ (scope: $NSX_CRED_SCOPE)}" "$list"
}

if [ "$SOURCE" = auto ]; then
	if [ -n "${VAULT_ADDR:-}" ]; then
		SOURCE=vault
	elif env_credential_vars >/dev/null; then
		SOURCE="env"
	else
		die "$(no_credentials_message)"
	fi
fi

case "$SOURCE" in
env)
	pair="$(env_credential_vars)" || die "$(no_credentials_message)"
	read -r u_var p_var <<<"$pair"
	NSXT_USERNAME="${!u_var}"
	NSXT_PASSWORD="${!p_var}"
	;;
vault)
	[ -n "${VAULT_ADDR:-}" ] || die "VAULT_ADDR is not set"
	[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is not set"
	[ -n "${NSX_VAULT_PATH:-}" ] || die "no vault_path recorded for site '$SITE'"

	# KV v2: /v1/<mount>/data/<path>. The inventory records the full path.
	response="$(curl -sS --fail-with-body \
		-H "X-Vault-Token: $VAULT_TOKEN" \
		"${VAULT_ADDR%/}/v1/${NSX_VAULT_PATH#/}")" ||
		die "vault read failed for $NSX_VAULT_PATH"

	NSXT_USERNAME="$(printf '%s' "$response" | json_get data data username)"
	NSXT_PASSWORD="$(printf '%s' "$response" | json_get data data password)"
	;;
vcf)
	[ -n "${SDDC_MANAGER_HOST:-}" ] || die "SDDC_MANAGER_HOST is not set"
	[ -n "${SDDC_USERNAME:-}" ] || die "SDDC_USERNAME is not set"
	[ -n "${SDDC_PASSWORD:-}" ] || die "SDDC_PASSWORD is not set"

	token="$(curl -sS --fail-with-body \
		-X POST "https://${SDDC_MANAGER_HOST}/v1/tokens" \
		-H 'Content-Type: application/json' \
		-d "$(python3 -c 'import json,os;print(json.dumps({"username":os.environ["SDDC_USERNAME"],"password":os.environ["SDDC_PASSWORD"]}))')" |
		json_get accessToken)" || die "SDDC Manager authentication failed"

	creds="$(curl -sS --fail-with-body \
		-H "Authorization: Bearer $token" \
		"https://${SDDC_MANAGER_HOST}/v1/credentials?resourceType=NSXT_MANAGER")" ||
		die "credential lookup failed"

	read -r NSXT_USERNAME NSXT_PASSWORD <<<"$(printf '%s' "$creds" | NSX_HOST="$NSX_HOST" python3 -c '
import json, os, sys
want = os.environ["NSX_HOST"].lower()
for e in json.load(sys.stdin).get("elements", []):
    res = e.get("resource", {})
    names = {str(res.get(k, "")).lower() for k in ("resourceName", "resourceIp", "resourceFqdn")}
    if want in names and e.get("accountType") in (None, "SYSTEM", "USER"):
        print(e["username"], e["password"])
        break
else:
    sys.exit("no NSX credential for " + want)
')" || die "no SDDC Manager credential matches $NSX_HOST"
	;;
*) die "unknown --from source: $SOURCE (auto|vault|env|vcf)" ;;
esac

[ -n "${NSXT_USERNAME:-}" ] || die "no username retrieved"
[ -n "${NSXT_PASSWORD:-}" ] || die "no password retrieved"
export NSXT_USERNAME NSXT_PASSWORD

exec "$@"
SCAFFOLD_EOF
mark_executable scripts/with-credentials.sh

write_file scripts/ci_matrix_lib.py <<'SCAFFOLD_EOF'
"""The run matrix, derived from inventory/managers.yaml.

Importable, unlike scripts/ci-matrix.py, whose hyphen keeps it out of reach of
an import statement. Everything that needs to know which stacks run against
which managers comes through here, so there is one definition and not three:
scripts/ci-matrix.py for humans and GitHub Actions, and
scripts/gitlab-child-pipeline.py for GitLab.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "inventory" / "managers.yaml"
MODES = ("managed", "mirror")


def mode_of(name: str, manager: dict) -> str:
    """managed or mirror, from the manager's mode in inventory/managers.yaml
    only: changing it is a reviewed merge request, like any other change."""
    mode = manager.get("mode", "managed")
    if mode not in MODES:
        sys.exit(f"error: {name}: mode {mode!r} in inventory/managers.yaml must be one of: {', '.join(MODES)}")
    return mode

# A Global Manager has no VM inventory and no local networking, so local-tags,
# local-network and platform are Local Manager stacks only.
GM_STACKS = ["global-security"]
LM_STACKS = ["local-security", "local-tags", "local-network", "platform"]


def misnamed_variables() -> list[tuple[str, str]]:
    """NSX_* variables set with lower-case letters, and the name they should
    have. Variable names are case-sensitive and every one these scripts read
    is upper-case, so NSX_CA_FILE_hyd_gm01 is simply never seen."""
    return sorted((k, k.upper()) for k in os.environ if k[:4].upper() == "NSX_" and k != k.upper())


def managers(strict: bool = True) -> dict:
    # A manager's mode once had a CI/CD variable too (1.3.0). It is read from
    # the inventory only now; a leftover variable must not look like it works.
    stale = sorted(k for k in os.environ if k.upper().startswith("NSX_MODE_"))
    if stale:
        sys.exit("error: a manager's mode comes from inventory/managers.yaml only (mode: mirror), not from "
                 "CI/CD variables. Delete these variables and set the mode there, in a merge request:\n"
                 + "\n".join(f"  {k}" for k in stale))
    wrong = misnamed_variables()
    if wrong:
        sys.exit("error: these CI/CD variables are never read, because names are case-sensitive:\n"
                 + "\n".join(f"  {k}  ->  rename it to {u}" for k, u in wrong))
    if not INVENTORY.exists():
        if strict:
            sys.exit(f"error: {INVENTORY} does not exist")
        return {}
    doc = load_yaml(INVENTORY.read_text()) or {}
    return doc.get("managers") or {}


def entries(stack_filter: str | None = None, strict: bool = False) -> list[dict]:
    out = []
    for name, m in sorted(managers(strict=strict).items()):
        if m.get("enabled") is False:
            continue
        role = m.get("role", "lm")
        allowed = m.get("stacks") or (GM_STACKS if role == "gm" else LM_STACKS)
        for stack in allowed:
            if stack_filter and stack != stack_filter:
                continue
            out.append(
                {
                    "site": name,
                    "stack": stack,
                    "role": role,
                    "host": m.get("host", ""),
                    "tier": m.get("tier", ""),
                    "vcf_instance": m.get("vcf_instance", ""),
                    "mode": mode_of(name, m),
                }
            )
    return out
SCAFFOLD_EOF

write_file scripts/ci-matrix.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Derive the run matrix from inventory/managers.yaml.

Adding an eleventh Local Manager is a data change, not a code change: CI reads
its matrix from here, and so does scripts/tf.sh.

  scripts/ci-matrix.py                      # JSON matrix, every stack
  scripts/ci-matrix.py --stack local-security
  scripts/ci-matrix.py --format lines
  scripts/ci-matrix.py --export lon1        # shell exports for one manager
"""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ci_matrix_lib import entries, managers, mode_of  # noqa: E402


def export(site: str) -> int:
    m = managers().get(site)
    if not m:
        print(f"error: site {site!r} is not in inventory/managers.yaml", file=sys.stderr)
        return 1
    pairs = {
        "NSX_HOST": m.get("host", ""),
        "NSX_ROLE": m.get("role", "lm"),
        "NSX_SITE": site,
        "NSX_TIER": m.get("tier", ""),
        "NSX_VAULT_PATH": m.get("vault_path", ""),
        "NSX_DOMAIN": m.get("domain", "default"),
        "NSX_VCF_INSTANCE": m.get("vcf_instance", ""),
        "NSX_MODE": mode_of(site, m),
    }
    for key, value in pairs.items():
        print(f"export {key}={shlex.quote(str(value))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stack", help="only include this stack")
    ap.add_argument("--format", choices=["json", "github", "lines"], default="json")
    ap.add_argument("--export", metavar="SITE", help="print shell exports for one manager")
    ap.add_argument("--managed-only", action="store_true",
                    help="leave out managers in mode: mirror (the apply matrix)")
    args = ap.parse_args()

    if args.export:
        return export(args.export)

    # Strict here: a human or a GitHub matrix asking for the inventory when it
    # does not exist is an error, not an empty list.
    rows = entries(args.stack, strict=True)
    if args.managed_only:
        rows = [r for r in rows if r["mode"] != "mirror"]
    if args.format == "lines":
        for r in rows:
            print(f"{r['site']}\t{r['stack']}\t{r['role']}\t{r['host']}")
    elif args.format == "github":
        print(json.dumps({"include": rows}))
    else:
        print(json.dumps(rows, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/ci-matrix.py

write_file scripts/yamlcompat.py <<'SCAFFOLD_EOF'
"""YAML loading with no mandatory third-party dependency.

In order of preference:

  1. PyYAML, when it is importable (the CI image has it).
  2. Terraform's own yamldecode, when terraform is on PATH: a full YAML parser,
     and the one the stacks use, so what validates here is what Terraform reads.
     Many documents are decoded in one terraform call (load_all), and the data
     files of this repository are all decoded on the first call.
  3. A reader for the subset of YAML this repository writes: block mappings,
     block and flow sequences, quoted and plain scalars, block scalars, comments.

NSX_YAML_FALLBACK=1 skips PyYAML, as on an image without it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

try:  # pragma: no cover - environment dependent
    import yaml as _pyyaml
except ImportError:  # pragma: no cover
    _pyyaml = None


def reader() -> str:
    """Which reader load_yaml uses here: pyyaml, terraform or subset."""
    if _pyyaml is not None and os.environ.get("NSX_YAML_FALLBACK") != "1":
        return "pyyaml"
    if shutil.which("terraform") and os.environ.get("NSX_YAML_NO_TERRAFORM") != "1" and not _TERRAFORM_BROKEN:
        return "terraform"
    return "subset"


def load_yaml(text: str) -> Any:
    return load_all([text])[0]


def load_all(texts: list[str]) -> list[Any]:
    """Several documents at once: one terraform call where terraform reads them."""
    how = reader()
    if how == "pyyaml":
        return [_pyyaml.safe_load(t) for t in texts]
    if how == "subset":
        return [_Parser(t).parse() for t in texts]
    try:
        return _load_with_terraform(texts)
    except _Unusable:
        # terraform is there but does not decode (a wrapper, a broken install):
        # the subset reader instead, never a false "not valid YAML".
        _TERRAFORM_BROKEN.append(True)
        return [_Parser(t).parse() for t in texts]


class _Unusable(Exception):
    pass


_TERRAFORM_BROKEN: list[bool] = []


def _load_with_terraform(texts: list[str]) -> list[Any]:
    if not _PRELOADED:
        _PRELOADED.append(True)
        root = Path(__file__).resolve().parent.parent
        _decode([p.read_text() for d in ("data", "inventory") for p in sorted((root / d).rglob("*.yaml"))])
    _decode([t for t in texts if _key(t) not in _DECODED])
    out = []
    for t in texts:
        value = _DECODED[_key(t)]
        if isinstance(value, YamlError):
            raise value
        out.append(value)
    return out


class YamlError(ValueError):
    pass


_DECODED: dict[str, Any] = {}
_PRELOADED: list[bool] = []


def _key(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _decode(texts: list[str]) -> None:
    """Decode with terraform's yamldecode, all in one call; on a failure, file by
    file, so each bad document gets its own error."""
    todo = list(dict.fromkeys(t for t in texts if _key(t) not in _DECODED))
    if not todo:
        return
    values = _terraform(todo)
    if values is None:
        if len(todo) == 1:
            _DECODED[_key(todo[0])] = YamlError(_LAST_ERROR[0] or "not valid YAML")
            return
        for t in todo:
            _decode([t])
        return
    for t, v in zip(todo, values):
        _DECODED[_key(t)] = v


_LAST_ERROR: list[str] = [""]


def _terraform(texts: list[str]) -> list[Any] | None:
    with tempfile.TemporaryDirectory() as work:
        for i, t in enumerate(texts):
            Path(work, f"{i:08d}.yaml").write_text(t)
        # fileset, not range(): range stops at 1024 values. Its order is the
        # files' names, which the zero padding makes the texts' order.
        expression = 'jsonencode([for f in sort(fileset(path.cwd, "*.yaml")) : yamldecode(file("${path.cwd}/${f}"))])'
        env = {k: v for k, v in os.environ.items() if not k.startswith("TF_CLI_ARGS")}
        env.update(CHECKPOINT_DISABLE="1", TF_IN_AUTOMATION="1")
        run = subprocess.run(["terraform", "console"], input=expression, cwd=work, env=env,
                             capture_output=True, text=True)
    if run.returncode != 0:
        # Terraform frames its message in box-drawing characters and wraps it.
        detail = re.sub(r"\x1b\[[0-9;]*m", "", run.stderr)
        detail = " ".join(re.sub(r"[│╷╵]", " ", detail).split())
        found = re.search(r'Call to function "(yamldecode|jsonencode)" failed: (.*?)(?:\.\s|\.$|$)', detail)
        if not found:
            raise _Unusable(detail)  # not about a document: terraform itself is unusable
        # A document that is not YAML, or holds what Terraform cannot carry (.inf, .nan).
        _LAST_ERROR[0] = found.group(2).strip() or "not valid YAML"
        return None
    literal = run.stdout.strip()
    # The console prints an HCL string: JSON's escapes, plus $${ and %%{.
    try:
        values = json.loads(json.loads(literal.replace("$${", "${").replace("%%{", "%{")))
    except ValueError as exc:
        raise _Unusable(literal[:200]) from exc
    if not isinstance(values, list) or len(values) != len(texts):
        raise _Unusable(literal[:200])
    return values


_INT = re.compile(r"^[+-]?\d+$")
_FLOAT = re.compile(r"^[+-]?(\d+\.\d*|\.\d+)([eE][+-]?\d+)?$")


class _Parser:
    def __init__(self, text: str) -> None:
        self.lines: list[tuple[int, str, int]] = []
        for lineno, raw in enumerate(text.splitlines(), 1):
            self.lines.append((_indent(raw), raw, lineno))
        self.raw_text = text
        self.pos = 0

    # -- line helpers ------------------------------------------------------
    def _skip(self) -> None:
        while self.pos < len(self.lines):
            _, raw, _ = self.lines[self.pos]
            stripped = raw.strip()
            if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
                self.pos += 1
            else:
                return

    def _peek(self):
        self._skip()
        if self.pos >= len(self.lines):
            return None
        return self.lines[self.pos]

    def parse(self) -> Any:
        value = self._parse_block(0)
        self._skip()
        if self.pos < len(self.lines):
            _, raw, lineno = self.lines[self.pos]
            raise YamlError(f"line {lineno}: unexpected content {raw.strip()!r}")
        return value

    def _parse_block(self, indent: int) -> Any:
        entry = self._peek()
        if entry is None:
            return None
        cur_indent, raw, _ = entry
        if cur_indent < indent:
            return None
        if raw.strip().startswith("- "):
            return self._parse_sequence(cur_indent)
        if raw.strip() == "-":
            return self._parse_sequence(cur_indent)
        return self._parse_mapping(cur_indent)

    def _parse_mapping(self, indent: int) -> dict:
        result: dict[str, Any] = {}
        while True:
            entry = self._peek()
            if entry is None:
                break
            cur_indent, raw, lineno = entry
            if cur_indent < indent:
                break
            if cur_indent > indent:
                raise YamlError(f"line {lineno}: unexpected indentation")
            content = _strip_comment(raw.strip())
            if content.startswith("- "):
                break
            key, sep, rest = _split_key(content)
            if not sep:
                raise YamlError(f"line {lineno}: expected 'key: value', got {content!r}")
            self.pos += 1
            result[key] = self._parse_value(rest.strip(), indent, lineno)
        return result

    def _parse_sequence(self, indent: int) -> list:
        items: list[Any] = []
        while True:
            entry = self._peek()
            if entry is None:
                break
            cur_indent, raw, lineno = entry
            if cur_indent < indent:
                break
            content = _strip_comment(raw.strip())
            if not content.startswith("-"):
                break
            if cur_indent > indent:
                raise YamlError(f"line {lineno}: unexpected indentation in sequence")
            rest = content[1:].strip()
            self.pos += 1
            if not rest:
                items.append(self._parse_block(indent + 1))
                continue
            key, sep, tail = _split_key(rest)
            if sep:
                # Inline mapping start: '- key: value', continuation lines are
                # indented past the dash.
                item: dict[str, Any] = {}
                item[key] = self._parse_value(tail.strip(), cur_indent + 2, lineno)
                nested = self._peek()
                if nested is not None and nested[0] > cur_indent:
                    item.update(self._parse_mapping(nested[0]))
                items.append(item)
            else:
                items.append(_scalar(rest))
        return items

    def _parse_value(self, rest: str, indent: int, lineno: int) -> Any:
        if rest in ("|", "|-", "|+", ">", ">-", ">+"):
            return self._parse_block_scalar(rest, indent)
        if rest == "":
            entry = self._peek()
            if entry is None or entry[0] < indent:
                return None
            if entry[0] == indent:
                # A sequence may sit at its key's own indent ("key:" then "- x"),
                # as many editors and PyYAML write it.
                content = entry[1].strip()
                if content == "-" or content.startswith("- "):
                    return self._parse_sequence(indent)
                return None
            return self._parse_block(entry[0])
        return _scalar(rest)

    def _parse_block_scalar(self, marker: str, indent: int) -> str:
        collected: list[str] = []
        block_indent = None
        while self.pos < len(self.lines):
            cur_indent, raw, _ = self.lines[self.pos]
            if raw.strip() == "":
                collected.append("")
                self.pos += 1
                continue
            if cur_indent <= indent:
                break
            if block_indent is None:
                block_indent = cur_indent
            collected.append(raw[block_indent:])
            self.pos += 1
        while collected and collected[-1] == "":
            collected.pop()
        if marker.startswith("|"):
            text = "\n".join(collected)
        else:
            folded: list[str] = []
            for line in collected:
                if line == "":
                    folded.append("\n")
                elif folded and folded[-1] not in ("", "\n"):
                    folded[-1] = folded[-1] + " " + line
                else:
                    folded.append(line)
            text = "".join(p if p == "\n" else p for p in folded)
        if marker.endswith("-"):
            return text
        return text + "\n"


def _indent(raw: str) -> int:
    return len(raw) - len(raw.lstrip(" "))


def _outside_quotes(text: str) -> list[bool]:
    """For each character: True when it is outside a quoted scalar.

    As in YAML, a quote opens a quoted scalar only where a scalar starts: at the
    beginning, or after a space, '[', '{' or ','. Mid-word it is an ordinary
    character, so a name like Azure-AD-IP's is a plain scalar. Inside '...' a
    doubled '' is a quote; inside "..." a backslash escapes the next character.
    """
    out: list[bool] = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote == "'":
            out.append(False)
            if ch == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    out.append(False)
                    i += 2
                    continue
                quote = None
        elif quote == '"':
            out.append(False)
            if ch == "\\" and i + 1 < len(text):
                out.append(False)
                i += 2
                continue
            if ch == '"':
                quote = None
        elif ch in "'\"" and (i == 0 or text[i - 1] in " \t[{,"):
            quote = ch
            out.append(False)
        else:
            out.append(True)
        i += 1
    return out


def _strip_comment(text: str) -> str:
    outside = _outside_quotes(text)
    for i, ch in enumerate(text):
        if ch == "#" and outside[i] and (i == 0 or text[i - 1] in " \t"):
            return text[:i].rstrip()
    return text.rstrip()


def _split_key(text: str) -> tuple[str, bool, str]:
    # A colon only separates a key when it is outside quotes and outside any
    # [...] or {...}: '- { scope: workload, tag: x }' is one flow mapping, not
    # a mapping whose first key is '{ scope'.
    outside = _outside_quotes(text)
    depth = 0
    for i, ch in enumerate(text):
        if not outside[i]:
            continue
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif depth == 0 and ch == ":" and (i + 1 == len(text) or text[i + 1] in " \t"):
            return _unquote(text[:i].strip()), True, text[i + 1 :]
    return text, False, ""


def _unquote(text: str) -> str:
    """A quoted scalar's value: '' is ' in single quotes; escapes in double quotes."""
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == text[-1] == '"':
        body, out, i = text[1:-1], [], 0
        simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "/": "/", " ": " "}
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nxt = body[i + 1]
                if nxt in simple:
                    out.append(simple[nxt])
                    i += 2
                    continue
                if nxt in "xuU":
                    width = {"x": 2, "u": 4, "U": 8}[nxt]
                    out.append(chr(int(body[i + 2 : i + 2 + width], 16)))
                    i += 2 + width
                    continue
            out.append(ch)
            i += 1
        return "".join(out)
    return text


def _scalar(text: str) -> Any:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [_scalar(p) for p in _split_flow(inner)]
    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        out = {}
        for part in _split_flow(inner):
            key, sep, value = _split_key(part)
            if not sep:
                raise YamlError(f"bad flow mapping entry: {part!r}")
            out[key] = _scalar(value)
        return out
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return _unquote(text)
    lowered = text.lower()
    if lowered in ("true", "yes", "on"):
        return True
    if lowered in ("false", "no", "off"):
        return False
    if lowered in ("null", "~", ""):
        return None
    if _INT.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


def _split_flow(text: str) -> list[str]:
    outside = _outside_quotes(text)
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    for i, ch in enumerate(text):
        if outside[i] and ch in "[{":
            depth += 1
        elif outside[i] and ch in "]}":
            depth -= 1
        elif outside[i] and ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
            continue
        current.append(ch)
    if current:
        parts.append("".join(current).strip())
    return [p for p in parts if p]
SCAFFOLD_EOF

write_file scripts/validate-data.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Validate everything under data/ and inventory/ before any plan runs.

This is the cheapest place to catch a malformed rule, and the last place before
it reaches a live firewall. It runs offline: no credentials, no network, no
Terraform.

Two layers:

  * structure — the JSON Schemas in data/schema/ are evaluated directly, so the
    schemas an editor uses and the schemas CI enforces are the same files.
  * meaning   — the things a schema cannot express: that a Global Manager policy
    only references Global Manager groups, that sequence numbers do not collide,
    that every tag scope is in the vocabulary, that no raw policy path or secret
    has been pasted into a data file.

  scripts/validate-data.py           # errors fail, warnings are printed
  scripts/validate-data.py --strict  # warnings fail too
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402


def is_ip_literal(value: str) -> bool:
    """An address, CIDR or range (a-b), as NSX takes in a rule's source or destination."""
    try:
        for part in value.split("-", 1):
            ipaddress.ip_network(part, strict=False)
        return True
    except ValueError:
        return False

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA = REPO_ROOT / "data"
SCHEMA_DIR = DATA / "schema"
INVENTORY = REPO_ROOT / "inventory" / "managers.yaml"

SECRET_KEYS = {"password", "passwd", "secret", "token", "api_key", "apikey", "credential", "private_key"}
FUZZY_OPERATORS = {"CONTAINS", "STARTSWITH", "ENDSWITH", "MATCHES"}

# House style for keys we create. NSX itself permits far more, and an imported
# estate is full of mixed case and underscores — those keys are the real nsx_ids
# and must be adopted verbatim, so the convention is only enforced on files this
# repository authored, not on anything listed in the import manifest.
CONVENTIONAL_KEY = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$")
AUTHORED_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$")


def imported_files() -> set[str]:
    path = DATA / ".import-manifest.json"
    if not path.exists():
        return set()
    try:
        return set(json.loads(path.read_text()).get("imported", []))
    except ValueError:
        return set()


def check_key_style(where: str, kind: str, key: str, imported: set[str], report: Report) -> None:
    # An imported key is the object's real nsx_id, as NSX allows it: anything
    # but '/', so '_h-app01', "VM's" and spaces too. An id this repository
    # authors is held to letters, digits, '.', '_' and '-'.
    if where in imported:
        return
    if not AUTHORED_KEY.match(str(key)):
        report.error(
            where,
            f"{kind} key {key!r}: a new object's id is letters, digits, '.', '_' and '-', starting "
            "with a letter or digit. (An object adopted from NSX keeps its own id, whatever it is.)",
        )
        return
    if CONVENTIONAL_KEY.match(str(key)):
        return
    report.warn(
        where,
        f"{kind} key {key!r} is not lowercase-hyphenated. Fine for an imported object — the "
        "key is its real nsx_id and must match — but new objects should follow the convention.",
    )


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f"{where}: {message}")


# --------------------------------------------------------------------------
# JSON Schema subset: exactly the keywords used by data/schema/*.json.
# --------------------------------------------------------------------------

def check_schema(instance, schema: dict, where: str, path: str, report: Report) -> None:
    def fail(message: str) -> None:
        report.error(where, f"{path or '<root>'}: {message}")

    expected = schema.get("type")
    if expected and not _type_ok(instance, expected):
        fail(f"expected {expected}, got {_type_name(instance)}")
        return

    if "enum" in schema and instance not in schema["enum"]:
        fail(f"{instance!r} is not one of {', '.join(map(str, schema['enum']))}")

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            fail("must not be empty")
        pattern = schema.get("pattern")
        if pattern and not re.match(pattern, instance):
            fail(f"{instance!r} does not match {pattern}")

    if isinstance(instance, int) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            fail(f"must be >= {schema['minimum']}, got {instance}")

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            fail(f"needs at least {schema['minItems']} item(s)")
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(instance):
                check_schema(item, item_schema, where, f"{path}[{i}]", report)

    if isinstance(instance, dict):
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            fail(f"needs at least {schema['minProperties']} entr(ies)")

        for key in schema.get("required", []):
            if key not in instance or instance[key] is None:
                fail(f"missing required key {key!r}")

        names = schema.get("propertyNames", {}).get("pattern")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)

        for key, value in instance.items():
            child = f"{path}.{key}" if path else key
            if names and key not in properties and not re.match(names, str(key)):
                fail(f"key {key!r} does not match {names}")
            if key in properties:
                check_schema(value, properties[key], where, child, report)
            elif isinstance(additional, dict):
                check_schema(value, additional, where, child, report)
            elif additional is False:
                fail(f"unknown key {key!r}")


def _type_ok(instance, expected: str) -> bool:
    if expected == "object":
        return isinstance(instance, dict)
    if expected == "array":
        return isinstance(instance, list)
    if expected == "string":
        return isinstance(instance, str)
    if expected == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if expected == "boolean":
        return isinstance(instance, bool)
    return True


def _type_name(instance) -> str:
    return {dict: "object", list: "array", str: "string", bool: "boolean", int: "integer"}.get(
        type(instance), type(instance).__name__
    )


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

def load_schema(name: str) -> dict | None:
    path = SCHEMA_DIR / name
    if not path.exists():
        return None
    return json.loads(path.read_text())


def load_docs(subdir: str, report: Report) -> dict[Path, dict]:
    directory = DATA / subdir
    docs: dict[Path, dict] = {}
    if not directory.is_dir():
        return docs
    for path in sorted(directory.glob("*.yaml")):
        try:
            doc = load_yaml(path.read_text())
        except Exception as exc:  # noqa: BLE001 - report, do not crash the run
            report.error(_rel(path), f"unparseable YAML: {exc}")
            continue
        if doc is None:
            report.warn(_rel(path), "file is empty")
            continue
        if not isinstance(doc, dict):
            report.error(_rel(path), "top level must be a mapping")
            continue
        docs[path] = doc
    return docs


def _rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def walk_strings(value, trail: str = ""):
    if isinstance(value, dict):
        for key, item in value.items():
            yield from walk_strings(item, f"{trail}.{key}" if trail else str(key))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from walk_strings(item, f"{trail}[{i}]")
    elif isinstance(value, str):
        yield trail, value


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_no_raw_paths(where: str, doc: dict, report: Report) -> None:
    for trail, value in walk_strings(doc):
        # Context profiles (App-ID, FQDN) have no module to resolve a name: a rule
        # refers to them by path, and only them.
        if ".profiles[" in trail and "/context-profiles/" in value:
            continue
        if value.startswith("/infra/") or value.startswith("/global-infra/"):
            report.error(
                where,
                f"{trail}: raw policy path {value!r}. Reference groups and services by "
                "logical name; the module resolves them to paths.",
            )


def check_no_secrets(where: str, doc: dict, report: Report) -> None:
    def walk(node, trail: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                child = f"{trail}.{key}" if trail else str(key)
                if str(key).lower() in SECRET_KEYS:
                    report.error(
                        where,
                        f"{child}: looks like a credential. Nothing sensitive is ever "
                        "committed — record the Vault path, never the secret.",
                    )
                walk(value, child)
        elif isinstance(node, list):
            for i, item in enumerate(node):
                walk(item, f"{trail}[{i}]")

    walk(doc, "")


def check_inventory(report: Report) -> dict:
    if not INVENTORY.exists():
        report.error("inventory/managers.yaml", "missing. Every stack run resolves its manager here.")
        return {}
    try:
        doc = load_yaml(INVENTORY.read_text()) or {}
    except Exception as exc:  # noqa: BLE001
        report.error("inventory/managers.yaml", f"unparseable YAML: {exc}")
        return {}

    where = "inventory/managers.yaml"
    schema = load_schema("managers.schema.json")
    if schema:
        check_schema(doc, schema, where, "", report)
    check_no_secrets(where, doc, report)

    managers = doc.get("managers") or {}
    gms = [k for k, m in managers.items() if m.get("role") == "gm"]
    if not gms:
        report.warn(where, "no Global Manager listed. The global-security stack has nothing to target.")
    elif len(gms) > 1:
        report.warn(
            where,
            f"{len(gms)} Global Managers listed ({', '.join(sorted(gms))}). More than one "
            "federation means global-security is several states, not one — open decision 7.",
        )

    for name, m in managers.items():
        role = m.get("role")
        if role == "gm" and m.get("domain") not in (None, "default"):
            report.warn(
                where,
                f"{name}: domain {m.get('domain')!r}. On a Global Manager, global objects live in "
                "domain 'default'; another domain is one location's. Leave it out unless that is the intent.",
            )
        for stack in m.get("stacks") or []:
            if role == "gm" and stack != "global-security":
                report.error(where, f"{name}: a Global Manager cannot run the {stack} stack.")
            if role == "lm" and stack == "global-security":
                report.error(where, f"{name}: global-security runs against the GM, not a Local Manager.")
        backend = REPO_ROOT / "envs" / f"{name}.backend.hcl"
        if m.get("enabled") is not False and not backend.exists():
            report.warn(where, f"{name}: no envs/{name}.backend.hcl — nothing can initialise for this manager.")

    return managers


def as_date(value) -> date:
    """A YAML date as any reader gives it: a date (PyYAML), or a string, with a
    time (Terraform's yamldecode: 2026-11-01T00:00:00Z) or without."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value)
    if not re.match(r"^\d{4}-\d{2}-\d{2}(T00:00:00(Z|[+-]00:00)?)?$", text):
        raise ValueError(text)
    return date.fromisoformat(text[:10])


def check_delegations(managers: dict, report: Report) -> None:
    """inventory/delegations.yaml: standby approvals for change control
    (scripts/change-control.py). Each hands one Maintainer's approval to another
    engineer until a date; the file is reviewed like any change."""
    path = REPO_ROOT / "inventory" / "delegations.yaml"
    if not path.exists():
        return
    where = "inventory/delegations.yaml"
    try:
        doc = load_yaml(path.read_text()) or {}
    except Exception as exc:  # noqa: BLE001
        report.error(where, f"unparseable YAML: {exc}")
        return
    today = datetime.now(timezone.utc).date()
    for i, d in enumerate(doc.get("delegations") or []):
        label = f"delegations[{i}]"
        if not isinstance(d, dict):
            report.error(where, f"{label}: expected from, to, until (and a reason)")
            continue
        unknown = set(d) - {"from", "to", "until", "reason"}
        if unknown:
            report.error(where, f"{label}: unknown key(s) {', '.join(sorted(unknown))}")
        if not d.get("from") or not d.get("to"):
            report.error(where, f"{label}: needs both from (the Maintainer) and to (who stands in)")
        elif d["from"] == d["to"]:
            report.error(where, f"{label}: {d['from']} cannot stand in for themselves")
        try:
            until = as_date(d.get("until"))
        except ValueError:
            report.error(where, f"{label}: until must be a date, YYYY-MM-DD (the last day it applies, UTC)")
            continue
        if not d.get("reason"):
            report.warn(where, f"{label}: no reason given; say why, for whoever reads the approvals later")
        if until < today:
            report.warn(where, f"{label}: ended on {until}; remove it")
        elif (until - today).days > 31:
            report.warn(where, f"{label}: runs until {until}, more than a month. A standby approval is for a "
                               "set period; for a lasting change, make the engineer a Maintainer.")


def check_tag_scopes(report: Report) -> dict:
    path = SCHEMA_DIR / "tag-scopes.yaml"
    if not path.exists():
        report.error("data/schema/tag-scopes.yaml", "missing. The tag vocabulary is a contract, not an option.")
        return {}
    try:
        doc = load_yaml(path.read_text()) or {}
    except Exception as exc:  # noqa: BLE001
        report.error("data/schema/tag-scopes.yaml", f"unparseable YAML: {exc}")
        return {}
    return doc.get("scopes") or {}


def check_tag_value(where: str, label: str, member_type: str, value: str, scopes: dict, report: Report,
                    imported: bool = False) -> None:
    # In a file adopted from NSX the tag is a fact of the estate: what it does
    # not match in the vocabulary is reported, and the copy still validates.
    flag = report.warn if imported else report.error
    if "|" not in value:
        report.warn(
            where,
            f"{label}: tag {value!r} has no scope. Scope every tag as 'scope|value' so the "
            "vocabulary can be enforced.",
        )
        return
    scope, _, tag_value = value.partition("|")
    if scope not in scopes:
        flag(
            where,
            f"{label}: tag scope {scope!r} is not in data/schema/tag-scopes.yaml. Adding a "
            "scope is a reviewed change; a typo here silently empties the group.",
        )
        return
    spec = scopes[scope] or {}
    allowed = spec.get("values")
    if allowed and tag_value not in allowed:
        flag(where, f"{label}: {tag_value!r} is not a permitted value for scope {scope!r} ({', '.join(allowed)})")
    applies = spec.get("applies_to")
    if applies and member_type and member_type not in applies:
        report.warn(where, f"{label}: scope {scope!r} is documented for {', '.join(applies)}, not {member_type}")


def check_groups(docs: dict[Path, dict], scopes: dict, sites: set[str], imported: set[str], report: Report) -> dict[str, dict]:
    schema = load_schema("group.schema.json")
    groups: dict[str, dict] = {}
    origin: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        for name, group in (doc.get("groups") or {}).items():
            if not isinstance(group, dict):
                continue
            if name in groups:
                report.error(where, f"group {name!r} is also defined in {origin[name]}. Group names are unique estate-wide.")
                continue
            groups[name] = group
            origin[name] = where
            check_key_style(where, "group", name, imported, report)

            owner = group.get("owner")
            group_sites = group.get("sites") or []
            if owner == "gm" and group_sites:
                report.error(where, f"{name}: a Global Manager group has no site list; its span comes from its domain.")
            if owner == "lm" and not group_sites:
                report.error(where, f"{name}: a site-local group must list the sites it is created on.")
            for site in group_sites:
                if site != "*" and site not in sites:
                    report.error(where, f"{name}: site {site!r} is not in inventory/managers.yaml")

            criteria = group.get("criteria") or []
            static = any(c.get("ip_addresses") or c.get("external_ids") or c.get("mac_addresses") for c in criteria if isinstance(c, dict))
            if not criteria and not group.get("why_empty"):
                report.error(where, f"{name}: no criteria. A group with no membership matches nothing; give it criteria, or a why_empty note saying why it exists.")
            for i, criterion in enumerate(criteria):
                if isinstance(criterion, dict) and bool(criterion.get("external_ids")) != bool(criterion.get("member_type")):
                    report.error(where, f"{name}.criteria[{i}]: external_ids and member_type go together: the ids name members of that type.")
            if static and not group.get("why_static"):
                report.error(
                    where,
                    f"{name}: static membership needs a why_static note saying what would let it "
                    "become dynamic. Nothing updates a static group when the estate changes.",
                )
            if len(criteria) > 1 and not group.get("conjunction"):
                report.error(where, f"{name}: {len(criteria)} criteria blocks need an explicit conjunction (AND/OR).")

            for i, criterion in enumerate(criteria):
                if not isinstance(criterion, dict):
                    continue
                for j, condition in enumerate(criterion.get("conditions") or []):
                    label = f"{name}.criteria[{i}].conditions[{j}]"
                    operator = condition.get("operator")
                    if operator in FUZZY_OPERATORS:
                        report.warn(
                            where,
                            f"{label}: {operator} on a tag acquires unintended members — "
                            "'app|payments' also matches 'app|payments-test'. Prefer EQUALS.",
                        )
                    if condition.get("key") == "Tag":
                        check_tag_value(where, label, condition.get("member_type", ""), str(condition.get("value", "")), scopes, report,
                                        imported=where in imported)

    # Nested membership: the stacks resolve groups in two passes, so a composite
    # group may only reference a base group.
    composite = {
        name
        for name, g in groups.items()
        if any(isinstance(c, dict) and c.get("member_groups") for c in (g.get("criteria") or []))
    }
    for name in sorted(composite):
        for criterion in groups[name].get("criteria") or []:
            for member in (criterion.get("member_groups") or []) if isinstance(criterion, dict) else []:
                target = origin.get(name, "data/groups")
                if member == name:
                    report.error(target, f"{name}: references itself.")
                elif member not in groups:
                    report.error(target, f"{name}: member_groups references undefined group {member!r}")
                elif member in composite:
                    report.error(
                        target,
                        f"{name}: references {member!r}, which itself nests groups. The stacks "
                        "resolve nested groups in two passes only; flatten one level.",
                    )
                elif groups[member].get("owner") != groups[name].get("owner"):
                    report.error(target, f"{name} ({groups[name].get('owner')}) nests {member!r} ({groups[member].get('owner')}) — that crosses the GM/LM boundary.")

    return groups


def check_services(docs: dict[Path, dict], sites: set[str], imported: set[str], report: Report) -> dict[str, dict]:
    schema = load_schema("service.schema.json")
    services: dict[str, dict] = {}
    origin: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        for name, display in (doc.get("predefined") or {}).items():
            # A predefined service is a lookup, not an object anyone owns: two
            # files (a GM's and an LM's, or two adoptions) may both name it.
            known = services.get(name)
            if known and known["kind"] == "predefined" and known["display_name"] == display:
                continue
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            services[name] = {"kind": "predefined", "display_name": display, "owner": None}
            origin[name] = where
            check_key_style(where, "service", name, imported, report)

        for name, display in (doc.get("predefined_ids") or {}).items():
            known = services.get(name)
            if known and known["kind"] == "predefined":
                continue  # the same service NSX ships with, named by several adoptions
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            services[name] = {"kind": "predefined", "display_name": display, "owner": None}
            origin[name] = where

        for name, service in (doc.get("custom") or {}).items():
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            if not any(service.get(k) for k in ("l4_port_set", "icmp", "ip_protocol", "algorithm", "igmp", "ether_type")):
                report.error(where, f"service {name!r} has no entries — it would match nothing.")
            service_sites = service.get("sites") or []
            if service.get("owner", "gm") == "lm" and not service_sites:
                report.error(
                    where,
                    f"service {name!r} is site-local but lists no sites, so it is created on EVERY Local "
                    "Manager. List the sites, or sites: [\"*\"] if that is the intent.",
                )
            for site in service_sites:
                if site != "*" and site not in sites:
                    report.error(where, f"service {name!r}: site {site!r} is not in inventory/managers.yaml")
            services[name] = {"kind": "custom", "owner": service.get("owner", "gm")}
            origin[name] = where
            check_key_style(where, "service", name, imported, report)

    return services


def check_policies(
    docs: dict[Path, dict],
    groups: dict[str, dict],
    services: dict[str, dict],
    sites: set[str],
    imported: set[str],
    report: Report,
) -> None:
    schema = load_schema("policy.schema.json")
    seen_ids: dict[str, str] = {}
    seen_names: dict[tuple, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        policy = doc.get("policy") or {}
        rules = doc.get("rules") or {}
        owner = policy.get("owner")
        policy_id = policy.get("id")
        policy_sites = policy.get("sites") or []

        if policy_id:
            if policy_id in seen_ids:
                report.error(where, f"policy id {policy_id!r} is also used in {seen_ids[policy_id]}")
            seen_ids[policy_id] = where
            check_key_style(where, "policy id", policy_id, imported, report)

        # A policy is reused, not recreated. Two data files describing the same
        # policy is how a second "policy X" gets built beside the first: same
        # name, same category, same span, different nsx_id. Adding a rule to an
        # existing policy means editing its file — scripts/add-rule.py does the
        # lookup for you.
        # NSX itself allows two policies with one display name (different ids):
        # two such policies adopted from a manager are both real, and both stay.
        name_key = (policy.get("name"), policy.get("category"), owner, tuple(sorted(policy_sites)))
        if policy.get("name") and name_key in seen_names and not (where in imported and seen_names[name_key] in imported):
            report.error(
                where,
                f"policy {policy.get('name')!r} ({policy.get('category')}) is already defined in "
                f"{seen_names[name_key]}. Add the rule to that policy instead of declaring a "
                f"second one: scripts/add-rule.py --policy {policy_id or policy.get('name')} ...",
            )
        seen_names[name_key] = where

        if owner == "lm" and not policy_sites:
            report.error(where, "a site-local policy must list the sites it applies to.")
        if owner == "gm" and policy_sites:
            report.error(where, "a Global Manager policy has no site list; its span comes from its domain.")
        for site in policy_sites:
            if site != "*" and site not in sites:
                report.error(where, f"site {site!r} is not in inventory/managers.yaml")

        if policy.get("category") == "Emergency":
            report.warn(
                where,
                "Emergency category. This is a RESTRICTED change class — change advisory, "
                "named approver, rollback plan, out-of-hours.",
            )

        if policy.get("rule_management") == "inline" and len(rules) > 8:
            report.warn(
                where,
                f"{len(rules)} rules managed inline. Inline blocks rewrite the whole policy on "
                "every change; use rule_management: standalone for anything with churn.",
            )

        def resolve_group(name: str, label: str, literal_ok: bool = False) -> None:
            if name == "ANY":
                return
            group = groups.get(name)
            if group is None and literal_ok and is_ip_literal(name):
                return
            if group is None:
                hint = " (an IP address is allowed in a rule's source or destination, not in its Apply To)" if is_ip_literal(name) else ""
                report.error(where, f"{label}: references undefined group {name!r}{hint}")
                return
            if owner == "gm" and group.get("owner") != "gm":
                report.error(
                    where,
                    f"{label}: a Global Manager policy references site-local group {name!r}. "
                    "Federation cannot span an LM group; create it on the GM.",
                )
            if owner == "lm" and group.get("owner") == "lm":
                missing = [s for s in policy_sites if s != "*" and s not in (group.get("sites") or []) and "*" not in (group.get("sites") or [])]
                if missing:
                    report.error(where, f"{label}: group {name!r} does not exist at site(s) {', '.join(missing)}")
            if owner == "lm" and group.get("owner") == "gm":
                report.warn(
                    where,
                    f"{label}: a site-local policy references GM-owned group {name!r}. Confirm "
                    "your NSX version lets a Local Manager policy consume a GM group before relying on it.",
                )

        for name in policy.get("scope") or []:
            resolve_group(name, "policy.scope")

        sequence_numbers: dict[int, str] = {}
        for key, rule in rules.items():
            if not isinstance(rule, dict):
                continue
            label = f"rules.{key}"
            check_key_style(where, "rule", key, imported, report)

            seq = rule.get("sequence_number")
            if isinstance(seq, int):
                if seq in sequence_numbers:
                    # NSX orders equal numbers itself; adopted as they are, they are noted.
                    (report.warn if where in imported else report.error)(
                        where, f"{label}: sequence_number {seq} already used by {sequence_numbers[seq]}. Sequence numbers are allocated, not guessed.")
                sequence_numbers[seq] = label
                if seq % 100 != 0 and where not in imported:
                    report.warn(where, f"{label}: sequence_number {seq} is not a multiple of 100. Gaps are what let a rule be inserted later without renumbering.")

            for field in ("source_groups", "destination_groups", "scope"):
                for name in rule.get(field) or []:
                    resolve_group(name, f"{label}.{field}", literal_ok=field != "scope")

            for name in rule.get("services") or []:
                if name == "ANY":
                    continue
                service = services.get(name)
                if service is None:
                    report.error(where, f"{label}.services: references undefined service {name!r}")
                elif owner == "gm" and service["kind"] == "custom" and service.get("owner") != "gm":
                    report.error(where, f"{label}.services: {name!r} is a site-local service; a GM policy cannot reference it.")

            if rule.get("action") in ("DROP", "REJECT") and rule.get("logged") is False:
                report.warn(where, f"{label}: a drop with logging off is invisible during an incident.")

            if not (rule.get("source_groups") or rule.get("destination_groups")):
                report.warn(where, f"{label}: neither source nor destination is set — this matches everything in scope.")


BACKEND_SECRET = re.compile(
    r"^\s*(password|token|secret_key|access_key|secret_access_key|client_secret"
    r"|sas_token|shared_access_key|tf_http_password)\s*=",
    re.IGNORECASE,
)


def check_env_backends(report: Report) -> None:
    """envs/*.backend.hcl is committed, so a backend credential in it is a leak.

    The HTTP backend makes this easy to get wrong — the GitLab token is just
    another key in the same file as the address. It belongs in TF_HTTP_PASSWORD.
    """
    directory = REPO_ROOT / "envs"
    if not directory.is_dir():
        return

    for path in sorted(directory.glob("*.hcl")):
        where = _rel(path)
        try:
            lines = path.read_text().splitlines()
        except OSError as exc:
            report.error(where, f"unreadable: {exc}")
            continue

        body = [ln for ln in lines if not ln.lstrip().startswith("#")]

        for i, line in enumerate(body, 1):
            if BACKEND_SECRET.match(line):
                key = line.split("=", 1)[0].strip()
                report.error(
                    where,
                    f"{key!r} is a backend credential and this file is committed. "
                    "Pass it through the environment instead — TF_HTTP_PASSWORD for the "
                    "http backend, the provider's own variables or an instance role for "
                    "the object stores.",
                )

        joined = "\n".join(body)
        if "address" in joined and "lock_address" not in joined:
            report.error(
                where,
                "http backend with no lock_address. Without it Terraform does not lock, "
                "and two concurrent runs against this site will corrupt the state.",
            )


def check_vm_tags(scopes: dict, sites: set[str], report: Report) -> int:
    """VM tag assignments, the one place this repository writes tags itself.

    nsxt_policy_vm_tags replaces a VM's entire tag set, so the checks here are
    about ownership rather than syntax: that no scope another system owns is
    written from Terraform, and that no VM is claimed twice.
    """
    schema = load_schema("vm-tags.schema.json")
    directory = DATA / "vm-tags"
    if not directory.is_dir():
        return 0

    seen_vms: dict[str, str] = {}
    seen_ids: dict[str, str] = {}
    total = 0

    for path in sorted(directory.glob("*.yaml")):
        where = _rel(path)
        try:
            doc = load_yaml(path.read_text()) or {}
        except Exception as exc:  # noqa: BLE001
            report.error(where, f"unparseable YAML: {exc}")
            continue
        if not isinstance(doc, dict):
            report.error(where, "top level must be a mapping")
            continue
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)
        check_no_secrets(where, doc, report)

        site = doc.get("site")
        if site and site != path.stem:
            report.error(where, f"site {site!r} does not match the filename; the stack loads data/vm-tags/<site>.yaml")
        if site and sites and site not in sites:
            report.error(where, f"site {site!r} is not in inventory/managers.yaml")

        vms = doc.get("vms") or {}
        total += len(vms)

        if len(vms) > 200:
            report.warn(
                where,
                f"{len(vms)} VMs tagged from Terraform. That is one resource per VM and one "
                "refresh per plan; past a few hundred, tagging belongs in the provisioning "
                "system and this repository should consume the tags instead (docs/TAGGING.md).",
            )

        for name, vm in vms.items():
            if not isinstance(vm, dict):
                continue
            label = f"vms.{name}"

            # A VM tagged from two files means two resources racing for one tag
            # set: each apply reverts the other, forever.
            if name in seen_vms:
                report.error(where, f"{label}: VM {name!r} is also tagged in {seen_vms[name]}. The whole tag set is replaced on apply, so two files fight over it.")
            seen_vms[name] = where

            external_id = vm.get("external_id")
            if external_id:
                if external_id in seen_ids:
                    report.error(where, f"{label}: external_id {external_id!r} is also tagged in {seen_ids[external_id]}")
                seen_ids[external_id] = where
            elif vm.get("display_name"):
                report.warn(
                    where,
                    f"{label}: identified by display_name. A rename in vCenter silently moves the "
                    "tags to whatever takes the name; external_id survives it.",
                )

            for i, tag in enumerate(vm.get("tags") or []):
                if not isinstance(tag, dict):
                    continue
                scope = str(tag.get("scope", ""))
                check_tag_value(where, f"{label}.tags[{i}]", "VirtualMachine", f"{scope}|{tag.get('tag')}", scopes, report)

                # The ownership rule, and the reason this file type exists at all.
                spec = scopes.get(scope) or {}
                owner = spec.get("owner")
                if scope in scopes and owner != "terraform":
                    report.error(
                        where,
                        f"{label}.tags[{i}]: scope {scope!r} is owned by {owner!r} in "
                        "data/schema/tag-scopes.yaml, so Terraform must not write it. "
                        "nsxt_policy_vm_tags replaces the VM's whole tag set, so the two systems "
                        "would overwrite each other on every run. Either tag from that system, or "
                        "move the scope to 'owner: terraform' — a reviewed change declaring that "
                        "nothing else tags these VMs.",
                    )

            for i, port in enumerate(vm.get("ports") or []):
                if not isinstance(port, dict):
                    continue
                for j, tag in enumerate(port.get("tags") or []):
                    if not isinstance(tag, dict):
                        continue
                    check_tag_value(
                        where,
                        f"{label}.ports[{i}].tags[{j}]",
                        "SegmentPort",
                        f"{tag.get('scope')}|{tag.get('tag')}",
                        scopes,
                        report,
                    )

    return total


def check_site_files(subdir: str, schema_name: str, scopes: dict, sites: set[str], report: Report) -> None:
    schema = load_schema(schema_name)
    directory = DATA / subdir
    if not directory.is_dir():
        return

    for path in sorted(directory.glob("*.yaml")):
        where = _rel(path)
        try:
            doc = load_yaml(path.read_text()) or {}
        except Exception as exc:  # noqa: BLE001
            report.error(where, f"unparseable YAML: {exc}")
            continue
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        site = doc.get("site")
        if site and site != path.stem:
            report.error(where, f"site {site!r} does not match the filename; the stack loads data/{subdir}/<site>.yaml")
        if site and sites and site not in sites:
            report.error(where, f"site {site!r} is not in inventory/managers.yaml")

        tier1s = doc.get("tier1s") or {}
        for name, segment in (doc.get("segments") or {}).items():
            if not isinstance(segment, dict):
                continue
            tier1 = segment.get("tier1")
            if tier1 and tier1 not in tier1s:
                report.error(where, f"segment {name!r} connects to undefined tier1 {tier1!r}")
            for i, tag in enumerate(segment.get("tags") or []):
                check_tag_value(where, f"segments.{name}.tags[{i}]", "Segment", f"{tag.get('scope')}|{tag.get('tag')}", scopes, report)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="treat warnings as failures")
    ap.add_argument("--quiet", action="store_true", help="print only the summary")
    args = ap.parse_args()

    report = Report()

    managers = check_inventory(report)
    sites = set(managers.keys())
    scopes = check_tag_scopes(report)

    group_docs = load_docs("groups", report)
    service_docs = load_docs("services", report)
    policy_docs = load_docs("policies", report)

    imported = imported_files()
    groups = check_groups(group_docs, scopes, sites, imported, report)
    services = check_services(service_docs, sites, imported, report)
    check_policies(policy_docs, groups, services, sites, imported, report)
    tagged_vms = check_vm_tags(scopes, sites, report)
    check_env_backends(report)
    check_delegations(managers, report)
    check_site_files("network", "network.schema.json", scopes, sites, report)
    check_site_files("platform", "platform.schema.json", scopes, sites, report)

    if not args.quiet:
        for message in report.warnings:
            print(f"warning  {message}")
        for message in report.errors:
            print(f"ERROR    {message}")
        if report.warnings or report.errors:
            print()

    print(
        f"checked {len(managers)} manager(s), {len(groups)} group(s), "
        f"{len(services)} service(s), {len(policy_docs)} policy file(s), "
        f"{tagged_vms} tagged VM(s): "
        f"{len(report.errors)} error(s), {len(report.warnings)} warning(s)"
    )

    import yamlcompat  # noqa: PLC0415
    how = yamlcompat.reader()
    if how == "terraform":
        print("note: PyYAML is not installed here: YAML was read with Terraform's yamldecode, as the stacks read it.")
    elif how == "subset":
        print("note: neither PyYAML nor terraform is here: YAML was read with the built-in reader, which accepts the "
              "YAML this repository writes but not every form YAML allows.")

    if report.errors:
        return 1
    if args.strict and report.warnings:
        print("--strict: warnings are failures")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/validate-data.py

write_file scripts/add-rule.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Add a rule to an EXISTING policy. Never create a second one beside it.

A policy is reused, not recreated. If policy X exists, a new rule for X belongs
inside X — a second policy with the same name means two nsx_ids, two orderings,
and rules that silently never match because the wrong policy won the sequence.

So this tool looks the policy up first, and only creates one when told to:

  # add a rule to whatever file already holds prod-payments
  scripts/add-rule.py --policy prod-payments \
      --rule web-from-monitoring \
      --action ALLOW --direction IN \
      --source prod-monitoring --destination prod-payments-web \
      --service https --scope prod-payments-web

  # policy does not exist yet — refuses unless you say so explicitly
  scripts/add-rule.py --policy brand-new ... --create-policy \
      --category Application --owner gm

The policy is found by id, then by display name, across every file in
data/policies/. The rule is appended to that file, in place, preserving the
comments around it. Sequence numbers are allocated, not guessed: the next free
multiple of 100 after the highest existing rule, so there is room to insert.

Nothing here talks to NSX. Run 'make validate' and open a PR as usual.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
POLICY_DIR = REPO_ROOT / "data" / "policies"


def find_policy(name: str) -> tuple[Path, dict] | None:
    """Locate the file already holding this policy. Id first, then display name."""
    by_name = None
    for path in sorted(POLICY_DIR.glob("*.yaml")):
        doc = load_yaml(path.read_text()) or {}
        policy = doc.get("policy") or {}
        if policy.get("id") == name:
            return path, doc
        if policy.get("name") == name:
            by_name = (path, doc)
    return by_name


def next_sequence(rules: dict) -> int:
    highest = 0
    for rule in rules.values():
        if isinstance(rule, dict) and isinstance(rule.get("sequence_number"), int):
            highest = max(highest, rule["sequence_number"])
    return highest + 100 if highest else 100


def yaml_list(values: list[str]) -> str:
    return "[" + ", ".join(values) + "]"


def render_rule(key: str, args, sequence: int) -> str:
    lines = [f"\n  {key}:", f"    name: {args.rule}"]
    if args.description:
        lines.append(f"    description: {args.description}")
    lines.append(f"    sequence_number: {sequence}")
    lines.append(f"    action: {args.action}")
    lines.append(f"    direction: {args.direction}")
    if args.source:
        lines.append(f"    source_groups: {yaml_list(args.source)}")
    if args.destination:
        lines.append(f"    destination_groups: {yaml_list(args.destination)}")
    if args.service:
        lines.append(f"    services: {yaml_list(args.service)}")
    lines.append(f"    scope: {yaml_list(args.scope)}")
    lines.append(f"    logged: {'true' if not args.no_log else 'false'}")
    return "\n".join(lines) + "\n"


def create_policy_file(args) -> Path:
    path = POLICY_DIR / f"{args.policy}.yaml"
    if path.exists():
        sys.exit(f"error: {path} already exists")
    sites = f"\n  sites: {yaml_list(args.sites)}" if args.owner == "lm" else ""
    path.write_text(
        f"""# {args.policy}
#
# Created by scripts/add-rule.py --create-policy. Review the header before
# merging: category and scope decide where these rules land and how far they
# are pushed.

policy:
  id: {args.policy}
  name: {args.policy}
  category: {args.category}
  owner: {args.owner}{sites}
  sequence_number: {args.policy_sequence}
  rule_management: standalone
  scope: {yaml_list(args.scope)}

rules:
"""
    )
    return path


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--policy", required=True, help="policy id or display name; looked up first")
    ap.add_argument("--rule", required=True, help="rule key and display name")
    ap.add_argument("--action", default="ALLOW", choices=["ALLOW", "DROP", "REJECT", "JUMP_TO_APPLICATION"])
    ap.add_argument("--direction", default="IN", choices=["IN", "OUT", "IN_OUT"])
    ap.add_argument("--source", action="append", default=[], metavar="GROUP")
    ap.add_argument("--destination", action="append", default=[], metavar="GROUP")
    ap.add_argument("--service", action="append", default=[], metavar="SERVICE")
    ap.add_argument("--scope", action="append", default=[], metavar="GROUP", help="Apply To. Mandatory.")
    ap.add_argument("--description")
    ap.add_argument("--sequence", type=int, help="override the allocated sequence number")
    ap.add_argument("--no-log", action="store_true", help="disable logging on this rule")
    ap.add_argument(
        "--create-policy",
        action="store_true",
        help="create the policy if it genuinely does not exist. Without this, a missing policy is an error.",
    )
    ap.add_argument("--category", default="Application", help="only with --create-policy")
    ap.add_argument("--owner", default="gm", choices=["gm", "lm"], help="only with --create-policy")
    ap.add_argument("--sites", action="append", default=[], help="only with --create-policy --owner lm")
    ap.add_argument("--policy-sequence", type=int, default=1000, help="only with --create-policy")
    ap.add_argument("--dry-run", action="store_true", help="print the rule; write nothing")
    args = ap.parse_args()

    if not args.scope:
        sys.exit(
            "error: --scope is mandatory. A rule without Apply To is pushed to every "
            "hypervisor in the policy's span."
        )
    if not re.match(r"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", args.rule):
        sys.exit(f"error: rule key {args.rule!r} must be lowercase, hyphen-separated")

    found = find_policy(args.policy)

    if found is None:
        if not args.create_policy:
            existing = []
            for path in sorted(POLICY_DIR.glob("*.yaml")):
                doc = load_yaml(path.read_text()) or {}
                pid = (doc.get("policy") or {}).get("id")
                if pid:
                    existing.append(pid)
            sys.exit(
                f"error: no policy {args.policy!r} in data/policies/.\n"
                f"       existing policies: {', '.join(existing) or '(none)'}\n"
                "       If the rule belongs in one of those, use its name. If this really is a\n"
                "       new policy, re-run with --create-policy (a new policy is an elevated\n"
                "       change: new category placement, new ordering, new blast radius)."
            )
        if args.owner == "lm" and not args.sites:
            sys.exit("error: --owner lm needs at least one --sites value")
        path = create_policy_file(args)
        doc = load_yaml(path.read_text()) or {}
        print(f"created {path.relative_to(REPO_ROOT)}")
    else:
        path, doc = found
        print(f"found policy {args.policy!r} in {path.relative_to(REPO_ROOT)} — appending to it")

    rules = doc.get("rules") or {}
    if args.rule in rules:
        sys.exit(
            f"error: rule {args.rule!r} already exists in {path.relative_to(REPO_ROOT)}. "
            "Edit it there; renaming a rule key destroys and recreates the rule."
        )

    sequence = args.sequence if args.sequence else next_sequence(rules)
    if any(
        isinstance(r, dict) and r.get("sequence_number") == sequence for r in rules.values()
    ):
        sys.exit(f"error: sequence_number {sequence} is already used in this policy")

    block = render_rule(args.rule, args, sequence)

    if args.dry_run:
        print(f"--- would append to {path.relative_to(REPO_ROOT)} ---")
        print(block, end="")
        return 0

    text = path.read_text()
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text + block)

    print(f"added rule {args.rule!r} at sequence {sequence}")
    print("next: make validate, then open a PR")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/add-rule.py

write_file scripts/tag-vm.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Set or clear NSX tags on a VM, as a data edit.

The point of this script is that tagging a workload never requires the NSX UI
and never requires hand-editing YAML: it edits data/vm-tags/<site>.yaml, and the
local-tags stack applies it.

  scripts/tag-vm.py --site lon1 --vm payments-web-01 --set workload=payments-web
  scripts/tag-vm.py --site lon1 --vm payments-web-01 --set quarantine=active
  scripts/tag-vm.py --site lon1 --vm payments-web-01 --unset quarantine
  scripts/tag-vm.py --site lon1 --vm payments-web-01 --remove
  scripts/tag-vm.py --site lon1 --list

--set replaces the value for that scope and leaves the rest of the VM's tags
alone. That is a convenience of this script, not of the underlying resource:
nsxt_policy_vm_tags still replaces the whole tag set on apply, which is why the
data file must always hold the complete set. Removing the last tag would strip
the VM, so --unset refuses it and tells you to use --remove.

Run make validate afterwards; it enforces the scope ownership rule.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
VM_TAGS = REPO_ROOT / "data" / "vm-tags"
SCOPES = REPO_ROOT / "data" / "schema" / "tag-scopes.yaml"

DEFAULT_JUSTIFICATION = (
    "TODO: say why no other system tags these VMs. Terraform takes the whole "
    "tag set, so a CMDB or VCF automation writing the same VM will fight it."
)


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def terraform_scopes() -> set[str]:
    if not SCOPES.exists():
        return set()
    doc = load_yaml(SCOPES.read_text()) or {}
    return {
        name
        for name, spec in (doc.get("scopes") or {}).items()
        if isinstance(spec, dict) and spec.get("owner") == "terraform"
    }


def load(site: str) -> dict:
    path = VM_TAGS / f"{site}.yaml"
    if not path.exists():
        return {"site": site, "sole_tagger": DEFAULT_JUSTIFICATION, "vms": {}}
    doc = load_yaml(path.read_text()) or {}
    doc.setdefault("site", site)
    doc.setdefault("sole_tagger", DEFAULT_JUSTIFICATION)
    doc.setdefault("vms", {})
    return doc


def dump(doc: dict) -> str:
    """Emit the narrow shape this file has, so no YAML writer is needed."""
    out = [
        "# VM tag assignments for one site.",
        "#",
        "# Terraform owns the COMPLETE tag set of every VM listed here: anything",
        "# not in a VM's tags list is REMOVED from that VM on apply. Read",
        "# docs/TAGGING.md before adding to this file.",
        "#",
        "# Written by scripts/tag-vm.py; safe to edit by hand.",
        "",
        f"site: {doc['site']}",
        "sole_tagger: >",
    ]
    for line in str(doc["sole_tagger"]).strip().splitlines():
        out.append(f"  {line.strip()}")
    out.append("")
    out.append("vms:")

    vms = doc.get("vms") or {}
    if not vms:
        out.append("  {}")
        return "\n".join(out) + "\n"

    for name in sorted(vms):
        vm = vms[name] or {}
        out.append(f"  {name}:")
        for key in ("display_name", "external_id", "description"):
            if vm.get(key):
                out.append(f"    {key}: {_scalar(str(vm[key]))}")
        out.append("    tags:")
        for tag in vm.get("tags") or []:
            out.append(f"      - {{ scope: {_scalar(tag['scope'])}, tag: {_scalar(tag['tag'])} }}")
        for port in vm.get("ports") or []:
            out.append("    ports:")
            out.append(f"      - segment: {_scalar(port['segment'])}")
            out.append("        tags:")
            for tag in port.get("tags") or []:
                out.append(f"          - {{ scope: {_scalar(tag['scope'])}, tag: {_scalar(tag['tag'])} }}")
    return "\n".join(out) + "\n"


def _scalar(value: str) -> str:
    # Quote anything YAML would read as other than a plain string.
    if value == "" or value[0] in "!&*{}[]|>%@`\"'" or ": " in value or value.strip() != value:
        return '"' + value.replace('"', '\\"') + '"'
    return value


def parse_pair(raw: str) -> tuple[str, str]:
    scope, sep, value = raw.partition("=")
    if not sep or not scope or not value:
        die(f"--set expects scope=value, got {raw!r}")
    return scope, value


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", required=True, help="site id; the file is data/vm-tags/<site>.yaml")
    ap.add_argument("--vm", help="logical key for the VM, normally its vCenter name")
    ap.add_argument("--display-name", help="vCenter name, if it differs from --vm")
    ap.add_argument("--external-id", help="NSX external id. Preferred: it survives a rename.")
    ap.add_argument("--description", help="why this VM is tagged from Terraform")
    ap.add_argument("--set", dest="set_tags", action="append", default=[], metavar="SCOPE=VALUE")
    ap.add_argument("--unset", action="append", default=[], metavar="SCOPE")
    ap.add_argument("--remove", action="store_true", help="stop managing this VM's tags entirely")
    ap.add_argument("--list", action="store_true", help="show what is tagged at this site")
    ap.add_argument("--dry-run", action="store_true", help="print the file, write nothing")
    args = ap.parse_args()

    doc = load(args.site)
    vms = doc["vms"]

    if args.list:
        if not vms:
            print(f"{args.site}: no VMs tagged from Terraform")
            return 0
        for name in sorted(vms):
            tags = " ".join(f"{t['scope']}|{t['tag']}" for t in (vms[name].get("tags") or []))
            print(f"{name}\t{tags}")
        return 0

    if not args.vm:
        die("--vm is required unless --list is given")

    if args.remove:
        if args.vm not in vms:
            die(f"{args.vm!r} is not tagged at {args.site}")
        del vms[args.vm]
        print(f"removed {args.vm} from data/vm-tags/{args.site}.yaml")
        print("NOTE: this REMOVES every tag from the VM on the next apply. Review the plan.")
    else:
        if not (args.set_tags or args.unset):
            die("nothing to do: pass --set, --unset, --remove or --list")

        vm = vms.setdefault(args.vm, {"tags": []})
        if args.display_name:
            vm["display_name"] = args.display_name
        if args.external_id:
            vm["external_id"] = args.external_id
        if args.description:
            vm["description"] = args.description
        if not vm.get("display_name") and not vm.get("external_id"):
            vm["display_name"] = args.vm

        tags = {t["scope"]: t["tag"] for t in vm.get("tags") or []}

        allowed = terraform_scopes()
        for raw in args.set_tags:
            scope, value = parse_pair(raw)
            if allowed and scope not in allowed:
                die(
                    f"scope {scope!r} is not owned by terraform in data/schema/tag-scopes.yaml.\n"
                    f"       Terraform-writable scopes: {', '.join(sorted(allowed)) or '(none)'}\n"
                    "       Writing a scope another system owns means the two overwrite each\n"
                    "       other on every run. See docs/TAGGING.md."
                )
            tags[scope] = value

        for scope in args.unset:
            tags.pop(scope, None)

        if not tags:
            die(
                f"that would leave {args.vm!r} with no tags, and an empty tag set strips the VM.\n"
                "       Use --remove if you meant to stop managing it."
            )

        vm["tags"] = [{"scope": s, "tag": tags[s]} for s in sorted(tags)]
        print(f"{args.vm}: " + " ".join(f"{s}|{tags[s]}" for s in sorted(tags)))

    rendered = dump(doc)
    if args.dry_run:
        print()
        print(rendered, end="")
        return 0

    VM_TAGS.mkdir(parents=True, exist_ok=True)
    (VM_TAGS / f"{args.site}.yaml").write_text(rendered)
    print(f"wrote data/vm-tags/{args.site}.yaml — run 'make validate', then plan local-tags")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/tag-vm.py

write_file scripts/import-estate.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Adopt an existing NSX estate into this repository.

The estate exists already. Nothing here creates NSX objects — it reads what is
there and writes it out as data files plus Terraform import blocks, so that
Terraform takes ownership of the objects you already run instead of building a
parallel set beside them.

Two sources:

  # live manager — credentials from the environment, as everywhere else
  scripts/with-credentials.sh lon1 -- scripts/import-estate.py --site lon1

  # offline: capture once, convert as often as you like
  scripts/with-credentials.sh lon1 -- scripts/import-estate.py --site lon1 \
      --dump-only reports/lon1-raw.json
  scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json

One piece at a time: --policy adopts only the named policies (repeat it) and
what they need, the groups they reference (nested groups included) and their
custom services. Anything already in data/ is skipped: it is managed already.

  scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json \
      --policy legacy-app --tranche legacy-app

What it writes (never over the top of anything). <tranche> is --tranche, or
"all" for a whole manager:

  data/groups/imported-<site>-<tranche>.yaml     groups, criteria from expressions
  data/policies/<policy-id>.yaml                 one file per policy, for add-rule.py
  data/services/imported-<site>-<tranche>.yaml   custom services; predefined referenced
  stacks/<stack>/import-<site>-<tranche>.tf      import blocks, for this site only
  data/.import-manifest.json                     what was imported, and from where

The import blocks are guarded by the site, so a tranche for one Local Manager
never touches the plans of the others that share the stack.

If a target file already exists it is written as <name>.new and reported. Your
data is never overwritten by this tool, and bootstrap.sh refuses to overwrite
anything listed in the manifest even with --force-data.

Mirror mode: --mirror converts EVERY adoptable object of the manager, not a
chosen policy, into files this tool owns for that manager and regenerates on
every run, so objects added, changed or deleted in the UI follow:

  data/groups/imported-<site>-mirror.yaml, data/services/imported-<site>-mirror.yaml,
  data/policies/<policy-id>.yaml, stacks/<stack>/import-<site>-mirror.tf

Each starts with the line "# nsx-mirror: <site>". Those files are overwritten
and removed by the next run; nothing else is touched, and objects declared in
any other file are left to that file. The output is stable: a run against an
unchanged manager rewrites the same bytes. scripts/mirror.sh runs this from
the pipeline for managers with "mode: mirror" in the inventory.

IMPORT ID FORMAT: policy resources in the nsxt provider have taken more than
one import id format across versions — the policy path, or "domain/id". This
script defaults to the path and can emit either (--id-format). Confirm on your
first tranche: a wrong format fails immediately and harmlessly at plan time
with a "not found" style error, before anything is written to state.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA = REPO_ROOT / "data"
MANIFEST = DATA / ".import-manifest.json"

# First line of every file mirror mode owns, followed by the manager's name.
MIRROR_MARK = "# nsx-mirror: "

GM_BASE = "/global-manager/api/v1/global-infra"
LM_BASE = "/policy/api/v1/infra"


# --------------------------------------------------------------------------
# Fetching
# --------------------------------------------------------------------------

CA_SITE = ""  # set in main(): the manager whose CA file applies


def nsx_ca_file() -> str | None:
    """The CA to trust for this manager, as scripts/tf.sh chooses it:
    NSX_CA_FILE_<SITE> first, then NSX_CA_FILE."""
    key = re.sub(r"[^A-Z0-9]", "_", CA_SITE.upper())
    for name in (f"NSX_CA_FILE_{key}", "NSX_CA_FILE"):
        path = os.environ.get(name)
        if path:
            if not os.path.isfile(path):
                sys.exit(f"error: {name} is set to '{path}', which is not a readable file")
            return path
    return None


def api_get(host: str, path: str, user: str, password: str, insecure: bool) -> dict:
    url = f"https://{host}{path}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    credentials = urllib.parse.quote(user), urllib.parse.quote(password)
    import base64

    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    request.add_header("Authorization", f"Basic {token}")

    context = ssl.create_default_context()
    # Python 3.13 turned on RFC 5280 strict checks, which reject internal CAs that
    # lack a keyUsage extension. Terraform's Go TLS stack accepts them, and so did
    # Python before 3.13; without this the capture and the plan would disagree
    # about the same manager. The chain and the hostname are still verified.
    context.verify_flags &= ~ssl.VERIFY_X509_STRICT
    ca_file = nsx_ca_file()
    if ca_file:
        context.load_verify_locations(cafile=ca_file)
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(request, context=context, timeout=60) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        sys.exit(f"error: {exc.code} from {path}: {exc.read()[:300].decode(errors='replace')}")
    except urllib.error.URLError as exc:
        hint = ""
        if "CERTIFICATE_VERIFY_FAILED" in str(exc.reason):
            hint = (
                "\n       The manager is presenting a certificate this machine does not trust. Point "
                f"NSX_CA_FILE_{re.sub(r'[^A-Z0-9]', '_', CA_SITE.upper())} (or NSX_CA_FILE) at the PEM of "
                "its CA, or of the certificate itself if it is self-signed. --insecure is for a lab only."
            )
        sys.exit(f"error: cannot reach {host}: {exc.reason}{hint}")


def fetch_estate(host: str, user: str, password: str, base: str, domain: str, insecure: bool) -> dict:
    """Groups, services and policies. On a Global Manager, from every domain: a
    global policy's rules may use a location domain's groups (e.g. WL-Mum), and
    location domains hold policies of their own. A Local Manager has only
    'default' (its view of the Global Manager's domains is not its own)."""
    def results(path: str) -> list:
        # The policy API pages lists (1000 per page by default). Follow the cursor,
        # or a large estate is silently cut short.
        out: list = []
        cursor = None
        while True:
            page = api_get(host, path + (f"?cursor={urllib.parse.quote(cursor)}" if cursor else ""), user, password, insecure)
            out.extend(page.get("results", []))
            cursor = page.get("cursor")
            if not cursor:
                return out

    domains = [domain]
    if base == GM_BASE:
        # The manager's own domain first: on an id clash between domains, it wins.
        domains += sorted(d["id"] for d in results(f"{base}/domains") if d.get("id") and d["id"] != domain)
    print(f"reading {host} ({base}, domain(s) {', '.join(domains)})", file=sys.stderr)
    groups: list = []
    policies: list = []
    for d in domains:
        found = results(f"{base}/domains/{urllib.parse.quote(d, safe='')}/groups")
        groups += found
        count = 0
        for summary in results(f"{base}/domains/{urllib.parse.quote(d, safe='')}/security-policies"):
            # The list endpoint omits rules; fetch each policy in full.
            policies.append(
                api_get(
                    host,
                    # Ids made in the UI may hold spaces, quotes or '#'.
                    f"{base}/domains/{urllib.parse.quote(d, safe='')}/security-policies/{urllib.parse.quote(summary['id'], safe='')}",
                    user,
                    password,
                    insecure,
                )
            )
            count += 1
        print(f"  domain {d}: {len(found)} group(s), {count} policy/policies", file=sys.stderr)
    services = results(f"{base}/services")
    print(f"  {len(services)} service(s)", file=sys.stderr)

    return {"groups": groups, "services": services, "policies": policies, "domain": domain, "domains": domains}


def domain_of(path: str, default: str) -> str:
    """The domain an object's path puts it in."""
    found = re.match(r"^/(?:global-)?infra/domains/([^/]+)/", path or "")
    return found.group(1) if found else default


def is_ip_literal(value: str) -> bool:
    """An address, CIDR or range (a-b), as NSX takes in a rule's source or destination."""
    try:
        for part in value.split("-", 1):
            ipaddress.ip_network(part, strict=False)
        return True
    except ValueError:
        return False


# --------------------------------------------------------------------------
# YAML emitting — small and controlled, so output is stable and diffable.
# --------------------------------------------------------------------------

NEEDS_QUOTE = set(":{}[],&*#?|-<>=!%@`\"'")


def scalar(value) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if (
        text == ""
        or text[0] in NEEDS_QUOTE
        or text.strip() != text
        or text.lower() in ("true", "false", "null", "yes", "no", "on", "off", "~")
        or any(c in text for c in ":#'\"\\,[]{}")  # also safe inside a [flow, list]
        or any(ord(c) < 32 or ord(c) == 127 for c in text)
        or _looks_numeric(text)
    ):
        return '"' + "".join(_ESCAPES.get(c) or (f"\\x{ord(c):02x}" if ord(c) < 32 or ord(c) == 127 else c)
                             for c in text) + '"'
    return text


# Double-quoted YAML: these characters are written escaped, anything else as is.
_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def key(value) -> str:
    """A mapping key, quoted like any value when it needs to be: NSX ids can be
    anything but '/' (Azure-AD-IP's, 'WIN11 IC', 100, -x, @y)."""
    return scalar(str(value))


def _looks_numeric(text: str) -> bool:
    try:
        float(text)
        return True
    except ValueError:
        return False


def emit(value, indent: int = 0) -> list[str]:
    pad = "  " * indent
    lines: list[str] = []
    if isinstance(value, dict):
        for name, item in value.items():
            if isinstance(item, dict) and item:
                lines.append(f"{pad}{key(name)}:")
                lines.extend(emit(item, indent + 1))
            elif isinstance(item, list) and item:
                if all(not isinstance(x, (dict, list)) for x in item):
                    lines.append(f"{pad}{key(name)}: [{', '.join(scalar(x) for x in item)}]")
                else:
                    lines.append(f"{pad}{key(name)}:")
                    lines.extend(emit(item, indent + 1))
            elif isinstance(item, (dict, list)):
                lines.append(f"{pad}{key(name)}: {{}}" if isinstance(item, dict) else f"{pad}{key(name)}: []")
            else:
                lines.append(f"{pad}{key(name)}: {scalar(item)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                rendered = emit(item, indent + 1)
                first = rendered[0].lstrip()
                lines.append(f"{pad}- {first}")
                lines.extend(rendered[1:])
            else:
                lines.append(f"{pad}- {scalar(item)}")
    return lines


def to_yaml(value) -> str:
    return "\n".join(emit(value)) + "\n"


# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------

def tags_of(obj: dict) -> list[dict]:
    return [{"scope": t.get("scope", ""), "tag": t.get("tag", "")} for t in obj.get("tags") or []]


def condition(expression: dict) -> dict:
    return {
        "key": expression.get("key", "Tag"),
        "member_type": expression.get("member_type", "VirtualMachine"),
        "operator": expression.get("operator", "EQUALS"),
        "value": expression.get("value", ""),
    }


def convert_group(group: dict, path_to_name: dict, owner: str, sites: list[str]) -> dict:
    criteria: list[dict] = []
    conjunction = None
    static = False

    for expression in group.get("expression", []):
        kind = expression.get("resource_type")
        if kind == "Condition":
            criteria.append({"conditions": [condition(expression)]})
        elif kind == "NestedExpression":
            conditions = [
                condition(inner)
                for inner in expression.get("expressions", [])
                if inner.get("resource_type") == "Condition"
            ]
            if conditions:
                criteria.append({"conditions": conditions})
        elif kind == "IPAddressExpression":
            criteria.append({"ip_addresses": expression.get("ip_addresses", [])})
            static = True
        elif kind == "MACAddressExpression":
            criteria.append({"mac_addresses": expression.get("mac_addresses", [])})
            static = True
        elif kind == "ExternalIDExpression":
            # Members picked one by one in the UI: virtual machines by instance UUID.
            criteria.append({"member_type": expression.get("member_type", "VirtualMachine"),
                             "external_ids": list(expression.get("external_ids", []))})
            static = True
        elif kind == "PathExpression":
            criteria.append(
                {"member_groups": [path_to_name.get(p, p) for p in expression.get("paths", [])]}
            )
        elif kind == "ConjunctionOperator":
            conjunction = expression.get("conjunction_operator")

    out: dict = {"display_name": group.get("display_name", group["id"]), "owner": owner}
    if group.get("description"):
        out["description"] = group["description"]
    if owner == "lm":
        out["sites"] = list(sites)
    if static:
        out["why_static"] = (
            "IMPORTED AS-IS from the live manager. Replace this note with the real reason "
            "the membership is static, and what would let it become dynamic."
        )
    if (group.get("group_type") or []) == ["IPAddress"]:
        out["group_type"] = "IPAddress"  # "IP Addresses Only" in the UI
    if conjunction and len(criteria) > 1:
        out["conjunction"] = conjunction
    if criteria:
        out["criteria"] = criteria
    else:
        out["why_empty"] = (
            "IMPORTED AS-IS: this group has no membership criteria in NSX, so it matches nothing "
            "(or its members are managed elsewhere). Replace this note with the reason, or delete the group."
        )
    if tags_of(group):
        out["tags"] = tags_of(group)
    return out


def convert_rule(rule: dict, group_paths: dict, service_paths: dict) -> dict:
    def names(paths, lookup):
        out = []
        for path in paths or []:
            if path == "ANY":
                continue
            out.append(lookup.get(path, path))
        return out

    converted: dict = {
        "name": rule.get("display_name", rule["id"]),
        "sequence_number": rule.get("sequence_number", 100),
        "action": rule.get("action", "ALLOW"),
        "direction": rule.get("direction", "IN_OUT"),
    }
    if rule.get("description"):
        converted["description"] = rule["description"]
    if rule.get("ip_protocol") and rule["ip_protocol"] != "IPV4_IPV6":
        converted["ip_version"] = rule["ip_protocol"]

    sources = names(rule.get("source_groups"), group_paths)
    destinations = names(rule.get("destination_groups"), group_paths)
    services = names(rule.get("services"), service_paths)
    scope = names(rule.get("scope"), group_paths)

    if sources:
        converted["source_groups"] = sources
    if destinations:
        converted["destination_groups"] = destinations
    if services:
        converted["services"] = services
    if rule.get("sources_excluded"):
        converted["sources_excluded"] = True
    if rule.get("destinations_excluded"):
        converted["destinations_excluded"] = True
    if rule.get("disabled"):
        converted["disabled"] = True
    converted["logged"] = bool(rule.get("logged", False))
    if rule.get("notes"):
        converted["notes"] = rule["notes"]
    if rule.get("tag"):
        converted["log_label"] = rule["tag"]
    profiles = [p for p in rule.get("profiles") or [] if p != "ANY"]
    if profiles:
        converted["profiles"] = profiles
    if tags_of(rule):
        converted["tags"] = tags_of(rule)
    # Apply To "ANY" (the policy's own scope) is written as ANY: an empty list
    # would read as a rule that forgot its Apply To, and is refused.
    converted["scope"] = scope or ["ANY"]
    return converted


def convert_policy(policy: dict, group_paths: dict, service_paths: dict, owner: str, sites: list[str]) -> dict:
    header: dict = {
        "id": policy["id"],
        "name": policy.get("display_name", policy["id"]),
        "category": policy.get("category", "Application"),
        "owner": owner,
    }
    if policy.get("description"):
        header["description"] = policy["description"]
    if owner == "lm":
        header["sites"] = list(sites)
    header["sequence_number"] = policy.get("sequence_number", 100)
    if policy.get("stateful") is False:
        header["stateful"] = False
    if policy.get("locked"):
        header["locked"] = True
    if policy.get("comments"):
        header["comments"] = policy["comments"]
    if tags_of(policy):
        header["tags"] = tags_of(policy)
    header["rule_management"] = "standalone"
    header["scope"] = [
        group_paths.get(p, p) for p in policy.get("scope", []) if p != "ANY"
    ] or ["ANY"]

    rules = {}
    for rule in policy.get("rules", []):
        rules[rule["id"]] = convert_rule(rule, group_paths, service_paths)
    numbers = [r["sequence_number"] for r in rules.values()]
    if len(numbers) != len(set(numbers)):
        header["allow_duplicate_sequence"] = True

    return {"policy": header, "rules": rules}


def convert_service(service: dict) -> dict:
    out: dict = {"display_name": service.get("display_name", service["id"])}
    if service.get("description"):
        out["description"] = service["description"]
    l4: list[dict] = []
    icmp: list[dict] = []
    other: dict[str, list[dict]] = {}
    for entry in service.get("service_entries", []):
        kind = entry.get("resource_type")
        if kind == "L4PortSetServiceEntry":
            item = {
                "protocol": entry.get("l4_protocol", "TCP"),
                "destination_ports": [str(p) for p in entry.get("destination_ports", [])],
            }
            if entry.get("display_name"):
                item["display_name"] = entry["display_name"]
            if entry.get("source_ports"):
                item["source_ports"] = [str(p) for p in entry["source_ports"]]
            l4.append(item)
        elif kind == "ICMPTypeServiceEntry":
            item = {"protocol": entry.get("protocol", "ICMPv4")}
            if entry.get("display_name"):
                item["display_name"] = entry["display_name"]
            if entry.get("icmp_type") is not None:
                item["icmp_type"] = str(entry["icmp_type"])
            if entry.get("icmp_code") is not None:
                item["icmp_code"] = str(entry["icmp_code"])
            icmp.append(item)
        elif kind == "IPProtocolServiceEntry":
            item = {"protocol": int(entry["protocol_number"])}
            if entry.get("display_name"):
                item["display_name"] = entry["display_name"]
            other.setdefault("ip_protocol", []).append(item)
        elif kind == "ALGTypeServiceEntry":
            item = {"algorithm": entry["alg"], "destination_port": str((entry.get("destination_ports") or [""])[0])}
            if entry.get("display_name"):
                item["display_name"] = entry["display_name"]
            if entry.get("source_ports"):
                item["source_ports"] = [str(p) for p in entry["source_ports"]]
            other.setdefault("algorithm", []).append(item)
        elif kind == "IGMPTypeServiceEntry":
            other.setdefault("igmp", []).append({"display_name": entry["display_name"]} if entry.get("display_name") else {})
        elif kind == "EtherTypeServiceEntry":
            item = {"ether_type": int(entry["ether_type"])}
            if entry.get("display_name"):
                item["display_name"] = entry["display_name"]
            other.setdefault("ether_type", []).append(item)
    if l4:
        out["l4_port_set"] = l4
    if icmp:
        out["icmp"] = icmp
    out.update(other)
    return out


# What this converter and the modules represent exactly. Anything else would be
# lost on the first apply (an unset attribute is cleared), so such objects are
# never adopted: they stay in the UI and are reported.
GROUP_EXPRESSIONS = {"Condition", "NestedExpression", "IPAddressExpression", "MACAddressExpression",
                     "ExternalIDExpression", "PathExpression", "ConjunctionOperator"}
EXTERNAL_ID_TYPES = {"VirtualMachine", "VirtualNetworkInterface", "CloudNativeServiceInstance", "PhysicalServer"}
SERVICE_ENTRIES = {"L4PortSetServiceEntry", "ICMPTypeServiceEntry", "IPProtocolServiceEntry", "ALGTypeServiceEntry",
                   "IGMPTypeServiceEntry", "EtherTypeServiceEntry"}
ALGORITHMS = {"ORACLE_TNS", "FTP", "SUN_RPC_TCP", "SUN_RPC_UDP", "MS_RPC_TCP", "MS_RPC_UDP", "NBNS_BROADCAST", "NBDG_BROADCAST", "TFTP"}


def condition_values() -> dict[str, set[str]]:
    """What data/schema/group.schema.json accepts in a condition: a condition
    with anything else is not adopted, so the copy always validates."""
    schema = json.loads((DATA / "schema" / "group.schema.json").read_text())
    item = schema["properties"]["groups"]["additionalProperties"]["properties"]["criteria"]["items"]
    fields = item["properties"]["conditions"]["items"]["properties"]
    return {k: set(fields[k]["enum"]) for k in ("key", "member_type", "operator")}


CONDITION_VALUES: dict[str, set[str]] = {}


def condition_unsupported(expression: dict) -> str | None:
    if not CONDITION_VALUES:
        CONDITION_VALUES.update(condition_values())
    for field, default in (("key", "Tag"), ("member_type", "VirtualMachine"), ("operator", "EQUALS")):
        value = expression.get(field, default)
        if value not in CONDITION_VALUES[field]:
            return f"a condition with {field} {value}"
    if expression.get("scope_operator", "EQUALS") != "EQUALS":
        # The provider has no scope_operator: written without it, the condition
        # would match a different set of members.
        return f"a condition with scope_operator {expression['scope_operator']}"
    if not str(expression.get("value", "")):
        return "a condition with an empty value"
    return None


def group_unsupported(group: dict) -> str | None:
    kinds = set()
    for expression in group.get("expression", []):
        kinds.add(expression.get("resource_type"))
        if expression.get("resource_type") == "NestedExpression":
            inner = {e.get("resource_type") for e in expression.get("expressions", [])}
            if inner - {"Condition", "ConjunctionOperator"}:
                return "nested expression containing " + ", ".join(sorted(str(k) for k in inner - {"Condition", "ConjunctionOperator"}))
    if kinds - GROUP_EXPRESSIONS:
        return "membership by " + ", ".join(sorted(str(k) for k in kinds - GROUP_EXPRESSIONS))
    for expression in group.get("expression", []):
        if expression.get("resource_type") == "ExternalIDExpression" and expression.get("member_type", "VirtualMachine") not in EXTERNAL_ID_TYPES:
            return f"external ids of {expression.get('member_type')}"
        conditions = [expression] if expression.get("resource_type") == "Condition" else [
            e for e in expression.get("expressions", []) if e.get("resource_type") == "Condition"]
        for c in conditions:
            if why := condition_unsupported(c):
                return why
    if group.get("extended_expression"):
        return "extended criteria (identity firewall)"
    group_type = group.get("group_type") or []
    if group_type and group_type != ["IPAddress"]:
        return "group_type " + ", ".join(group_type)
    return None


def service_unsupported(service: dict) -> str | None:
    entries = service.get("service_entries", [])
    kinds = {e.get("resource_type") for e in entries} - SERVICE_ENTRIES
    if kinds:
        return "service entries of type " + ", ".join(sorted(str(k) for k in kinds))
    for e in entries:
        if e.get("resource_type") == "ALGTypeServiceEntry" and (e.get("alg") not in ALGORITHMS or len(e.get("destination_ports") or []) != 1):
            return f"an ALG entry {e.get('alg')} with {len(e.get('destination_ports') or [])} destination port(s)"
        if e.get("resource_type") == "IPProtocolServiceEntry" and e.get("protocol_number") is None:
            return "an IP protocol entry without a protocol number"
        if e.get("resource_type") == "EtherTypeServiceEntry" and e.get("ether_type") is None:
            return "an EtherType entry without an ether type"
    return None


def unsupported_objects(groups: list[dict], services: list[dict], start: dict[str, str] | None = None) -> dict[str, str]:
    """path -> reason, for groups and custom services that cannot be adopted.
    A group that nests an unsupported group is unsupported too. start: paths
    already known to be unadoptable (federation())."""
    bad: dict[str, str] = dict(start or {})
    for g in groups:
        if not is_system(g) and (why := group_unsupported(g)):
            bad[g["path"]] = why
    for s in services:
        if not is_system(s) and (why := service_unsupported(s)):
            bad[s["path"]] = why
    changed = True
    while changed:
        changed = False
        for g in groups:
            if g.get("path") in bad or is_system(g):
                continue
            for expression in g.get("expression", []):
                hit = [p for p in expression.get("paths", []) if p in bad] if expression.get("resource_type") == "PathExpression" else []
                if hit:
                    bad[g["path"]] = "nests " + ", ".join(h.rsplit("/", 1)[-1] for h in hit)
                    changed = True
                    break
    return bad


def rule_unsupported(rule: dict, bad: dict[str, str]) -> str | None:
    if rule.get("service_entries"):
        return "inline service entries"
    used = sorted({p for f in ("source_groups", "destination_groups", "scope", "services") for p in rule.get(f) or [] if p in bad})
    if used:
        return "uses " + "; ".join(f"{u.rsplit('/', 1)[-1]} ({bad[u]})" for u in used)
    return None


def is_system(obj: dict) -> bool:
    return bool(obj.get("_system_owned")) or obj.get("_create_user") == "system"


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

class Writer:
    def __init__(self, dry_run: bool, overwrite: bool = False) -> None:
        self.dry_run = dry_run
        self.overwrite = overwrite
        self.written: list[str] = []
        self.deferred: list[str] = []

    def write(self, path: Path, text: str) -> None:
        rel = str(path.relative_to(REPO_ROOT))
        target = path
        if path.exists() and not self.overwrite:
            target = path.with_suffix(path.suffix + ".new")
            self.deferred.append(f"{rel} -> {target.name}")
        else:
            self.written.append(rel)
        if self.dry_run:
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)


def import_block(address: str, identifier: str) -> str:
    return f'import {{\n  to = {address}\n  id = "{identifier}"\n}}\n\n'


def object_id(kind: str, domain: str, path: str, nsx_id: str, fmt: str) -> str:
    if fmt == "path":
        return path
    if fmt == "domain-id" and kind != "service":
        return f"{domain}/{nsx_id}"
    return nsx_id


def hcl_string(value: str) -> str:
    """A Terraform string literal: JSON escaping, plus HCL's own template markers."""
    return json.dumps(value).replace("${", "$${").replace("%{", "%%{")


def ident(text: str) -> str:
    return re.sub(r"[^a-z0-9_]", "_", text.lower())


def import_file(site: str, tranche: str, role: str, kinds: list[tuple[str, str, dict]], header: str) -> str:
    """Import blocks for one tranche, one block per resource kind, each a for_each
    over a map. On a Local Manager the map is empty unless var.site is this site,
    so the file is inert in every other manager's plan of the same stack."""
    name = f"import_{ident(site)}_{ident(tranche)}"
    lines = [header, "locals {"]
    for kind, _, entries in kinds:
        lines.append(f"  {name}_{kind} = {{")
        # Aligned on '=' as terraform fmt aligns it, so 'fmt -check' passes as written.
        width = max((len(hcl_string(k)) for k in entries), default=0)
        for key, value in entries.items():
            if isinstance(value, dict):
                inner = ", ".join(f"{k} = {hcl_string(v)}" for k, v in value.items())
                lines.append(f"    {hcl_string(key).ljust(width)} = {{ {inner} }}")
            else:
                lines.append(f"    {hcl_string(key).ljust(width)} = {hcl_string(value)}")
        lines.append("  }")
    lines.append("}")
    lines.append("")
    for kind, to, entries in kinds:
        if not entries:
            continue
        source = f"local.{name}_{kind}"
        if role != "gm":
            source = f"var.site == {hcl_string(site)} ? {source} : {{}}"
        value = "each.value.id" if "each.value.policy" in to else "each.value"
        lines += ["import {", f"  for_each = {source}", f"  to       = {to}", f"  id       = {value}", "}", ""]
    return "\n".join(lines) + "\n"


def mirror_files(site: str) -> set[Path]:
    """The data files mirror mode owns for this manager, by their first line."""
    own: set[Path] = set()
    for kind in ("groups", "services", "policies"):
        for f in (DATA / kind).glob("*.yaml"):
            if f.read_text().split("\n", 1)[0].strip() == f"{MIRROR_MARK}{site}":
                own.add(f)
    return own


def declared_objects(exclude: frozenset[Path] | set[Path] = frozenset()) -> dict[str, dict[str, dict]]:
    """Groups and custom services data/ declares, id -> definition."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from yamlcompat import load_yaml  # noqa: PLC0415

    out: dict[str, dict[str, dict]] = {"groups": {}, "services": {}}
    for kind, key in (("groups", "groups"), ("services", "custom")):
        for f in sorted((DATA / kind).glob("*.yaml")):
            if f in exclude:
                continue
            for name, definition in ((load_yaml(f.read_text()) or {}).get(key) or {}).items():
                out[kind][name] = definition if isinstance(definition, dict) else {}
    return out


def federation(role: str, site: str, groups: list, services: list, policies: list,
               declared: dict, group_paths: dict, service_paths: dict) -> dict[str, str]:
    """What cannot be adopted on this manager because of the Global Manager / Local
    Manager split, path -> reason; fills group_paths and service_paths with the
    global objects a Local Manager's rules may use.

    data/ is keyed by id, and each object has one owner, so an object belongs to
    exactly one manager's stack and two stacks never fight over it. Here that
    is kept true: a local object whose id another manager already owns in
    data/ is not adopted (its name would resolve to the other object), and a
    reference that resolves to nothing data/ declares is not adopted either,
    rather than written as a raw path."""
    default_owner = {"groups": "lm", "services": "gm"}

    def elsewhere(kind: str, definition: dict) -> bool:
        owner = definition.get("owner", default_owner[kind])
        if role == "gm":
            return owner != "gm"
        sites_ = definition.get("sites") or []
        return owner == "gm" or not (site in sites_ or "*" in sites_)

    if role != "gm":
        # A Local Manager sees the Global Manager's objects under /global-infra,
        # read-only. Its own rules may use those that data/ declares as owner: gm.
        for gid, definition in declared["groups"].items():
            if definition.get("owner", "lm") == "gm":
                group_paths[f"/global-infra/domains/{definition.get('domain', 'default')}/groups/{gid}"] = gid
        for sid, definition in declared["services"].items():
            if definition.get("owner", "gm") == "gm":
                service_paths[f"/global-infra/services/{sid}"] = sid

    problems: dict[str, str] = {}
    for kind, objects in (("groups", groups), ("services", services)):
        for obj in objects:
            definition = declared[kind].get(obj["id"])
            if definition is not None and not is_system(obj) and elsewhere(kind, definition):
                whose = "the Global Manager's" if definition.get("owner", default_owner[kind]) == "gm" else "another manager's"
                problems[obj["path"]] = f"its id is also {whose} {kind[:-1]} in data/, so the names would collide"

    def check(path: str, known: dict, what: str) -> None:
        if path in ("ANY", "") or path in known or path in problems:
            return
        if what == "group" and not path.startswith("/") and is_ip_literal(path):
            return  # an address, CIDR or range written in the rule itself
        if path.startswith("/global-infra/") and role != "gm":
            problems[path] = f"uses the global {what} {path.rsplit('/', 1)[-1]}, which data/ does not declare: adopt or mirror the Global Manager first"
        else:
            problems[path] = f"refers to {path}, which {site} does not hold"

    for policy in policies:
        for path in policy.get("scope") or []:
            check(path, group_paths, "group")
        for rule in policy.get("rules", []):
            for field in ("source_groups", "destination_groups", "scope"):
                for path in rule.get(field) or []:
                    check(path, group_paths, "group")
            for path in rule.get("services") or []:
                check(path, service_paths, "service")
    for group in groups:
        for expression in group.get("expression", []):
            if expression.get("resource_type") != "PathExpression":
                continue
            for path in expression.get("paths", []):
                if path.startswith("/global-infra/") and role != "gm":
                    # A site-local group cannot be built from a global one here.
                    problems.setdefault(group["path"], f"nests the global group {path.rsplit('/', 1)[-1]}")
                else:
                    check(path, group_paths, "group")
    return problems


def existing_keys(exclude: frozenset[Path] | set[Path] = frozenset()) -> dict[str, set[str]]:
    """What data/ already declares: those objects are managed and never re-imported.
    Files in exclude are not counted (mirror mode's own, about to be rewritten)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from yamlcompat import load_yaml  # noqa: PLC0415

    found: dict[str, set[str]] = {"groups": set(), "services": set(), "policies": set()}
    for f in sorted((DATA / "groups").glob("*.yaml")):
        if f in exclude:
            continue
        found["groups"].update(((load_yaml(f.read_text()) or {}).get("groups") or {}).keys())
    for f in sorted((DATA / "services").glob("*.yaml")):
        if f in exclude:
            continue
        found["services"].update(((load_yaml(f.read_text()) or {}).get("custom") or {}).keys())
    for f in sorted((DATA / "policies").glob("*.yaml")):
        if f in exclude:
            continue
        doc = load_yaml(f.read_text()) or {}
        found["policies"].add(str((doc.get("policy") or {}).get("id") or f.stem))
    return found


def needed_by(policies: list[dict], groups: list[dict]) -> tuple[set[str], set[str]]:
    """Group and service paths the policies use, nested groups followed to the end."""
    group_paths: set[str] = set()
    service_paths: set[str] = set()
    for policy in policies:
        group_paths.update(policy.get("scope") or [])
        for rule in policy.get("rules", []):
            for field in ("source_groups", "destination_groups", "scope"):
                group_paths.update(rule.get(field) or [])
            service_paths.update(rule.get("services") or [])
    by_path = {g.get("path"): g for g in groups}
    pending = list(group_paths)
    while pending:
        group = by_path.get(pending.pop())
        for expression in (group or {}).get("expression", []):
            if expression.get("resource_type") == "PathExpression":
                for nested in expression.get("paths", []):
                    if nested not in group_paths:
                        group_paths.add(nested)
                        pending.append(nested)
    group_paths.discard("ANY")
    service_paths.discard("ANY")
    return group_paths, service_paths


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--site", required=True, help="manager id from inventory/managers.yaml")
    ap.add_argument("--domain", default=None, help="NSX domain (default: 'default', or 'global' on a GM)")
    ap.add_argument("--role", choices=["gm", "lm"], default=None, help="override the role from the inventory")
    ap.add_argument("--from-dump", metavar="FILE", help="convert a previously captured dump instead of calling the API")
    ap.add_argument("--dump-only", metavar="FILE", help="capture the raw API responses and stop")
    ap.add_argument("--id-format", choices=["path", "domain-id", "id"], default="path")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (lab only)")
    ap.add_argument("--dry-run", action="store_true", help="report what would be written")
    ap.add_argument("--policy", action="append", default=[], metavar="ID",
                    help="adopt only this policy and what it needs; repeat for more")
    ap.add_argument("--list", action="store_true",
                    help="survey: list the policies and whether each can be adopted; write nothing")
    ap.add_argument("--tranche", default=None, metavar="NAME",
                    help="name for this piece of work, used in the file names (default: the first --policy, or 'all')")
    ap.add_argument("--mirror", action="store_true",
                    help="mirror mode: every adoptable object, into files this tool owns and rewrites each run")
    args = ap.parse_args()
    if args.mirror and (args.policy or args.tranche or args.list or args.dump_only):
        sys.exit("error: --mirror takes the whole manager: not with --policy, --tranche, --list or --dump-only")
    if not args.mirror and args.tranche == "mirror":
        sys.exit("error: the tranche name 'mirror' belongs to --mirror")
    tranche = "mirror" if args.mirror else (args.tranche or (args.policy[0] if args.policy else "all"))
    global CA_SITE
    CA_SITE = args.site
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tranche):
        sys.exit(f"error: --tranche '{tranche}' must be letters, digits, '.', '_' or '-'")

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from yamlcompat import load_yaml  # noqa: PLC0415

    inventory_path = REPO_ROOT / "inventory" / "managers.yaml"
    managers = {}
    if inventory_path.exists():
        managers = (load_yaml(inventory_path.read_text()) or {}).get("managers") or {}
    manager = managers.get(args.site, {})
    role = args.role or manager.get("role", "lm")
    # On a Global Manager too, global objects live in domain "default" (another
    # domain is one location's); scripts/tf.sh uses the same default.
    domain = args.domain or manager.get("domain") or "default"
    base = GM_BASE if role == "gm" else LM_BASE

    if args.from_dump:
        estate = json.loads(Path(args.from_dump).read_text())
        domain = estate.get("domain", domain)
    else:
        host = os.environ.get("NSXT_MANAGER_HOST") or manager.get("host")
        user = os.environ.get("NSXT_USERNAME")
        password = os.environ.get("NSXT_PASSWORD")
        if not (host and user and password):
            sys.exit(
                "error: no credentials in the environment. Wrap the call:\n"
                f"       scripts/with-credentials.sh {args.site} -- scripts/import-estate.py --site {args.site}"
            )
        # The flag the NSX provider reads, so the capture and the plan agree:
        # where verification is switched off for Terraform, it is off here too.
        insecure = args.insecure or os.environ.get("NSXT_ALLOW_UNVERIFIED_SSL", "").strip().lower() in ("true", "1", "yes")
        if insecure:
            print(f"warning: TLS verification of {host} is OFF (NSXT_ALLOW_UNVERIFIED_SSL or --insecure): "
                  "whoever answers at that address receives the credentials.", file=sys.stderr)
        estate = fetch_estate(host, user, password, base, domain, insecure)

    if args.dump_only:
        out = Path(args.dump_only)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(estate, indent=2))
        print(f"wrote {out}")
        return 0

    # This manager's own tree only. A Local Manager also shows the Global
    # Manager's objects (under /global-infra); those belong to the GM's data,
    # never to an LM's, or the same object would be managed twice.
    tree = "/global-infra/" if role == "gm" else "/infra/"
    foreign = [o for kind in ("groups", "services", "policies") for o in estate.get(kind, [])
               if not str(o.get("path", tree)).startswith(tree)]
    all_groups = [g for g in estate.get("groups", []) if str(g.get("path", tree)).startswith(tree)]
    all_services = [s for s in estate.get("services", []) if str(s.get("path", tree)).startswith(tree)]
    all_policies = [p for p in estate.get("policies", []) if str(p.get("path", tree)).startswith(tree)]

    own: set[Path] = mirror_files(args.site) if args.mirror else set()
    # References are converted to names using everything that was read, so a
    # rule can name a group this tranche does not adopt.
    group_paths = {g["path"]: g["id"] for g in all_groups if g.get("path")}
    service_paths = {s["path"]: s["id"] for s in all_services if s.get("path")}
    federated = federation(role, args.site, all_groups, all_services, all_policies,
                           declared_objects(exclude=own), group_paths, service_paths)
    # data/ is keyed by id; NSX keys by domain and id. The same id in a second
    # domain (Global Manager) stays in the UI rather than become a second object
    # under one name. The manager's own domain was read first, so it keeps its own.
    first: dict[tuple[str, str], str] = {}
    clashing_policies: dict[str, str] = {}
    for kind, objects in (("group", all_groups), ("policy", all_policies)):
        for o in objects:
            here = domain_of(o.get("path", ""), domain)
            there = first.setdefault((kind, o["id"]), here)
            if there != here:
                why = f"its id is also a {kind} in domain {there}, and data/ names objects by id alone"
                if kind == "group":
                    federated.setdefault(o["path"], why)
                else:
                    clashing_policies[o["path"]] = why

    if args.list:
        return survey(args.site, all_groups, all_services, all_policies, federated)
    sites = [args.site]
    owner = "gm" if role == "gm" else "lm"

    clashing = [p for p in all_policies if p.get("path") in clashing_policies]
    all_policies = [p for p in all_policies if p.get("path") not in clashing_policies]
    groups, services, policies = all_groups, all_services, all_policies
    skipped: list[str] = []
    if args.mirror:
        # Everything, except what another file declares: that file manages it.
        # Sorted, so an unchanged manager gives byte-identical files.
        have = existing_keys(exclude=own)
        skipped += sorted(f"group {g['id']}" for g in groups if g["id"] in have["groups"] and not is_system(g))
        skipped += sorted(f"service {s['id']}" for s in services if s["id"] in have["services"] and not is_system(s))
        skipped += sorted(f"policy {p['id']}" for p in policies if p["id"] in have["policies"] and not is_system(p))
        groups = sorted((g for g in groups if g["id"] not in have["groups"]), key=lambda g: g["id"])
        services = sorted((s for s in services if is_system(s) or s["id"] not in have["services"]), key=lambda s: s["id"])
        # A policy's file is data/policies/<id>.yaml; one that another file
        # already occupies is that file's, whatever it declares.
        taken = {p["id"] for p in policies if (DATA / "policies" / f"{p['id']}.yaml").exists()
                 and DATA / "policies" / f"{p['id']}.yaml" not in own and p["id"] not in have["policies"]}
        skipped += sorted(f"policy {i} (data/policies/{i}.yaml is another file)" for i in taken)
        policies = sorted((p for p in policies if p["id"] not in have["policies"] and p["id"] not in taken),
                          key=lambda p: p["id"])
    if args.policy:
        by_id = {p["id"]: p for p in all_policies}
        missing = [i for i in args.policy if i not in by_id]
        if missing:
            sys.exit(f"error: no policy with id {', '.join(missing)} in what was read from {args.site}")
        system = [i for i in args.policy if is_system(by_id[i])]
        if system:
            sys.exit(f"error: {', '.join(system)} is system-owned; NSX manages it, not Terraform")
        policies = [by_id[i] for i in dict.fromkeys(args.policy)]
        need_groups, need_services = needed_by(policies, all_groups)
        groups = [g for g in all_groups if g.get("path") in need_groups]
        services = [s for s in all_services if s.get("path") in need_services]

        # Already in data/ means already managed: never adopt it twice.
        have = existing_keys()
        skipped += [f"group {g['id']}" for g in groups if g["id"] in have["groups"]]
        skipped += [f"service {s['id']}" for s in services if s["id"] in have["services"] and not is_system(s)]
        skipped += [f"policy {p['id']}" for p in policies if p["id"] in have["policies"]]
        groups = [g for g in groups if g["id"] not in have["groups"]]
        services = [s for s in services if is_system(s) or s["id"] not in have["services"]]
        policies = [p for p in policies if p["id"] not in have["policies"]]

    # Never adopt what cannot be represented exactly; report it instead.
    bad = unsupported_objects(all_groups, all_services, federated)
    kept_in_ui: list[str] = [f"{o.get('resource_type', 'object')} {o.get('id')}: belongs to the Global Manager ({o.get('path')})"
                             for o in foreign]
    kept_in_ui += [f"policy {p['id']}: {clashing_policies[p['path']]}" for p in clashing]
    # A local object shadowed by another manager's id is reported here, not as MANAGED.
    for kind, objects in (("group", all_groups), ("service", all_services)):
        for o in objects:
            if o.get("path") in federated and "names would collide" in federated[o["path"]]:
                kept_in_ui.append(f"{kind} {o['id']}: {federated[o['path']]}")
                skipped = [x for x in skipped if x != f"{kind} {o['id']}"]
    for g in groups:
        if g.get("path") in bad:
            kept_in_ui.append(f"group {g['id']}: {bad[g['path']]}")
    for sv in services:
        if sv.get("path") in bad:
            kept_in_ui.append(f"service {sv['id']}: {bad[sv['path']]}")
    groups = [g for g in groups if g.get("path") not in bad]
    services = [sv for sv in services if sv.get("path") not in bad]
    adoptable = []
    for policy in policies:
        if is_system(policy):
            adoptable.append(policy)
            continue
        blocked = [p for p in policy.get("scope") or [] if p in bad]
        if blocked:
            reason = f"policy {policy['id']}: its Apply To uses {', '.join(b.rsplit('/', 1)[-1] for b in blocked)} (not adoptable)"
            if policy["id"] in args.policy:
                sys.exit(f"error: {reason}. Nothing was written.")
            kept_in_ui.append(reason)
            continue
        rules = []
        notes = []
        for rule in policy.get("rules", []):
            why = rule_unsupported(rule, bad)
            if why:
                notes.append(f"rule {policy['id']}/{rule['id']}: {why}; stays in the UI, the rest of the policy is adopted")
            else:
                rules.append(rule)
        if not rules:
            # A policy with no rule to adopt stays whole in the UI: data/ holds no
            # empty policies.
            reason = f"policy {policy['id']}: none of its {len(policy.get('rules', []))} rule(s) can be adopted"
            if policy["id"] in args.policy:
                sys.exit(f"error: {reason}. Nothing was written.")
            kept_in_ui += [n.replace("; stays in the UI, the rest of the policy is adopted", "") for n in notes] + [reason]
            continue
        kept_in_ui += notes
        adoptable.append(dict(policy, rules=rules))
    policies = adoptable

    writer = Writer(args.dry_run, overwrite=args.mirror)
    security_stack = "global-security" if role == "gm" else "local-security"
    import_path = REPO_ROOT / "stacks" / security_stack / f"import-{args.site}-{tranche}.tf"
    mirror_header = (
        f"{MIRROR_MARK}{args.site}\n"
        f"# Mirror of {args.site}, regenerated from the live manager by scripts/mirror.sh.\n"
        "# Do not edit: the next sync overwrites this file. Change the object in NSX, or\n"
        "# move the manager to mode: managed (docs/IMPORT.md, \"Mirror mode\").\n\n"
    )
    if args.mirror and not args.dry_run:
        # Start from nothing: what NSX no longer has must not survive here.
        for f in own:
            f.unlink()
        import_path.unlink(missing_ok=True)

    # --- groups ---------------------------------------------------------
    converted_groups = {
        g["id"]: convert_group(g, group_paths, owner, sites) for g in groups if not is_system(g)
    }
    if role == "gm":
        # A group outside the global domain keeps its domain, where the GM stack
        # creates it and Local Managers find it (local-security).
        for g in groups:
            where = domain_of(g.get("path", ""), domain)
            if g["id"] in converted_groups and where != "default":
                converted_groups[g["id"]]["domain"] = where
    if converted_groups:
        header = mirror_header if args.mirror else (
            f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}. Adopted, not created.\n"
            "#\n"
            "# Review before the first apply: check every 'why_static' note, and confirm\n"
            "# the tag scopes below are in data/schema/tag-scopes.yaml.\n\n"
        )
        writer.write(DATA / "groups" / f"imported-{args.site}-{tranche}.yaml", header + to_yaml({"groups": converted_groups}))

    # --- services -------------------------------------------------------
    custom = {s["id"]: convert_service(s) for s in services if not is_system(s)}
    predefined = {
        s["id"]: s.get("display_name", s["id"])
        for s in services
        if is_system(s) and _referenced(s, policies)
    }
    if custom or predefined:
        document: dict = {}
        if predefined:
            # By id, never by display name: names are not unique (a federated
            # Local Manager lists its own HTTPS and the Global Manager's).
            document["predefined_ids"] = predefined
        if custom:
            for definition in custom.values():
                definition["owner"] = owner
                if owner == "lm":
                    definition["sites"] = list(sites)
            document["custom"] = custom
        header = mirror_header if args.mirror else f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}.\n\n"
        writer.write(DATA / "services" / f"imported-{args.site}-{tranche}.yaml", header + to_yaml(document))

    # --- policies: one file each, so add-rule.py can find them ----------
    for policy in policies:
        if is_system(policy):
            continue
        document = convert_policy(policy, group_paths, service_paths, owner, sites)
        where = domain_of(policy.get("path", ""), domain)
        if role == "gm" and where != "default":
            document["policy"]["domain"] = where
        header = mirror_header if args.mirror else (
            f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}. Adopted, not created.\n"
            "#\n"
            "# A new rule for this policy belongs IN THIS FILE. Do not declare a second\n"
            f"# policy: scripts/add-rule.py --policy {policy['id']} --rule <name> ...\n\n"
        )
        writer.write(DATA / "policies" / f"{policy['id']}.yaml", header + to_yaml(document))

    # --- import blocks --------------------------------------------------
    base: dict = {}
    composite: dict = {}
    for group_id, definition in converted_groups.items():
        nested = any("member_groups" in c for c in definition.get("criteria", []))
        path = next((g["path"] for g in groups if g["id"] == group_id), "")
        (composite if nested else base)[group_id] = object_id("group", domain_of(path, domain), path, group_id, args.id_format)
    service_ids = {
        s["id"]: object_id("service", domain, s.get("path", ""), s["id"], args.id_format)
        for s in services
        if not is_system(s) and s["id"] in custom
    }
    policy_ids: dict = {}
    rule_ids: dict = {}
    for policy in policies:
        if is_system(policy):
            continue
        key = policy["id"]
        policy_ids[key] = object_id("policy", domain_of(policy.get("path", ""), domain), policy.get("path", ""), key, args.id_format)
        for rule in policy.get("rules", []):
            rule_ids[f"{key}/{rule['id']}"] = {
                "policy": key,
                "rule": rule["id"],
                "id": object_id("rule", domain_of(policy.get("path", ""), domain), rule.get("path", ""), f"{key}/{rule['id']}", args.id_format),
            }

    kinds = [
        ("base_groups", "module.base_groups.nsxt_policy_group.this[each.key]", base),
        ("composite_groups", "module.composite_groups.nsxt_policy_group.this[each.key]", composite),
        ("services", "module.services.nsxt_policy_service.this[each.key]", service_ids),
        ("policies", "module.policies[each.key].nsxt_policy_parent_security_policy.this", policy_ids),
        ("rules", "module.policies[each.value.policy].nsxt_policy_security_policy_rule.this[each.value.rule]", rule_ids),
    ]
    header = (
        f"# Mirror of {args.site}: every object in the mirror files, imported into state.\n"
        "# Regenerated by scripts/mirror.sh; do not edit.\n"
        "#\n"
        f"# While {args.site} is in mirror mode, its sync-state job applies these imports\n"
        "# (and nothing else) with the read-only credential; an object already in state\n"
        "# is left as it is. After cutover to managed, delete this file in its own merge\n"
        "# request.\n"
        f"#\n# id format: {args.id_format}.\n"
    ) if args.mirror else (
        f"# Generated by scripts/import-estate.py: tranche '{tranche}' for {args.site}.\n"
        "# Adopts existing objects into state; creates nothing.\n"
        "#\n"
        f"#   scripts/tf.sh plan {security_stack} {args.site}\n"
        "#\n"
        "# scripts/plan-guard.py refuses the plan unless it only imports. A tranche is\n"
        "# done when, after the apply, the plan reports no changes. Then delete this\n"
        "# file in its own merge request: import blocks are one-shot.\n"
        "#\n"
        f"# id format: {args.id_format}. If every import fails with a not-found error,\n"
        "# re-run import-estate.py with a different --id-format; nothing has been\n"
        "# written to state at that point.\n"
    )
    if any(entries for _, _, entries in kinds):
        writer.write(import_path, import_file(args.site, tranche, role, kinds, header))

    # --- manifest -------------------------------------------------------
    manifest = {"version": 1, "imported": [], "sources": []}
    if MANIFEST.exists():
        try:
            manifest = json.loads(MANIFEST.read_text())
        except ValueError:
            pass
    before = json.dumps(manifest, indent=2) + "\n"
    if args.mirror:
        # No dated history here: an unchanged manager must leave no diff. Files
        # this mirror no longer writes (deleted in NSX) leave the list too.
        gone = {str(f.relative_to(REPO_ROOT)) for f in own} - set(writer.written)
        manifest["imported"] = [r for r in manifest.get("imported", []) if r not in gone]
    for rel in writer.written:
        if rel not in manifest["imported"]:
            manifest["imported"].append(rel)
    if args.mirror:
        manifest.setdefault("mirrors", {})[args.site] = {"role": role, "domain": domain}
    else:
        manifest["sources"].append(
            {
                "site": args.site,
                "role": role,
                "domain": domain,
                "tranche": tranche,
                "policies": [p["id"] for p in policies if not is_system(p)],
                "when": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "counts": {
                    "groups": len(converted_groups),
                    "policies": len([p for p in policies if not is_system(p)]),
                    "rules": sum(len(p.get("rules", [])) for p in policies if not is_system(p)),
                    "services": len(custom),
                },
            }
        )
    if not args.dry_run and json.dumps(manifest, indent=2) + "\n" != before:
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")

    # --- report ---------------------------------------------------------
    print()
    for rel in writer.written:
        print(f"  wrote     {rel}")
    for note in writer.deferred:
        print(f"  EXISTS    {note}  (your file was not touched — diff and merge by hand)")
    for note in skipped:
        print(f"  MANAGED   {note}  (already in data/, so not adopted again)")
    for note in kept_in_ui:
        print(f"  NOT ADOPTED  {note}")
    if kept_in_ui:
        print("  (these cannot be represented exactly, so importing them would change them on")
        print("   the first apply; they stay as they are, managed in the NSX UI)")
    print()
    print(f"{len(converted_groups)} group(s), {len([p for p in policies if not is_system(p)])} policy/policies, "
          f"{sum(len(p.get('rules', [])) for p in policies if not is_system(p))} rule(s), {len(custom)} custom service(s)")
    if args.dry_run:
        print("dry run — nothing was written.")
        return 0
    if args.mirror:
        print(f"mirror of {args.site} regenerated. While it is in mode: mirror, its plans must only import;")
        print("only its state is updated, by import and refresh. Cutover: docs/IMPORT.md, \"Mirror mode\".")
        return 0
    print()
    print("next:")
    print("  1. make validate")
    print(f"  2. scripts/tf.sh plan {security_stack} {args.site}")
    print("  3. the plan must only import: scripts/plan-guard.py refuses anything else")
    print("  4. apply, then confirm the next plan reports no changes")
    print(f"  5. delete stacks/{security_stack}/import-{args.site}-{tranche}.tf in its own merge request")
    return 0


def survey(site: str, groups: list, services: list, policies: list, federated: dict | None = None) -> int:
    """What could be adopted from this manager, policy by policy. Writes nothing."""
    bad = unsupported_objects(groups, services, federated)
    have = existing_keys()
    rows = []
    for policy in policies:
        if is_system(policy):
            continue
        rules = policy.get("rules", [])
        kept = [r for r in rules if rule_unsupported(r, bad)]
        blocked = [p.rsplit("/", 1)[-1] for p in policy.get("scope") or [] if p in bad]
        if policy["id"] in have["policies"]:
            status = "managed already"
        elif blocked:
            status = f"not adoptable: Apply To uses {', '.join(blocked)}"
        elif kept:
            status = f"adoptable; {len(kept)} of {len(rules)} rule(s) stay in the UI"
        else:
            status = "adoptable"
        rows.append((policy.get("category", ""), policy["id"], policy.get("display_name", ""), len(rules), status))
    print(f"{len(rows)} policy/policies on {site}:")
    print()
    print(f"  {'CATEGORY':<14} {'POLICY ID':<36} {'RULES':>5}  STATUS")
    for category, pid, name, count, status in sorted(rows):
        label = pid if name in ("", pid) else f"{pid} ({name})"
        print(f"  {category:<14} {label:<36} {count:>5}  {status}")
    print()
    print("Adopt one with: --policy <POLICY ID> (in the pipeline: ADOPT_POLICY).")
    return 0


def _referenced(service: dict, policies: list) -> bool:
    path = service.get("path")
    for policy in policies:
        for rule in policy.get("rules", []):
            if path in (rule.get("services") or []):
                return True
    return False


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/import-estate.py

write_file scripts/plan-guard.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Refuse a Terraform plan that would destroy, or duplicate, a live NSX object.

Run on every plan and again before every apply (scripts/tf.sh does both):

  terraform show -json tfplan | scripts/plan-guard.py --site lon1 --stack local-security

Two rules, both mechanical so that nobody has to spot the problem in review:

1. Nothing is destroyed unless that exact resource is approved. A delete, and a
   replace (which deletes the live object first or after), is refused unless
   allow-destroy.txt at the repository root lists it:

       # <site> <stack> <resource address>
       lon1 local-security module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["old-rule"]

   The file is committed, so every approval is in a merge request diff. Remove
   the line once the change is applied. A line that matches nothing in a plan is
   reported as stale.

2. An import tranche is pure. When the stack holds this site's tranche files
   (import-<site>-*.tf, or a legacy import.tf) or the plan imports anything, the plan may only import, read and forget. A create means
   Terraform did not recognise an object that already exists and would build a
   second one; an update means the data does not yet match what is running.
   Fix the data, re-plan. There is deliberately no override: accepting an
   update during adoption can strip a live setting, for example a rule's
   context profiles, which widens the rule.

Handing an object back without deleting it (a removed block with
destroy = false) shows as "forget" and is always allowed.

--observe is stricter still, for a manager in mirror mode (scripts/tf.sh asks
for it before applying to one): the plan may only import and leave alone.
Every create, update, destroy (approved or not) and forget is refused, so what
is applied can only bring Terraform's state up to date with NSX.

Exit status: 0 the plan is allowed, 2 it is refused, 1 usage or input error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ALLOW_FILE = REPO_ROOT / "allow-destroy.txt"


def load_allowed(site: str, stack: str) -> set[str]:
    allowed: set[str] = set()
    if not ALLOW_FILE.exists():
        return allowed
    for number, raw in enumerate(ALLOW_FILE.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) != 3:
            sys.exit(f"error: allow-destroy.txt line {number}: expected '<site> <stack> <address>', got: {raw}")
        if parts[0] == site and parts[1] == stack:
            allowed.add(parts[2])
    return allowed


def import_files(stack_dir: Path, site: str) -> list[Path]:
    """This site's tranche files, and a legacy import.tf, which applies to every site."""
    candidates = list(stack_dir.glob(f"import-{site}-*.tf")) + list(stack_dir.glob("import.tf"))
    return sorted(f for f in candidates if "import {" in f.read_text())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", required=True)
    ap.add_argument("--stack", required=True)
    ap.add_argument("--observe", action="store_true",
                    help="mirror mode: only imports and no-ops; everything else is refused")
    ap.add_argument("plan_json", nargs="?", help="output of 'terraform show -json tfplan' (default: stdin)")
    args = ap.parse_args()

    text = Path(args.plan_json).read_text() if args.plan_json else sys.stdin.read()
    try:
        plan = json.loads(text)
    except ValueError:
        sys.exit("error: plan-guard needs the JSON from 'terraform show -json tfplan'")
    if "resource_changes" not in plan and "planned_values" not in plan:
        sys.exit("error: that is not a Terraform plan in JSON")

    changes = [c for c in plan.get("resource_changes") or [] if c.get("mode", "managed") == "managed"]
    allowed = load_allowed(args.site, args.stack)
    leftover = import_files(REPO_ROOT / "stacks" / args.stack, args.site)
    tranche = bool(leftover) or any(c["change"].get("importing") for c in changes)

    refused: list[tuple[str, str]] = []
    destroy_lines: list[str] = []
    used: set[str] = set()
    counts = {"import": 0, "create": 0, "update": 0, "destroy": 0, "forget": 0}

    for c in changes:
        address = c["address"]
        actions = c["change"]["actions"]
        importing = bool(c["change"].get("importing"))
        if importing:
            counts["import"] += 1
        if args.observe and actions not in (["no-op"], ["read"]):
            refused.append((address, f"{'/'.join(actions)} on a manager in mirror mode: only imports and refreshes are applied to it"))
            continue
        if "delete" in actions:
            counts["destroy"] += 1
            kind = "replace" if "create" in actions else "destroy"
            if address in allowed:
                used.add(address)
            else:
                refused.append((address, f"{kind} of a live object, not approved in allow-destroy.txt"))
                destroy_lines.append(f"{args.site} {args.stack} {address}")
            continue
        if "forget" in actions:
            counts["forget"] += 1
            continue
        if "create" in actions:
            counts["create"] += 1
            if tranche:
                refused.append((address, "create during an import tranche: this object would be built a second time, or its import is missing or has the wrong id"))
            continue
        if "update" in actions:
            counts["update"] += 1
            if tranche:
                why = "the data does not match the live object yet" if importing else "a change mixed into an import tranche; adopt first, change in a later merge request"
                refused.append((address, f"update during an import tranche: {why}"))

    mode = "mirror, observe only" if args.observe else "import tranche (must be pure)" if tranche else "normal"
    print(
        f"plan-guard {args.site}/{args.stack}, {mode}: "
        f"{counts['import']} import, {counts['create']} create, {counts['update']} update, "
        f"{counts['destroy']} destroy/replace, {counts['forget']} hand back"
    )
    # A mirror's import file stays until cutover; it is not a finished tranche.
    if leftover and not counts["import"] and os.environ.get("NSX_MODE") != "mirror":
        names = ", ".join(f"stacks/{args.stack}/{f.name}" for f in leftover)
        print(f"  note: {names} imports nothing new, so that tranche is applied. Delete the file(s)")
        print("        in their own merge request; until then this stack accepts imports only.")
    for stale in sorted(allowed - used):
        print(f"  note: allow-destroy.txt approves '{stale}', which this plan does not destroy; remove the line if it is done")

    if not refused:
        print("plan-guard: allowed.")
        return 0

    print()
    print(f"plan-guard: REFUSED. {len(refused)} change(s) would not be safe to apply:")
    for address, why in refused:
        print(f"  x {address}")
        print(f"      {why}")
    if os.environ.get("NSX_MODE") == "mirror":
        print()
        print(f"{args.site} is in mirror mode, so data/ is a copy of it. A difference here usually means it")
        print("was changed in the UI after the last sync: the next sync brings that in. If it persists, the")
        print("object named above cannot be copied exactly; hand it back (docs/IMPORT.md).")
    if destroy_lines:
        print()
        print("If, and only if, deleting those objects in NSX is the intent, approve each one")
        print("in allow-destroy.txt at the repository root, in the same merge request:")
        for line in destroy_lines:
            print(f"  {line}")
        print("To stop managing an object WITHOUT deleting it, use a removed block instead")
        print("(docs/IMPORT.md, 'Handing an object back').")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/plan-guard.py

write_file scripts/hand-back.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Stop managing one object with Terraform, without deleting it from NSX.

The object goes back to being managed in the NSX UI, exactly as it is. Use it
to undo an adoption, or to retire one rule from code while it keeps running.

  scripts/hand-back.py --stack local-security \\
      --address 'module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["old-rule"]'

In the same merge request, remove the object from data/ (here, the rule from
data/policies/legacy-app.yaml). Terraform refuses the plan while the object is
still declared, so the two cannot get out of step.

How: Terraform's removed block cannot name one instance of a for_each, so the
file first moves the instance to a stand-alone address and then forgets it:
the plan shows "will no longer be managed by Terraform, but will not be
destroyed", and scripts/plan-guard.py allows exactly that. The file is inert
once applied; delete it whenever convenient.

The stack directory is shared by every manager that runs it: a hand-back applies
wherever that address is in state. For a site-local object that is only its own
manager.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ADDRESS = re.compile(r'^(?:module\.[a-z0-9_]+(?:\["[^"]+"\])?\.)*([a-z0-9_]+)\.[a-z0-9_]+(?:\["[^"]+"\])?$')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stack", required=True)
    ap.add_argument("--address", required=True, help="resource address, as in the plan or 'terraform state list'")
    ap.add_argument("--name", help="short name for the file (default: from the address)")
    args = ap.parse_args()

    stack_dir = REPO_ROOT / "stacks" / args.stack
    if not stack_dir.is_dir():
        sys.exit(f"error: no such stack: {args.stack}")
    match = ADDRESS.match(args.address)
    if not match:
        sys.exit(f"error: not a resource address: {args.address}")
    resource_type = match.group(1)
    if not resource_type.startswith("nsxt_"):
        sys.exit(f"error: {resource_type} is not an NSX resource")

    keys = re.findall(r'\["([^"]+)"\]', args.address)
    name = args.name or "_".join(keys) or resource_type
    slug = re.sub(r"[^a-z0-9_]", "_", name.lower()).strip("_")
    target = stack_dir / f"handback-{slug}.tf"
    if target.exists():
        sys.exit(f"error: {target.relative_to(REPO_ROOT)} exists already")

    stand_alone = f"{resource_type}.handback_{slug}"
    target.write_text(
        f"# Hand back to the NSX UI, without deleting: {args.address}\n"
        "# Generated by scripts/hand-back.py. Remove the object from data/ in the same\n"
        "# merge request. Inert once applied; delete this file whenever convenient.\n\n"
        "moved {\n"
        f"  from = {args.address}\n"
        f"  to   = {stand_alone}\n"
        "}\n\n"
        "removed {\n"
        f"  from = {stand_alone}\n"
        "  lifecycle {\n"
        "    destroy = false\n"
        "  }\n"
        "}\n"
    )
    print(f"wrote {target.relative_to(REPO_ROOT)}")
    print("next: remove the object from data/ in the same merge request, then plan.")
    print("      The plan must say it will no longer be managed, and destroy nothing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/hand-back.py

write_file scripts/adopt.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Adopt existing NSX objects from the pipeline: no credentials on any server.
#
# Run by the 'adopt' job, started by hand on the default branch from
# Build -> Pipelines -> Run pipeline, with:
#
#   ADOPT_SITE     the manager, as in inventory/managers.yaml        (required)
#   ADOPT_POLICY   policy ids to adopt, space separated               (optional)
#   ADOPT_TRANCHE  a name for this piece of work                      (optional)
#
# Without ADOPT_POLICY it is a survey: it lists the manager's policies and what
# can be adopted, and changes nothing. With it, it converts those policies and
# what they need, commits that to a new branch adopt/<site>-<tranche>, and opens
# a merge request. From there it is an ordinary change: the merge request
# pipeline plans it, scripts/plan-guard.py refuses anything but a pure import,
# a person reviews it, and the apply is the usual manual job after the merge.
#
# What it never does: apply, push to the default branch, or keep the capture.
# It reads the manager with the read-only plan credential, and the capture
# lives in a temporary directory removed when the job ends.
#
# Needs NSX_ADOPT_TOKEN: a project access token with the api and
# write_repository scopes (role Developer is enough to push a branch and open a
# merge request; branch protection still keeps it off the default branch).
# Masked and protected.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
	echo "error: $*" >&2
	exit 1
}

SITE="${ADOPT_SITE:-}"
POLICIES="${ADOPT_POLICY:-}"
TRANCHE="${ADOPT_TRANCHE:-}"
[ -n "$SITE" ] || die "ADOPT_SITE is not set: the manager to adopt from, as in inventory/managers.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dump="$work/capture.json"

echo "== reading $SITE (read-only)"
NSX_CRED_SCOPE=plan scripts/with-credentials.sh "$SITE" -- \
	python3 scripts/import-estate.py --site "$SITE" --dump-only "$dump"

if [ -z "$POLICIES" ]; then
	echo
	python3 scripts/import-estate.py --site "$SITE" --from-dump "$dump" --list
	echo "Survey only: nothing was changed. Run the pipeline again with ADOPT_POLICY to adopt."
	exit 0
fi

args=()
for p in $POLICIES; do args+=(--policy "$p"); done
[ -z "$TRANCHE" ] || args+=(--tranche "$TRANCHE")
first="${POLICIES%% *}"
tranche="${TRANCHE:-$first}"
branch="adopt/${SITE}-${tranche}"

[ -n "${NSX_ADOPT_TOKEN:-}${NSX_ADOPT_REMOTE:-}" ] ||
	die "NSX_ADOPT_TOKEN is not set: a project access token (api, write_repository), masked and protected"

echo "== converting: $POLICIES"
git checkout -q -B "$branch"
report="$(python3 scripts/import-estate.py --site "$SITE" --from-dump "$dump" "${args[@]}")"
echo "$report"
if ! grep -q "  wrote " <<<"$report"; then
	echo "Nothing to adopt: everything named is already managed, or cannot be adopted (see above)."
	exit 0
fi

validation="$(python3 scripts/validate-data.py 2>&1 || true)"
echo "$validation" | tail -5

git add -A data stacks
git -c user.name="${GITLAB_USER_NAME:-nsx-adopt}" -c user.email="${GITLAB_USER_EMAIL:-nsx-adopt@localhost}" \
	-c commit.gpgsign=false commit -q -m "Adopt $POLICIES from $SITE

Converted by scripts/adopt.sh in pipeline ${CI_PIPELINE_ID:-local}. Imports only:
nothing in NSX changes when this is applied."

echo "== pushing $branch"
push_env=()
if [ -n "${NSX_ADOPT_REMOTE:-}" ]; then
	remote="$NSX_ADOPT_REMOTE"
	auth=()
else
	remote="${CI_SERVER_URL%/}/${CI_PROJECT_PATH}.git"
	# The token goes in a header, never in the URL, so it cannot end up in a log.
	auth=(-c "http.extraHeader=Authorization: Basic $(printf 'oauth2:%s' "$NSX_ADOPT_TOKEN" | base64 | tr -d '\n')")
	# The runner's CA setup applies to the clone, which runs in another container;
	# this push runs here, so it is given GitLab's CA itself. Through the
	# environment, because an inherited GIT_SSL_CAINFO overrides git's config.
	if [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then
		push_env=(GIT_SSL_CAINFO="$CI_SERVER_TLS_CA_FILE")
	fi
fi
env "${push_env[@]}" git "${auth[@]}" push -q "$remote" "HEAD:refs/heads/$branch" ||
	die "could not push $branch. If it exists already, an adoption of this tranche is open: merge or close it, or set ADOPT_TRANCHE."

echo "== opening the merge request"
api="${CI_API_V4_URL:?CI_API_V4_URL is not set}"
body="$work/mr.json"
# Through files: a large report is over the kernel's limit for one environment
# variable or argument (128 KiB).
printf '%s\n' "$report" >"$work/report.txt"
printf '%s\n' "$validation" >"$work/validation.txt"
BRANCH="$branch" TARGET="${CI_DEFAULT_BRANCH:-main}" SITE="$SITE" POLICIES="$POLICIES" \
	python3 - "$body" "$work/report.txt" "$work/validation.txt" <<'PY'
import json, os, sys
e = os.environ
MAX = 400  # lines per list; GitLab caps a description at 1 MB, and the job log has them all
def capped(lines):
    return lines if len(lines) <= MAX else lines[:MAX] + [f"... and {len(lines) - MAX} more: see the adopt job's log"]
lines = capped([l for l in open(sys.argv[2]).read().splitlines() if l.strip() and not l.startswith(("next:", "  1.", "  2.", "  3.", "  4.", "  5."))])
summary = capped([l for l in open(sys.argv[3]).read().splitlines() if l.startswith(("ERROR", "checked"))])
description = "\n".join([
    f"Adopts `{e['POLICIES']}` from **{e['SITE']}**, as converted by the `adopt` pipeline job.",
    "",
    "**Imports only.** Applying this changes nothing in NSX. The plan in this merge request must read",
    "`N to import, 0 to add, 0 to change, 0 to destroy`; `scripts/plan-guard.py` fails it otherwise.",
    "",
    "### Converter report",
    "```", *lines, "```",
    "",
    "### Validation",
    "```", *(summary or ["(clean)"]), "```",
    "",
    "### Before approving",
    "- [ ] every `why_static` note replaced with the real reason",
    "- [ ] new tag scopes are in `data/schema/tag-scopes.yaml` on purpose",
    "- [ ] the objects listed as NOT ADOPTED are fine to leave in the UI",
    "- [ ] the plan is a pure import",
    "",
    "After the apply, the next plan must report no changes; then delete the `import-*.tf` file this added, in its own merge request.",
])
json.dump({
    "source_branch": e["BRANCH"], "target_branch": e["TARGET"], "remove_source_branch": True,
    "title": f"Adopt {e['POLICIES']} from {e['SITE']}", "description": description,
}, open(sys.argv[1], "w"))
PY
token_header=()
[ -z "${NSX_ADOPT_TOKEN:-}" ] || token_header=(--header "PRIVATE-TOKEN: ${NSX_ADOPT_TOKEN}")
response="$(curl --silent --show-error --fail-with-body --max-time 60 \
	${CI_SERVER_TLS_CA_FILE:+--cacert "$CI_SERVER_TLS_CA_FILE"} \
	"${token_header[@]}" --header "Content-Type: application/json" \
	--data "@$body" "${api%/}/projects/${CI_PROJECT_ID:?CI_PROJECT_ID is not set}/merge_requests")" ||
	die "the branch $branch was pushed, but the merge request could not be opened: $response"
url="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("web_url",""))')"
echo "merge request: ${url:-opened}"
SCAFFOLD_EOF
mark_executable scripts/adopt.sh

write_file scripts/mirror.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Mirror mode: keep data/ a copy of managers that are still run from the UI.
#
# Run by the 'mirror' job, on a pipeline schedule (Build -> Pipeline schedules)
# or by hand (Run pipeline) on the default branch, with:
#
#   MIRROR_SITE        a manager from inventory/managers.yaml, several separated
#                      by spaces, or 'all' for every manager in mode: mirror
#   MIRROR_AUTO_MERGE  1 to set the merge request to merge when its pipeline
#                      passes (optional; without it, a person merges it)
#
# For each manager it reads everything (read-only plan credential), rewrites the
# manager's mirror files with scripts/import-estate.py --mirror, and compares
# them with the default branch. If NSX matches the repository there is nothing
# to do. Otherwise it commits the difference to the branch mirror/<site>, which
# it owns and force-pushes, and keeps ONE merge request for it up to date: the
# objects engineers added, changed or deleted in the UI since the last merge.
# When NSX matches the repository again, that merge request is closed.
#
# Only managers in mirror mode are touched. Nothing is applied to NSX for them:
# they have no apply job, and their sync-state job only imports and refreshes
# Terraform's state, with the read-only credential, until mode: managed.
#
# Changes engineers made in the UI since the copy on the default branch are
# also raised as a GitLab issue, labelled nsx-drift (scripts/drift-issue.py):
# who changed what and when, to investigate during the observation period.
#
# Needs NSX_ADOPT_TOKEN, as the adopt job: a project access token with the api
# and write_repository scopes. Masked and protected.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
	echo "error: $*" >&2
	exit 1
}

[ -n "${MIRROR_SITE:-}" ] || die "MIRROR_SITE is not set: a manager in mode: mirror, several, or 'all'"
[ -n "${NSX_ADOPT_TOKEN:-}${NSX_ADOPT_REMOTE:-}" ] ||
	die "NSX_ADOPT_TOKEN is not set: a project access token (api, write_repository), masked and protected"
api="${CI_API_V4_URL:?CI_API_V4_URL is not set}"
project="${CI_PROJECT_ID:?CI_PROJECT_ID is not set}"
target="${CI_DEFAULT_BRANCH:-main}"
base="$(git rev-parse HEAD)"

# Managers, with their mode, from the inventory.
inventory="$(python3 - <<'PY'
import sys
sys.path.insert(0, "scripts")
from ci_matrix_lib import managers, mode_of
for name, m in sorted(managers().items()):
    if m.get("enabled") is not False:
        print(name, mode_of(name, m))
PY
)" || die "cannot read the managers' modes (above)"
mode_of() { awk -v s="$1" '$1 == s { print $2 }' <<<"$inventory"; }
if [ "$MIRROR_SITE" = all ]; then
	sites="$(awk '$2 == "mirror" { print $1 }' <<<"$inventory")"
	if [ -z "$sites" ]; then
		echo "error: no manager in inventory/managers.yaml has mode: mirror. On the branch this ran on:" >&2
		while read -r name mode; do
			echo "  $name: $mode" >&2
		done <<<"$inventory"
		die "add 'mode: mirror' to each manager to copy, in inventory/managers.yaml, through a merge request"
	fi
else
	sites="$MIRROR_SITE"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

token_header=()
[ -z "${NSX_ADOPT_TOKEN:-}" ] || token_header=(--header "PRIVATE-TOKEN: ${NSX_ADOPT_TOKEN}")
gitlab() { # gitlab METHOD PATH [JSON-FILE]: the project API; the token stays in a header
	local data=()
	[ -z "${3:-}" ] || data=(--header "Content-Type: application/json" --data "@$3")
	curl --silent --show-error --fail-with-body --max-time 60 -X "$1" \
		${CI_SERVER_TLS_CA_FILE:+--cacert "$CI_SERVER_TLS_CA_FILE"} \
		${token_header[@]+"${token_header[@]}"} ${data[@]+"${data[@]}"} "${api%/}/projects/${project}$2"
}
json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d, list) and d else d; print((d or {}).get(sys.argv[1], "") if isinstance(d, dict) else "")' "$1"; }

push_branch() { # push_branch BRANCH: force, as the branch belongs to this job
	local remote push_env=() auth=()
	if [ -n "${NSX_ADOPT_REMOTE:-}" ]; then
		remote="$NSX_ADOPT_REMOTE"
	else
		remote="${CI_SERVER_URL%/}/${CI_PROJECT_PATH}.git"
		# In a header, never in the URL, so the token cannot reach a log.
		auth=(-c "http.extraHeader=Authorization: Basic $(printf 'oauth2:%s' "$NSX_ADOPT_TOKEN" | base64 | tr -d '\n')")
		# GitLab's CA through the environment: an inherited GIT_SSL_CAINFO overrides git's config.
		if [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then
			push_env=(GIT_SSL_CAINFO="$CI_SERVER_TLS_CA_FILE")
		fi
	fi
	env ${push_env[@]+"${push_env[@]}"} git ${auth[@]+"${auth[@]}"} push -q --force "$remote" "HEAD:refs/heads/$1"
}

failed=()
for site in $sites; do
	echo
	echo "=== $site"
	case "$(mode_of "$site")" in
	mirror) ;;
	"")
		echo "error: $site is not an enabled manager in inventory/managers.yaml" >&2
		failed+=("$site")
		continue
		;;
	*)
		echo "error: $site is in mode: managed. Terraform owns it now; mirroring would overwrite the repository with whatever the UI holds." >&2
		failed+=("$site")
		continue
		;;
	esac
	branch="mirror/$site"
	git checkout -q -f -B "$branch" "$base"

	dump="$work/$site.json"
	if ! NSX_CRED_SCOPE=plan scripts/with-credentials.sh "$site" -- \
		python3 scripts/import-estate.py --site "$site" --dump-only "$dump"; then
		failed+=("$site")
		continue
	fi
	if ! report="$(python3 scripts/import-estate.py --site "$site" --from-dump "$dump" --mirror)"; then
		echo "$report"
		failed+=("$site")
		continue
	fi
	grep -E "NOT ADOPTED|MANAGED|group\(s\)" <<<"$report" || true

	git add -A data stacks
	open_mr="$(gitlab GET "/merge_requests?state=opened&source_branch=$branch&target_branch=$target" | json_field iid)" || open_mr=""
	if git diff --cached --quiet; then
		echo "$site matches the repository: nothing to do."
		if [ -n "$open_mr" ]; then
			printf '{"state_event": "close"}' >"$work/close.json"
			gitlab PUT "/merge_requests/$open_mr" "$work/close.json" >/dev/null &&
				echo "closed merge request !$open_mr: NSX matches the repository again."
		fi
		continue
	fi

	changes="$(git diff --cached --name-status)"
	echo "$changes"
	git -c user.name="${GITLAB_USER_NAME:-nsx-mirror}" -c user.email="${GITLAB_USER_EMAIL:-nsx-mirror@localhost}" \
		-c commit.gpgsign=false commit -q -m "Mirror $site from NSX

Regenerated by scripts/mirror.sh in pipeline ${CI_PIPELINE_ID:-local}: what was
added, changed or deleted in the NSX UI. $site is in mirror mode: nothing
is applied to NSX; once merged, its state follows by import and refresh."
	if ! push_branch "$branch"; then
		echo "error: could not push $branch" >&2
		failed+=("$site")
		continue
	fi

	# Through files: a large manager's text is over the kernel's limit for one
	# environment variable or argument (128 KiB).
	printf '%s\n' "$changes" >"$work/changes.txt"
	printf '%s\n' "$report" >"$work/report.txt"
	SITE="$site" BRANCH="$branch" TARGET="$target" NEW="${open_mr:-}" \
		python3 - "$work/mr.json" "$work/changes.txt" "$work/report.txt" <<'PY'
import json, os, sys
e = os.environ
MAX = 400  # lines per list; GitLab caps a description at 1 MB, and the job log has them all
def capped(lines):
    return lines if len(lines) <= MAX else lines[:MAX] + [f"... and {len(lines) - MAX} more: see the mirror job's log"]
kinds = {"A": "added", "M": "changed", "D": "deleted"}
rows = []
for line in open(sys.argv[2]).read().splitlines():
    status, _, path = line.partition("\t")
    if not path or path.endswith(".import-manifest.json"):
        continue
    rows.append(f"| {kinds.get(status[:1], status)} | `{path}` |")
rows = capped(rows)
kept = capped([l.strip() for l in open(sys.argv[3]).read().splitlines() if "NOT ADOPTED" in l or "  MANAGED" in l])
description = "\n".join([
    f"**{e['SITE']}** is in mirror mode: engineers change it in the NSX UI, and this merge request",
    "brings the repository up to date with what it holds now. It is regenerated on every sync until merged.",
    "",
    "**Nothing is applied to NSX.** A manager in mirror mode has no apply job; once this is merged, its",
    "`sync-state` job only imports and refreshes Terraform's state, with the read-only credential. The plan",
    "here must only import: a red plan names an object that would not be taken over cleanly.",
    "",
    "| | file |", "|---|---|", *rows,
    "",
    "### Left in the UI",
    "```", *(kept or ["(nothing)"]), "```",
])
body = {"title": f"Mirror {e['SITE']} from NSX", "description": description}
if not e["NEW"]:
    body.update(source_branch=e["BRANCH"], target_branch=e["TARGET"], remove_source_branch=True)
json.dump(body, open(sys.argv[1], "w"))
PY
	if [ -n "$open_mr" ]; then
		response="$(gitlab PUT "/merge_requests/$open_mr" "$work/mr.json")" || { failed+=("$site"); continue; }
		iid="$open_mr"
		echo "updated merge request !$iid"
	else
		response="$(gitlab POST "/merge_requests" "$work/mr.json")" || {
			echo "error: $branch was pushed, but the merge request could not be opened: $response" >&2
			failed+=("$site")
			continue
		}
		iid="$(json_field iid <<<"$response")"
		echo "merge request: $(json_field web_url <<<"$response")"
	fi

	# What engineers changed in the UI since the copy on the default branch,
	# raised as an issue to investigate. A failure here is reported, not fatal:
	# the merge request already carries the changes.
	if ! python3 scripts/drift-issue.py mirror --site "$site" --base "$base" --dump "$dump" \
		--link "$(json_field web_url <<<"$response")"; then
		echo "warning: the drift issue for $site could not be raised (above)" >&2
	fi

	if [ "${MIRROR_AUTO_MERGE:-}" = 1 ] && [ -n "$iid" ]; then
		# The push starts the merge request pipeline a moment later; until it
		# exists GitLab refuses to schedule the merge.
		printf '{"merge_when_pipeline_succeeds": true, "should_remove_source_branch": true}' >"$work/merge.json"
		scheduled=0
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			if gitlab PUT "/merge_requests/$iid/merge" "$work/merge.json" >/dev/null 2>&1; then
				scheduled=1
				break
			fi
			sleep "${MIRROR_RETRY_SLEEP:-6}"
		done
		if [ "$scheduled" = 1 ]; then
			echo "set to merge when its pipeline passes"
		else
			echo "note: GitLab would not schedule the merge (no pipeline yet, or merge checks); merge !$iid by hand."
		fi
	fi
done
git checkout -q -f "$base" 2>/dev/null || true

if [ "${#failed[@]}" -gt 0 ]; then
	die "not mirrored: ${failed[*]} (above)"
fi
SCAFFOLD_EOF
mark_executable scripts/mirror.sh

write_file scripts/drift-issue.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Raise a GitLab issue for changes made in NSX outside this repository, so
each one is investigated: who made it, why, and whether it stays.

  scripts/drift-issue.py mirror --site S --base REF --dump FILE [--link URL]
      Run by scripts/mirror.sh after it rewrote a manager's mirror files:
      compares them, object by object, with REF (the default branch).
  scripts/drift-issue.py plan --site S --stack STACK --plan-json FILE [--link URL]
      Run by scripts/drift-job.sh for a manager in mode: managed: the drift
      a refresh-only plan found (NSX no longer matches Terraform's state).

One issue per run that found something new, labelled nsx-drift and
site:<site>. It lists each object, what changed, and who last changed it and
when, as NSX records them on every object it still has. That is the tracker
for the observation period: close an issue once every change in it is
explained.

Each object is reported once per version. The next run seeing the same change
does not report it again (the issues themselves are the record, nothing else
is kept); a further change to the same object is reported. In mirror mode:

  * The first copy of a manager is its baseline, not drift.
  * A difference whose object NSX says nobody modified since the copy on REF
    (less an hour, the time a sync may take) is not drift either: it comes from
    the repository side, typically an object a newer importer can take over
    for the first time.

Needs NSX_BOT_TOKEN or NSX_ADOPT_TOKEN (scope api). Exit status: 0 done
(issue raised, or nothing new), 1 error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_all  # noqa: E402

LABEL = "nsx-drift"
MIRROR_MARK = "# nsx-mirror: "
MARK = re.compile(r"<!-- nsx-drift object=([0-9a-f]{16}) version=([0-9a-f]{16}) -->")
MAX_ROWS = 300
SYNC_MARGIN = 3600  # seconds: a sync reads the manager this long, at most, before its commit


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()[:16]


class GitLab:
    def __init__(self) -> None:
        self.api = os.environ.get("CI_API_V4_URL", "").rstrip("/")
        self.project = os.environ.get("CI_PROJECT_ID", "")
        self.token = os.environ.get("NSX_BOT_TOKEN") or os.environ.get("NSX_ADOPT_TOKEN") or ""
        if not (self.api and self.project):
            die("CI_API_V4_URL and CI_PROJECT_ID are not set: this runs in a GitLab job")
        if not self.token:
            die("NSX_BOT_TOKEN (or NSX_ADOPT_TOKEN) is not set: a project access token with the api scope")
        ca = os.environ.get("CI_SERVER_TLS_CA_FILE")
        self.ctx = ssl.create_default_context(cafile=ca) if ca and Path(ca).is_file() else ssl.create_default_context()
        self.ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)

    def call(self, method: str, path: str, body: dict | None = None, query: dict | None = None):
        url = f"{self.api}/projects/{urllib.parse.quote(self.project, safe='')}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("PRIVATE-TOKEN", self.token)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, context=self.ctx, timeout=60) as response:
                return json.loads(response.read().decode() or "null"), response.headers
        except urllib.error.HTTPError as exc:
            die(f"GitLab API {method} {path}: HTTP {exc.code} {exc.read().decode(errors='replace')[:300]}")
        except urllib.error.URLError as exc:
            die(f"GitLab API {method} {path}: {exc.reason}")

    def reported(self, site: str) -> set[tuple[str, str]]:
        """(object, version) pairs already in an nsx-drift issue for this site, open or closed."""
        seen: set[tuple[str, str]] = set()
        page = "1"
        for _ in range(10):  # the 1000 most recent issues
            issues, headers = self.call("GET", "/issues", query={
                "labels": f"{LABEL},site:{site}", "state": "all", "order_by": "created_at",
                "sort": "desc", "per_page": 100, "page": page})
            for issue in issues or []:
                seen.update(MARK.findall(issue.get("description") or ""))
            page = (headers.get("X-Next-Page") or "").strip()
            if not page:
                break
        return seen


# --------------------------------------------------------------------------
# What changed
# --------------------------------------------------------------------------

def mirror_objects(files: dict[str, str], site: str) -> dict[tuple[str, str], dict]:
    """(kind, id) -> definition, from this site's mirror files."""
    out: dict[tuple[str, str], dict] = {}
    mine = {path: text for path, text in files.items() if text.split("\n", 1)[0].strip() == f"{MIRROR_MARK}{site}"}
    # In one go: without PyYAML that is one terraform call, not one per file.
    for (path, text), doc in zip(mine.items(), load_all(list(mine.values()))):
        doc = doc or {}
        if path.startswith("data/groups/"):
            for key, value in (doc.get("groups") or {}).items():
                out[("group", str(key))] = value
        elif path.startswith("data/services/"):
            for key, value in (doc.get("custom") or {}).items():
                out[("service", str(key))] = value
        elif path.startswith("data/policies/"):
            header = doc.get("policy") or {}
            pid = str(header.get("id") or Path(path).stem)
            out[("policy", pid)] = header
            for key, value in (doc.get("rules") or {}).items():
                out[("rule", f"{pid}/{key}")] = value
    return out


def files_at(ref: str) -> dict[str, str]:
    """The data files at ref, read in one git process."""
    names = subprocess.run(["git", "ls-tree", "-r", "--name-only", ref, "--", "data/groups", "data/services", "data/policies"],
                           cwd=REPO_ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
    names = [n for n in names if n.endswith(".yaml")]
    if not names:
        return {}
    batch = subprocess.run(["git", "cat-file", "--batch"], cwd=REPO_ROOT, check=True, capture_output=True,
                           input="".join(f"{ref}:{n}\n" for n in names).encode()).stdout
    out: dict[str, str] = {}
    at = 0
    for name in names:
        header_end = batch.index(b"\n", at)
        size = int(batch[at:header_end].split()[2])
        out[name] = batch[header_end + 1:header_end + 1 + size].decode()
        at = header_end + 1 + size + 1
    return out


def files_now() -> dict[str, str]:
    out: dict[str, str] = {}
    for kind in ("groups", "services", "policies"):
        for f in sorted((REPO_ROOT / "data" / kind).glob("*.yaml")):
            out[str(f.relative_to(REPO_ROOT))] = f.read_text()
    return out


def describe(before, after) -> str:
    """What differs between two versions of one object, briefly."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return "changed"
    parts = []
    for key in sorted(set(before) | set(after)):
        old, new = before.get(key), after.get(key)
        if old == new:
            continue
        if isinstance(old, list) or isinstance(new, list):
            o = [json.dumps(x, sort_keys=True) if not isinstance(x, str) else x for x in old or []]
            n = [json.dumps(x, sort_keys=True) if not isinstance(x, str) else x for x in new or []]
            plus = [x for x in n if x not in o]
            minus = [x for x in o if x not in n]
            if all(isinstance(x, str) for x in (old or []) + (new or [])) and (plus or minus):
                parts.append(f"{key} " + " ".join([f"+{x}" for x in plus] + [f"-{x}" for x in minus]))
            else:
                parts.append(f"{key} changed")
        elif isinstance(old, dict) or isinstance(new, dict):
            parts.append(f"{key} changed")
        elif old is None:
            parts.append(f"{key} set to {new}")
        elif new is None:
            parts.append(f"{key} removed (was {old})")
        else:
            parts.append(f"{key} {old} → {new}")
    text = "; ".join(parts) or "changed"
    return text if len(text) <= 240 else text[:237] + "..."


def nsx_index(dump: dict) -> dict[tuple[str, str], dict]:
    """(kind, id) -> the object as NSX returned it, for who changed it and when."""
    out: dict[tuple[str, str], dict] = {}
    for g in dump.get("groups", []):
        out.setdefault(("group", g.get("id", "")), g)
    for s in dump.get("services", []):
        out.setdefault(("service", s.get("id", "")), s)
    for p in dump.get("policies", []):
        out.setdefault(("policy", p.get("id", "")), p)
        for r in p.get("rules", []):
            out.setdefault(("rule", f"{p.get('id')}/{r.get('id')}"), r)
    return out


def when(obj: dict | None) -> tuple[str, str, float | None]:
    """Who last changed an NSX object, when (text), and when (epoch seconds)."""
    if not obj:
        return "", "", None
    stamp = obj.get("_last_modified_time") or obj.get("_create_time")
    seconds = stamp / 1000 if isinstance(stamp, (int, float)) else None
    text = datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%d %H:%M") if seconds else ""
    return str(obj.get("_last_modified_user") or obj.get("_create_user") or ""), text, seconds


def mirror_changes(site: str, base: str, dump: dict) -> list[dict] | None:
    """The changes to report; None when REF holds no copy of the site yet (baseline)."""
    old_files = files_at(base)
    old = mirror_objects(old_files, site)
    if not old:
        return None
    new = mirror_objects(files_now(), site)
    mine = [p for p, t in old_files.items() if t.split("\n", 1)[0].strip() == f"{MIRROR_MARK}{site}"]
    copied = int(subprocess.run(["git", "log", "-1", "--format=%ct", base, "--", *mine], cwd=REPO_ROOT,
                                capture_output=True, text=True, check=True).stdout.strip() or 0)
    since = copied - SYNC_MARGIN
    live = nsx_index(dump)
    gone_policies = {k[1] for k in old if k[0] == "policy" and k not in new}
    items = []
    for key in sorted(set(old) | set(new)):
        kind, ident = key
        before, after = old.get(key), new.get(key)
        if before == after:
            continue
        if kind == "rule" and before is not None and after is None and ident.split("/", 1)[0] in gone_policies:
            continue  # reported with its policy
        who, at, seconds = when(live.get(key))
        if after is not None and seconds is not None and seconds < since:
            continue  # nobody changed it in NSX since the copy: the repository side moved
        if before is None:
            change, detail = "added", ""
        elif after is None:
            change = "deleted"
            detail = f"with its {sum(1 for k in old if k[0] == 'rule' and k[1].startswith(ident + '/'))} rule(s)" if kind == "policy" else ""
            who, at = "", ""
        else:
            change, detail = "changed", describe(before, after)
        items.append({"key": f"{kind} {ident}", "kind": kind, "id": ident, "change": change, "detail": detail,
                      "who": who, "at": at, "version": digest(after) if after is not None else "0" * 16})
    return items


def plan_changes(plan: dict) -> list[dict]:
    """Drift a refresh-only plan found, with who and when from NSX when it can be read."""
    items = []
    for drift in plan.get("resource_drift") or []:
        change = drift.get("change") or {}
        actions = change.get("actions") or []
        before, after = change.get("before"), change.get("after")
        if actions == ["no-op"]:
            continue
        address = drift.get("address", "")
        item = {"key": address, "kind": drift.get("type", "resource"), "id": address,
                "change": "deleted" if after is None else "changed",
                "detail": "" if after is None else describe(
                    {k: v for k, v in (before or {}).items() if k != "revision"},
                    {k: v for k, v in after.items() if k != "revision"}),
                "who": "", "at": "", "version": digest(after) if after is not None else "0" * 16,
                "path": (after or before or {}).get("path", "")}
        items.append(item)
    return items


def lookup_owners(site: str, items: list[dict]) -> None:
    """Who last changed each drifted object, from NSX (read-only credential)."""
    import importlib.util  # noqa: PLC0415
    spec = importlib.util.spec_from_file_location("import_estate", REPO_ROOT / "scripts" / "import-estate.py")
    estate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(estate)
    estate.CA_SITE = site  # this manager's CA, as for its plans
    host, user, password = (os.environ.get(k, "") for k in ("NSXT_MANAGER_HOST", "NSXT_USERNAME", "NSXT_PASSWORD"))
    insecure = os.environ.get("NSXT_ALLOW_UNVERIFIED_SSL", "").strip().lower() in ("true", "1", "yes")
    for item in items:
        path = item.get("path") or ""
        if item["change"] == "deleted" or not path:
            continue
        prefix = "/global-manager/api/v1" if path.startswith("/global-infra/") else "/policy/api/v1"
        try:
            obj = estate.api_get(host, prefix + urllib.parse.quote(path), user, password, insecure)
        except SystemExit:
            continue
        item["who"], item["at"], _ = when(obj)


# --------------------------------------------------------------------------
# The issue
# --------------------------------------------------------------------------

def cell(text: str) -> str:
    return str(text).replace("|", "\\|").replace("\n", " ")


def issue_body(site: str, items: list[dict], mode: str, link: str) -> str:
    source = "the mirror sync" if mode == "mirror" else "a drift check (refresh-only plan)"
    rows = [f"| {i['change']} | `{cell(i['key'])}` | {cell(i['detail'])} | {cell(i['who']) or '?'} | {i['at'] or '?'} |"
            for i in items[:MAX_ROWS]]
    if len(items) > MAX_ROWS:
        rows.append(f"| | ... and {len(items) - MAX_ROWS} more | see the job's log | | |")
    if mode == "mirror":
        keep = ("Intended: nothing to do here, the mirror merge request brings it into the repository "
                "(and Terraform's state follows).")
        undo = "Not intended: revert it in NSX; the next sync takes it out of the repository again."
        after = ("After cutover to `mode: managed` a change like this must come through a merge request: "
                 "the drift check raises it the same way, and the next apply would undo it.")
    else:
        keep = "Intended: bring it into `data/` in a merge request, so the next apply keeps it."
        undo = "Not intended: the next apply of this manager reverts it to the repository, or revert it in NSX."
        after = "This manager is in `mode: managed`: changes are made through merge requests, not the UI."
    lines = [
        f"{source.capitalize()} of **{site}** found {len(items)} change(s) made in NSX, not through this repository.",
        "",
        f"Found by: {link}" if link else "",
        "",
        "| change | object | what changed | last changed by | when (UTC) |",
        "|---|---|---|---|---|",
        *rows,
        "",
        "\"Last changed by\" and \"when\" are what NSX records on the object. NSX keeps nothing on a deleted object: "
        "its audit log (System > Audit) has who deleted it.",
        "",
        "### Investigation",
        "- [ ] Who made each change, and why: the incident or change ticket.",
        f"- [ ] {keep}",
        f"- [ ] {undo}",
        "- [ ] Should it have gone through a merge request? Agree what to do differently, if so.",
        "",
        after,
        "",
        "Close this issue once every change in it is explained.",
        "",
        *[f"<!-- nsx-drift object={digest(i['key'])} version={i['version']} -->" for i in items],
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["mirror", "plan"])
    ap.add_argument("--site", required=True)
    ap.add_argument("--base", help="mirror: the ref the copy is compared with (the default branch)")
    ap.add_argument("--dump", help="mirror: the capture the sync read")
    ap.add_argument("--stack", help="plan: the stack the plan is for")
    ap.add_argument("--plan-json", help="plan: terraform show -json of the refresh-only plan")
    ap.add_argument("--link", default="", help="where it was found (a merge request or job URL)")
    args = ap.parse_args()

    if args.mode == "mirror":
        if not (args.base and args.dump):
            die("mirror needs --base and --dump")
        items = mirror_changes(args.site, args.base, json.loads(Path(args.dump).read_text()))
        if items is None:
            print(f"drift: first copy of {args.site}, the baseline: no drift issue.")
            return 0
    else:
        if not (args.stack and args.plan_json):
            die("plan needs --stack and --plan-json")
        items = plan_changes(json.loads(Path(args.plan_json).read_text()))
        if items and os.environ.get("NSXT_MANAGER_HOST"):
            lookup_owners(args.site, items)
    if not items:
        print(f"drift: no change made in NSX on {args.site} to report.")
        return 0

    gitlab = GitLab()
    seen = gitlab.reported(args.site)
    new = [i for i in items if (digest(i["key"]), i["version"]) not in seen]
    if not new:
        print(f"drift: {len(items)} change(s) on {args.site}, each already in an nsx-drift issue.")
        return 0
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    where = f" ({args.stack})" if args.stack else ""
    issue, _ = gitlab.call("POST", "/issues", {
        "title": f"NSX drift on {args.site}{where}: {len(new)} change(s) made outside the repository, {stamp}",
        "description": issue_body(args.site, new, args.mode, args.link),
        "labels": f"{LABEL},site:{args.site}",
    })
    print(f"drift: {len(new)} change(s) on {args.site} to investigate: {(issue or {}).get('web_url', 'issue raised')}")
    for i in new[:20]:
        print(f"  {i['change']:8} {i['key']}  {i['who']} {i['at']}".rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
SCAFFOLD_EOF
mark_executable scripts/drift-issue.py

write_file scripts/drift.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Detect drift. Report it. Change nothing.
#
#   scripts/with-credentials.sh lon1 -- scripts/drift.sh local-security lon1
#
# Administrators make UI changes, especially during an incident. This tells you
# what diverged; it never reverts, and it never writes back into data/. An
# auto-revert during an active incident undoes the fix someone applied to stop
# an outage, and a tool that rewrites your data files on a drift signal would
# quietly overwrite the estate you imported.
#
# Reports go to reports/, which is gitignored: a plan reveals the security
# posture of the estate and is not a review attachment. With DRIFT_JSON set, the
# plan is also written there as JSON (scripts/drift-job.sh raises an issue from it).
#
# Exit status: 0 no drift, 1 error, 2 drift detected.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 2 ] || {
	echo "usage: drift.sh <stack> <site>" >&2
	exit 1
}

stack="$1"
site="$2"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_dir="$REPO_ROOT/reports"
report="$report_dir/drift-${stack}-${site}-${stamp}.txt"

mkdir -p "$report_dir"

# -refresh-only compares state against the live manager without proposing any
# configuration change, so nothing here can be mistaken for a fix. Through
# tf.sh, so the plan has the manager's variables, state and trust.
"$REPO_ROOT/scripts/tf.sh" drift "$stack" "$site" -no-color >"$report" 2>&1
status=$?

case "$status" in
0)
	echo "no drift: $stack @ $site"
	rm -f "$report"
	exit 0
	;;
2)
	echo "DRIFT DETECTED: $stack @ $site"
	echo "report: ${report#"$REPO_ROOT"/}"
	echo
	grep -E '^\s*[~+-]|will be updated|has changed|Objects have changed' "$report" | head -40
	echo
	echo "This is a ticket, not an auto-fix. Either bring the change into data/ or"
	echo "revert it deliberately. Nothing in data/ has been modified."
	exit 2
	;;
*)
	echo "error running the refresh-only plan; see ${report#"$REPO_ROOT"/}" >&2
	exit 1
	;;
esac
SCAFFOLD_EOF
mark_executable scripts/drift.sh

write_file scripts/drift-job.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# The 'drift' job: for managers in mode: managed, find changes made in NSX
# outside this repository and raise each as a GitLab issue to investigate.
#
# Run from a pipeline schedule (or Run pipeline) on the default branch with
#   DRIFT_SITE   a manager, several separated by spaces, or 'all'
#
# For each manager and stack: a refresh-only plan with the read-only plan
# credential (scripts/drift.sh), then scripts/drift-issue.py. Nothing is
# changed, in NSX or in the repository. Managers in mode: mirror are left to
# the mirror job, which raises their drift itself. Exit status: 0 done, drift
# or not (drift is an issue, not a failed job); 1 a manager could not be checked.
#
# Needs NSX_BOT_TOKEN or NSX_ADOPT_TOKEN (api scope), masked and protected.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if [ "${1:-}" = --one ]; then # --one SITE STACK, inside with-credentials.sh
	site="$2"
	stack="$3"
	json="$(mktemp)"
	trap 'rm -f "$json"' EXIT
	DRIFT_JSON="$json" scripts/drift.sh "$stack" "$site"
	case $? in
	0) exit 0 ;;
	2) python3 scripts/drift-issue.py plan --site "$site" --stack "$stack" --plan-json "$json" --link "${CI_JOB_URL:-}" ;;
	*) exit 1 ;;
	esac
	exit $?
fi

[ -n "${DRIFT_SITE:-}" ] || {
	echo "error: DRIFT_SITE is not set: a manager in mode: managed, several, or 'all'" >&2
	exit 1
}
failed=()
checked=0
while read -r site stack _; do
	[ -n "$site" ] || continue
	if [ "$DRIFT_SITE" != all ] && [[ " $DRIFT_SITE " != *" $site "* ]]; then
		continue
	fi
	echo
	echo "=== $site / $stack"
	checked=$((checked + 1))
	NSX_CRED_SCOPE=plan scripts/with-credentials.sh "$site" -- scripts/drift-job.sh --one "$site" "$stack" || failed+=("$site/$stack")
done < <(python3 scripts/ci-matrix.py --format lines --managed-only)

[ "$checked" -gt 0 ] || echo "no manager in mode: managed matches DRIFT_SITE='$DRIFT_SITE' (managers in mirror mode are checked by the mirror job)"
if [ "${#failed[@]}" -gt 0 ]; then
	echo "error: not checked: ${failed[*]} (above)" >&2
	exit 1
fi
SCAFFOLD_EOF
mark_executable scripts/drift-job.sh

write_file scripts/cutover.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Cut a manager over from mirror mode to managed: the copy becomes the source of
# truth, in one merge request that is proven to change nothing in NSX.
#
# Run by the 'cutover' job: Build -> Pipelines -> Run pipeline on the default
# branch, with
#
#   CUTOVER_SITE   the manager, in mode: mirror
#
# 1. Reads the manager (read-only) and checks the repository still holds exactly
#    what it holds: a change made in the UI since the last sync stops here.
# 2. Turns its mirror files into ordinary data files: the "do not edit" header
#    goes, data/groups|services/imported-<site>-mirror.yaml lose "-mirror", and
#    the import blocks (stacks/<stack>/import-<site>-mirror.tf) are deleted:
#    Terraform's state already holds every object. mode: mirror becomes
#    mode: managed in inventory/managers.yaml.
# 3. Plans every stack of the manager with that result. Each plan must change
#    nothing at all (no import, create, update, destroy or hand-back): state
#    holds everything and the files describe NSX exactly. Otherwise it stops
#    and says what differs.
# 4. Pushes the branch cutover/<site> and opens the merge request. Merging it is
#    the cutover. From then on engineers edit those files, or add new ones, in
#    merge requests; a change made in the UI is drift (scripts/drift-job.sh).
#
# Needs NSX_ADOPT_TOKEN, as the mirror job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
	echo "error: $*" >&2
	exit 1
}

site="${CUTOVER_SITE:-}"
[ -n "$site" ] || die "CUTOVER_SITE is not set: the manager to cut over, in mode: mirror"
[ -n "${NSX_ADOPT_TOKEN:-}${NSX_ADOPT_REMOTE:-}" ] ||
	die "NSX_ADOPT_TOKEN is not set: a project access token (api, write_repository), masked and protected"
api="${CI_API_V4_URL:?CI_API_V4_URL is not set}"
project="${CI_PROJECT_ID:?CI_PROJECT_ID is not set}"
target="${CI_DEFAULT_BRANCH:-main}"
base="$(git rev-parse HEAD)"
start="$(git symbolic-ref -q --short HEAD || echo "$base")"
branch="cutover/$site"

mode="$(python3 - "$site" <<'PY'
import sys
sys.path.insert(0, "scripts")
from ci_matrix_lib import managers, mode_of
m = managers().get(sys.argv[1])
print(mode_of(sys.argv[1], m) if m is not None else "")
PY
)" || die "cannot read the inventory (above)"
case "$mode" in
mirror) ;;
"") die "$site is not a manager in inventory/managers.yaml" ;;
*) die "$site is in mode: $mode, not mirror: there is nothing to cut over" ;;
esac

[ -z "$(git status --porcelain -- data stacks inventory)" ] ||
	die "data/, stacks/ or inventory/ has uncommitted changes: commit or stash them first"
work="$(mktemp -d)"
# Back where it started; anything left untracked under data/ or stacks/ was
# written here (the tree was clean above).
trap 'rm -rf "$work"; git checkout -q -f "$start" 2>/dev/null || true; git clean -qfd -- data stacks 2>/dev/null || true' EXIT
git checkout -q -f -B "$branch" "$base"

echo "== 1. $site still matches the repository"
NSX_CRED_SCOPE=plan scripts/with-credentials.sh "$site" -- \
	python3 scripts/import-estate.py --site "$site" --dump-only "$work/capture.json" >/dev/null
python3 scripts/import-estate.py --site "$site" --from-dump "$work/capture.json" --mirror >"$work/report.txt" ||
	{ cat "$work/report.txt"; die "the copy of $site could not be regenerated (above)"; }
if [ -n "$(git status --porcelain -- data stacks)" ]; then
	git status --short -- data stacks | head -40
	die "$site changed in the UI since the last sync (above). Run the mirror (MIRROR_SITE=$site), merge its merge request, let sync-state finish, then cut over again."
fi
echo "it does."

echo "== 2. the copy becomes the source of truth"
python3 - "$site" <<'PY'
import json, re, sys
from datetime import datetime, timezone
from pathlib import Path

site = sys.argv[1]
mark = f"# nsx-mirror: {site}"
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
header = (
    f"# Imported from {site} in mirror mode; managed by this repository since {today}.\n"
    "# Edit it like any data file, in a merge request: change these objects here,\n"
    "# add a rule to a policy in that policy's file (scripts/add-rule.py), and put\n"
    "# new objects in new files. A change made in the NSX UI is drift.\n\n"
)
renamed: dict[str, str] = {}
count = 0
for kind in ("groups", "services", "policies"):
    for f in sorted(Path("data", kind).glob("*.yaml")):
        text = f.read_text()
        if text.split("\n", 1)[0].strip() != mark:
            continue
        lines = text.split("\n")
        i = 0
        while i < len(lines) and lines[i].startswith("#"):
            i += 1
        while i < len(lines) and not lines[i].strip():
            i += 1
        target = f.with_name(f"imported-{site}.yaml") if f.name == f"imported-{site}-mirror.yaml" else f
        if target != f and target.exists():
            sys.exit(f"error: {target} exists already; merge it into {f} by hand first")
        target.write_text(header + "\n".join(lines[i:]))
        if target != f:
            f.unlink()
            renamed[str(f)] = str(target)
        count += 1
removed = [str(f) for f in sorted(Path("stacks").glob(f"*/import-{site}-mirror.tf"))]
for f in removed:
    Path(f).unlink()

manifest_path = Path("data/.import-manifest.json")
if manifest_path.exists():
    manifest = json.loads(manifest_path.read_text())
    manifest["imported"] = [renamed.get(r, r) for r in manifest.get("imported", []) if r not in removed]
    (manifest.get("mirrors") or {}).pop(site, None)
    if not manifest.get("mirrors"):
        manifest.pop("mirrors", None)
    manifest.setdefault("sources", []).append({"site": site, "cutover": today})
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

inventory = Path("inventory/managers.yaml")
lines = inventory.read_text().split("\n")
start = next((i for i, l in enumerate(lines) if re.fullmatch(rf"\s*{re.escape(site)}:\s*", l)), None)
if start is None:
    sys.exit(f"error: {site} not found in {inventory}")
indent = len(lines[start]) - len(lines[start].lstrip())
done = False
for i in range(start + 1, len(lines)):
    line = lines[i]
    if line.strip() and len(line) - len(line.lstrip()) <= indent:
        break
    if re.fullmatch(r"\s+mode:\s*mirror\s*(#.*)?", line):
        lines[i] = re.sub(r"mirror", "managed", line, count=1)
        done = True
        break
if not done:
    sys.exit(f"error: no 'mode: mirror' line under {site} in {inventory}")
inventory.write_text("\n".join(lines))
print(f"{count} file(s) now ordinary data files; import blocks removed: {', '.join(removed) or 'none'}; "
      f"{site}: mode: managed")
PY

echo "== 3. plan $site: it must change nothing"
summary="$work/plans.txt"
: >"$summary"
stacks="$(python3 scripts/ci-matrix.py --format lines | awk -v s="$site" '$1 == s { print $2 }')"
[ -n "$stacks" ] || die "no stack is planned for $site"
for stack in $stacks; do
	echo "-- $stack"
	if ! out="$(NSX_CRED_SCOPE=plan scripts/with-credentials.sh "$site" -- scripts/tf.sh plan "$stack" "$site" 2>&1)"; then
		printf '%s\n' "$out" | tail -40
		die "the plan of $site/$stack failed (above): nothing was pushed"
	fi
	line="$(grep -E "^plan-guard $site/$stack" <<<"$out" | tail -1)"
	printf '%s\n' "$line"
	if ! grep -qE ": 0 import, 0 create, 0 update, 0 destroy/replace, 0 hand back" <<<"$line"; then
		grep -E "^  # |will be (created|updated|destroyed|imported)|must be replaced" <<<"$out" | head -40
		die "the plan of $site/$stack is not empty (above): the files and state do not describe NSX exactly yet. Run the mirror and sync-state again; nothing was pushed."
	fi
	echo "$stack: no changes" >>"$summary"
done

git add -A data stacks inventory
git -c user.name="${GITLAB_USER_NAME:-nsx-cutover}" -c user.email="${GITLAB_USER_EMAIL:-nsx-cutover@localhost}" \
	-c commit.gpgsign=false commit -q -m "Cut $site over to managed

The mirror copy of $site becomes the source of truth: ordinary data files,
no import blocks, mode: managed. Planned by scripts/cutover.sh in pipeline
${CI_PIPELINE_ID:-local}: no changes."

push_env=() auth=()
if [ -n "${NSX_ADOPT_REMOTE:-}" ]; then
	remote="$NSX_ADOPT_REMOTE"
else
	remote="${CI_SERVER_URL%/}/${CI_PROJECT_PATH}.git"
	auth=(-c "http.extraHeader=Authorization: Basic $(printf 'oauth2:%s' "$NSX_ADOPT_TOKEN" | base64 | tr -d '\n')")
	if [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then
		push_env=(GIT_SSL_CAINFO="$CI_SERVER_TLS_CA_FILE")
	fi
fi
env ${push_env[@]+"${push_env[@]}"} git ${auth[@]+"${auth[@]}"} push -q --force "$remote" "HEAD:refs/heads/$branch" ||
	die "could not push $branch"

token_header=()
[ -z "${NSX_ADOPT_TOKEN:-}" ] || token_header=(--header "PRIVATE-TOKEN: ${NSX_ADOPT_TOKEN}")
gitlab() { # gitlab METHOD PATH [JSON-FILE]
	local data=()
	[ -z "${3:-}" ] || data=(--header "Content-Type: application/json" --data "@$3")
	curl --silent --show-error --fail-with-body --max-time 60 -X "$1" \
		${CI_SERVER_TLS_CA_FILE:+--cacert "$CI_SERVER_TLS_CA_FILE"} \
		${token_header[@]+"${token_header[@]}"} ${data[@]+"${data[@]}"} "${api%/}/projects/${project}$2"
}
open_mr="$(gitlab GET "/merge_requests?state=opened&source_branch=$branch&target_branch=$target" |
	python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["iid"] if d else "")')" || open_mr=""
SITE="$site" BRANCH="$branch" TARGET="$target" NEW="$open_mr" python3 - "$work/mr.json" "$summary" <<'PY'
import json, os, sys
e = os.environ
plans = open(sys.argv[2]).read().split()
description = "\n".join([
    f"Cuts **{e['SITE']}** over from mirror mode to managed. Merging this is the cutover.",
    "",
    "- Its mirror files become ordinary data files: the \"do not edit\" header is gone, and",
    "  `imported-<site>-mirror.yaml` is now `imported-<site>.yaml`.",
    "- Its import blocks are deleted: Terraform's state already holds every object.",
    f"- `inventory/managers.yaml`: `mode: managed`. Its plans and applies run like every other manager's.",
    "",
    "Planned by the cutover job against the live manager, with this exact content: **no changes** in any stack.",
    "This merge request's own pipeline plans it again; it must say the same.",
    "",
    "### Before merging",
    "- [ ] The UI freeze for this manager is agreed and in place.",
    "- [ ] Every open `nsx-drift` issue for it is explained.",
    "",
    "### After merging",
    "- Change these objects by editing their files, and add new objects in new files, in merge requests.",
    "- A change made in the NSX UI is drift: the drift check raises an issue, and the next apply would undo it.",
    "- Placeholder `why_static` notes still say IMPORTED AS-IS: replace them as the groups are touched.",
])
body = {"title": f"Cut {e['SITE']} over to managed", "description": description}
if not e["NEW"]:
    body.update(source_branch=e["BRANCH"], target_branch=e["TARGET"], remove_source_branch=True)
json.dump(body, open(sys.argv[1], "w"))
PY
if [ -n "$open_mr" ]; then
	gitlab PUT "/merge_requests/$open_mr" "$work/mr.json" >/dev/null || die "$branch was pushed, but merge request !$open_mr could not be updated"
	echo "updated merge request !$open_mr"
else
	response="$(gitlab POST "/merge_requests" "$work/mr.json")" ||
		die "$branch was pushed, but the merge request could not be opened: $response"
	echo "merge request: $(python3 -c 'import json,sys; print(json.load(sys.stdin).get("web_url", ""))' <<<"$response")"
fi
SCAFFOLD_EOF
mark_executable scripts/cutover.sh

# ---------------------------------------------------------------------------
# 7. Backend config and CI
# ---------------------------------------------------------------------------

write_file envs/example.backend.hcl.example <<'SCAFFOLD_EOF'
# Partial backend configuration for one manager. Copy to envs/<site>.backend.hcl
# and fill in. The file name must match the manager key in
# inventory/managers.yaml — scripts/tf.sh finds it that way.
#
#   terraform init -backend-config=envs/<site>.backend.hcl
#
# Whatever backend is chosen must give three things: encryption at rest, state
# LOCKING, and access restricted to the pipeline identity. State carries the
# full security posture of the estate.
#
# NEVER PUT A SECRET IN THIS FILE. It is committed. Backend credentials come
# from the environment — see each example below.
#
# NEVER COMMIT THE STATE ITSELF. Not to this repository, not to another one.
# State holds every rule, group and credential-shaped value in plaintext; git
# history is permanent and cannot be pruned once pushed, and git gives you no
# locking, so two concurrent runs silently diverge. .gitignore blocks *.tfstate
# for this reason.
#
# Pick the backend with: scripts/bootstrap.sh --force --backend TYPE

# --- example: http — GitLab-managed Terraform state ------------------------
# Locking, encryption at rest and version history come from GitLab, with no
# object store to run. One state per stack per manager, so the state NAME at the
# end of the address must be unique per pair.
#
# address        = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security"
# lock_address   = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security/lock"
# unlock_address = "https://gitlab.example.com/api/v4/projects/1234/terraform/state/lon1-local-security/lock"
# lock_method    = "POST"
# unlock_method  = "DELETE"
# retry_wait_min = 5
#
# Credentials from the environment, never here:
#   in GitLab CI scripts/tf.sh sets TF_HTTP_USERNAME=gitlab-ci-token and
#   TF_HTTP_PASSWORD=$CI_JOB_TOKEN itself; set them only to override that
# Outside CI, a project access token with the api scope in place of the job token.

# --- example: s3 (also MinIO or Ceph RGW, with endpoint set) ---------------
# bucket         = "nsx-terraform-state"
# key            = "example/global-security.tfstate"
# region         = "eu-west-2"
# dynamodb_table = "nsx-terraform-locks"
# kms_key_id     = "alias/nsx-terraform"
# encrypt        = true

# --- example: azurerm ------------------------------------------------------
# resource_group_name  = "rg-terraform-state"
# storage_account_name = "sttfstatensx"
# container_name       = "state"
# key                  = "example/global-security.tfstate"

# --- local backend ---------------------------------------------------------
# Holds nothing: scripts/tf.sh supplies the state path itself, so two stacks at
# the same site cannot collide on one file. Filesystem state has NO LOCKING —
# acceptable for a lab, not for a managed estate.
SCAFFOLD_EOF

write_file deploy/gitlab/docker-compose.yml <<'SCAFFOLD_EOF'
# A self-contained GitLab for running this repository's review pipeline, for
# teams that do not already have one. Brought up by scripts/gitlab-up.sh.
#
# NOT a production GitLab. TLS only through scripts/gitlab-https.sh, no backups, no HA, and the runner is
# privileged so it can run Docker-in-Docker. Fine for a lab or a pilot; put a
# real one in front of a production estate.
#
# Data lives in named volumes, so 'docker compose down' keeps everything and
# 'docker compose down -v' destroys it.

services:
  gitlab:
    image: gitlab/gitlab-ce:17.5.2-ce.0
    container_name: nsx-gitlab
    restart: unless-stopped
    hostname: "${GITLAB_HOST:-localhost}"
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url '${GITLAB_SCHEME:-http}://${GITLAB_HOST:-localhost}:${GITLAB_PORT:-8929}'
        # Only used when the scheme is https; set up by scripts/gitlab-https.sh.
        nginx['ssl_certificate'] = "/etc/gitlab/ssl/server.crt"
        nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/server.key"
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT:-2224}
        # A lab instance does not need mail, metrics or the container registry.
        # (No grafana[...] line: bundled Grafana was removed in GitLab 16.3 and
        # any grafana setting now stops 'gitlab-ctl reconfigure' with
        # "Reading unsupported config value grafana".)
        registry['enable'] = false
        prometheus_monitoring['enable'] = false
        gitlab_rails['gitlab_email_enabled'] = false
        puma['worker_processes'] = 2
        sidekiq['max_concurrency'] = 9
    ports:
      - "${GITLAB_PORT:-8929}:${GITLAB_PORT:-8929}"
      - "${GITLAB_SSH_PORT:-2224}:22"
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
      - ${GITLAB_SSL_DIR:-./ssl}:/etc/gitlab/ssl:ro
    shm_size: 256m
    healthcheck:
      test: ["CMD", "/opt/gitlab/bin/gitlab-healthcheck", "--fail", "--max-time", "10"]
      interval: 30s
      timeout: 15s
      retries: 30
      start_period: 10m

  runner:
    image: gitlab/gitlab-runner:v17.5.3
    container_name: nsx-gitlab-runner
    restart: unless-stopped
    # Host network: the runner then reaches GitLab at the same address you do,
    # including 127.0.0.1 / localhost. On the default bridge network 127.0.0.1
    # is the runner's own container and registration fails.
    network_mode: host
    depends_on:
      - gitlab
    volumes:
      - gitlab-runner-config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  gitlab-config:
  gitlab-logs:
  gitlab-data:
  gitlab-runner-config:
SCAFFOLD_EOF

write_file deploy/gitlab/README.md <<'SCAFFOLD_EOF'
# A local GitLab, for teams that do not have one

`scripts/gitlab-up.sh` brings up GitLab CE and a runner in Docker, waits for it,
prints the initial root password, creates a project for this repository, pushes
to it, and registers the runner so the review pipeline works end to end.

```bash
scripts/gitlab-up.sh              # start, create the project, push
scripts/gitlab-up.sh --status     # where it is and whether it is healthy
scripts/gitlab-up.sh --password   # print the initial root password again
scripts/gitlab-up.sh --down       # stop, keep all data
scripts/gitlab-up.sh --destroy    # stop and delete the volumes
```

First boot takes several minutes — GitLab migrates its database before it
answers. The script waits and tells you what it is waiting for.

## What you get

- GitLab at `http://localhost:8929`, user `root`, password printed by the script
  and readable again with `--password`.
- A project containing this repository, with `.gitlab-ci.yml` already in it.
- A registered runner using the Docker executor.

## HTTPS on 8443, renewed automatically

```bash
scripts/gitlab-https.sh           # certificate, HTTPS on 8443, runner, daily renewal
scripts/gitlab-https.sh --status  # URL, certificate expiry, renewal job
scripts/gitlab-https.sh --renew   # what the daily job runs
```

It makes a small internal CA with openssl, issues a 90-day server certificate,
reissues it when 30 days remain and reloads nginx. Import `ca.crt` (default
`/opt/nsx-gitlab/ssl/ca.crt`) into browsers and other clients. A private IP
cannot get a public certificate; if GitLab has a public DNS name, use certbot.

## The CI image, and restricted networks

Pipeline jobs run in `nsx-ci:1` (Python, Terraform, bash, curl, git), built on this
host by `scripts/converge.sh` from two Docker Hub images, so jobs never download
packages. `scripts/converge.sh` (run for you by `update.sh`) also registers the
runner and configures it for this host: proxy settings found on the host, the
host's CA bundle, and a pull policy that uses the local image.

The NSX provider is in the image too, at the exact version pinned in
`deploy/ci-image/providers.tf`, so plans and applies download nothing. The
image build fetches it once, through the same proxy settings jobs get, and
`terraform providers mirror` checks its signature as it does. If that fetch
fails, converge warns, the image is built without it, jobs download it as
before, and the next converge tries again. To change the version, edit
`providers.tf` and run `scripts/converge.sh`. An internal mirror set as the
CI/CD variable `NSX_TF_NETWORK_MIRROR` is used instead of the image's copy.
`scripts/converge.sh --check` reports without changing anything.

## What it is not

Not a production GitLab. No backups, no HA, and the initial root
password lives in a file inside the container for 24 hours. Change it at first
login. For a production estate use a real GitLab and point
`scripts/enable-gitops.sh` at it instead.

## Before the pipeline can plan against a manager

Set these in the project, under Settings → CI/CD → Variables:

| Variable | Value | Flags |
|---|---|---|
| `VAULT_ADDR` | your Vault endpoint | masked |
| `VAULT_PLAN_TOKEN` | a **read-only** token | masked |
| `VAULT_APPLY_TOKEN` | a write token | masked, **protected** |
| `CI_API_TOKEN` | project token, `api` scope — lets the pipeline post plans to the MR | masked |

`VAULT_APPLY_TOKEN` must be protected, so it is only available on protected
branches. That is what stops a feature branch from applying anything.
SCAFFOLD_EOF

write_file scripts/gitlab-setup.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Make a GitLab project ready to run this repository's review pipeline.
#
#   scripts/gitlab-setup.sh --url https://gitlab.example.com \
#                           --token glpat-xxxx \
#                           --project netops/nsx-terraform
#
# Works against any GitLab — your own, or the one scripts/gitlab-up.sh starts in
# Docker, which calls this script rather than duplicating it.
#
# What it does, each step skipped if already done:
#   1. create the project (and the group, if it does not exist)
#   2. push this repository to it
#   3. set the CI/CD variables the pipeline needs
#   4. protect the default branch so nobody can push straight to it
#   5. create one environment per manager/stack for the apply jobs
#
# The token needs the 'api' scope and Maintainer or Owner on the group. It is
# read from --token or GITLAB_TOKEN, used in memory, and never written to disk
# or into .git/config.
#
# Credentials for the pipeline are passed as environment variables, so they do
# not appear in your shell history:
#
#   VAULT_ADDR=... VAULT_PLAN_TOKEN=... VAULT_APPLY_TOKEN=... \
#     scripts/gitlab-setup.sh --url ... --token ... --project ...

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="${GITLAB_URL:-}"
TOKEN="${GITLAB_TOKEN:-}"
PROJECT="${GITLAB_PROJECT:-}"
BRANCH="${GIT_BRANCH:-main}"
DRY=0

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--url) URL="${2:?--url needs a GitLab base URL}"; shift 2 ;;
	--url=*) URL="${1#*=}"; shift ;;
	--token) TOKEN="${2:?--token needs a personal or group access token}"; shift 2 ;;
	--token=*) TOKEN="${1#*=}"; shift ;;
	--project) PROJECT="${2:?--project needs group/name}"; shift 2 ;;
	--project=*) PROJECT="${1#*=}"; shift ;;
	--branch) BRANCH="${2:?--branch needs a name}"; shift 2 ;;
	--branch=*) BRANCH="${1#*=}"; shift ;;
	--dry-run) DRY=1; shift ;;
	-h | --help) sed -n '2,30p' "$0"; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

[ -n "$URL" ] || die "--url is required (for example https://gitlab.example.com)"
[ -n "$TOKEN" ] || die "--token is required, or set GITLAB_TOKEN. It needs the 'api' scope."
[ -n "$PROJECT" ] || die "--project is required, as group/name"

URL="${URL%/}"
API="$URL/api/v4"
GROUP="${PROJECT%/*}"
NAME="${PROJECT##*/}"
[ "$GROUP" = "$PROJECT" ] && GROUP=""

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (for URL encoding and JSON)"

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
jget() { python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1:]:
    if isinstance(d,dict): d=d.get(k)
    else: d=None
print("" if d is None else d)' "$@"; }

api() {
	local method="$1" path="$2"; shift 2
	curl -sS --max-time 60 --header "PRIVATE-TOKEN: $TOKEN" \
		--request "$method" "$API$path" "$@"
}

run() {
	if [ "$DRY" = 1 ]; then say "  would: $*"; return 0; fi
	"$@"
}

# --- 0. can we talk to it -------------------------------------------------
step "checking $URL"
me="$(api GET /user | jget username)"
[ -n "$me" ] || die "cannot authenticate to $API.
       Check the URL is reachable and the token has the 'api' scope."
say "  authenticated as '$me'"

version="$(api GET /version | jget version)"
say "  GitLab ${version:-(version not reported)}"

# --- 1. project -----------------------------------------------------------
step "project $PROJECT"
enc="$(urlenc "$PROJECT")"
pid="$(api GET "/projects/$enc" | jget id)"

if [ -n "$pid" ]; then
	say "  already exists (id $pid)"
else
	namespace_id=""
	if [ -n "$GROUP" ]; then
		namespace_id="$(api GET "/namespaces/$(urlenc "$GROUP")" | jget id)"
		if [ -z "$namespace_id" ]; then
			say "  group '$GROUP' does not exist; creating it"
			namespace_id="$(run api POST /groups \
				--data-urlencode "name=$GROUP" \
				--data-urlencode "path=$GROUP" \
				--data "visibility=private" | jget id)"
			[ "$DRY" = 1 ] || [ -n "$namespace_id" ] ||
				die "could not create group '$GROUP'. Create it by hand, or use a token with rights to."
		fi
	fi
	say "  creating project"
	if [ "$DRY" = 1 ]; then
		say "  would: POST /projects name=$NAME"
	else
		pid="$(api POST /projects \
			--data-urlencode "name=$NAME" \
			--data-urlencode "path=$NAME" \
			${namespace_id:+--data "namespace_id=$namespace_id"} \
			--data "visibility=private" \
			--data "initialize_with_readme=false" | jget id)"
		[ -n "$pid" ] || die "could not create the project. Does '$PROJECT' already exist somewhere you cannot see?"
		say "  created (id $pid)"
	fi
fi

# --- 2. push --------------------------------------------------------------
step "pushing this repository"
if [ "$DRY" = 1 ]; then
	say "  would: git push to $URL/$PROJECT.git"
else
	git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || git -C "$REPO_ROOT" init -q -b "$BRANCH"
	if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
		git -C "$REPO_ROOT" add -A
		git -C "$REPO_ROOT" -c user.name="${GIT_AUTHOR_NAME:-nsx-terraform}" \
			-c user.email="${GIT_AUTHOR_EMAIL:-nsx-terraform@localhost}" \
			commit -q -m "Initial NSX Terraform scaffold"
		say "  committed the tree"
	fi
	# Token in the URL for this push only; never stored.
	host="${URL#https://}"; host="${host#http://}"
	scheme="https"; case "$URL" in http://*) scheme="http" ;; esac
	if git -C "$REPO_ROOT" push -q "$scheme://oauth2:${TOKEN}@${host}/${PROJECT}.git" \
		"HEAD:refs/heads/$BRANCH" 2>/dev/null; then
		say "  pushed to $BRANCH"
	else
		say "  note: push failed or was already up to date. Push by hand if needed:"
		say "        git push -u origin $BRANCH"
	fi
	if ! git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
		git -C "$REPO_ROOT" remote add origin "$URL/$PROJECT.git"
		say "  remote 'origin' set to $URL/$PROJECT.git (no token in it)"
	fi
fi

# --- 3. CI/CD variables ---------------------------------------------------
step "CI/CD variables"
set_var() {
	local key="$1" value="$2" protected="$3" masked="$4"
	[ -n "$value" ] || { say "  skip $key (not supplied)"; return 0; }
	if [ "$DRY" = 1 ]; then say "  would set $key (protected=$protected)"; return 0; fi
	local existing
	existing="$(api GET "/projects/$pid/variables/$key" | jget key)"
	if [ -n "$existing" ]; then
		api PUT "/projects/$pid/variables/$key" \
			--data-urlencode "value=$value" \
			--data "protected=$protected" --data "masked=$masked" >/dev/null &&
			say "  updated $key"
	else
		api POST "/projects/$pid/variables" \
			--data-urlencode "key=$key" \
			--data-urlencode "value=$value" \
			--data "protected=$protected" --data "masked=$masked" >/dev/null &&
			say "  set $key (protected=$protected, masked=$masked)"
	fi
}

set_var VAULT_ADDR "${VAULT_ADDR:-}" false false
set_var VAULT_PLAN_TOKEN "${VAULT_PLAN_TOKEN:-}" false true
# Protected, so a feature branch can never reach the write credential.
set_var VAULT_APPLY_TOKEN "${VAULT_APPLY_TOKEN:-}" true true
set_var CI_API_TOKEN "${CI_API_TOKEN:-$TOKEN}" false true

if [ -z "${VAULT_ADDR:-}${VAULT_PLAN_TOKEN:-}${VAULT_APPLY_TOKEN:-}" ]; then
	say ""
	say "  none of the Vault variables were supplied, so the plan jobs cannot reach"
	say "  a manager yet. Set them here, or re-run with them in the environment:"
	say "    $URL/$PROJECT/-/settings/ci_cd"
fi

# --- 4. protect the default branch ---------------------------------------
step "protecting '$BRANCH'"
if [ "$DRY" = 1 ]; then
	say "  would protect $BRANCH (no direct push, maintainers may merge)"
else
	existing="$(api GET "/projects/$pid/protected_branches/$(urlenc "$BRANCH")" | jget name)"
	if [ -n "$existing" ]; then
		say "  already protected"
	else
		# push_access_level 0 = nobody may push directly; merge 40 = maintainer.
		api POST "/projects/$pid/protected_branches" \
			--data-urlencode "name=$BRANCH" \
			--data "push_access_level=0" \
			--data "merge_access_level=40" >/dev/null &&
			say "  protected: no direct pushes, maintainers may merge" ||
			say "  note: could not protect the branch; do it in Settings -> Repository"
	fi
fi

# --- 5. environments for the apply jobs ----------------------------------
step "environments"
if [ -f "$REPO_ROOT/inventory/managers.yaml" ] && [ "$DRY" != 1 ]; then
	rows="$(cd "$REPO_ROOT" && python3 -c "
import sys
sys.path.insert(0,'scripts')
try:
    from ci_matrix_lib import entries
except Exception:
    sys.exit(0)
for r in entries():
    print(f\"nsx/{r['site']}/{r['stack']}\")
" 2>/dev/null)"
	n=0
	for env in $rows; do
		api POST "/projects/$pid/environments" --data-urlencode "name=$env" >/dev/null 2>&1
		n=$((n + 1))
	done
	say "  created or confirmed $n environment(s) from the inventory"
else
	say "  skipped (no inventory, or dry run)"
fi

cat <<SUMMARY

===================================================================
 $PROJECT is set up
===================================================================

  Project    $URL/$PROJECT
  Pipelines  $URL/$PROJECT/-/pipelines
  Variables  $URL/$PROJECT/-/settings/ci_cd

Still yours to do, because they cannot be set safely from a script:

  * Require an approval on merge requests:
      Settings -> Merge requests -> Approvals -> at least 1
  * If this is GitLab Premium or above, mark the nsx/* environments as
      PROTECTED and choose who may deploy:
      Settings -> CI/CD -> Protected environments
    On Free, the gate is the manual apply job plus the protected branch and
    the protected VAULT_APPLY_TOKEN, which is weaker: anyone who can run a
    pipeline on the default branch can start the apply.
  * Register a runner if this project has none:
      Settings -> CI/CD -> Runners

Then open a merge request with a small rule change and confirm the plan appears
on it before trusting the pipeline with anything real.

SUMMARY
SCAFFOLD_EOF
mark_executable scripts/gitlab-setup.sh

write_file scripts/gitlab-up.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Stand up a local GitLab in Docker and put this repository in it.
#
#   scripts/gitlab-up.sh              start, create the project, push
#   scripts/gitlab-up.sh --status     report where it is and whether it is up
#   scripts/gitlab-up.sh --password   print the initial root password
#   scripts/gitlab-up.sh --down       stop, keep the data
#   scripts/gitlab-up.sh --destroy    stop and delete the data
#
# For teams with no GitLab of their own. Everything it needs is in
# deploy/gitlab/docker-compose.yml. Not a production deployment — see
# deploy/gitlab/README.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/deploy/gitlab"
GITLAB_HOST="${GITLAB_HOST:-localhost}"
GITLAB_PORT="${GITLAB_PORT:-8929}"
GITLAB_URL="http://${GITLAB_HOST}:${GITLAB_PORT}"
PROJECT_NAME="${GITLAB_PROJECT:-nsx-terraform}"
WAIT_MINUTES="${GITLAB_WAIT_MINUTES:-15}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

compose() {
	if docker compose version >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && GITLAB_HOST="$GITLAB_HOST" GITLAB_PORT="$GITLAB_PORT" docker compose "$@")
	elif command -v docker-compose >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && GITLAB_HOST="$GITLAB_HOST" GITLAB_PORT="$GITLAB_PORT" docker-compose "$@")
	else
		die "neither 'docker compose' nor 'docker-compose' is available."
	fi
}

preflight() {
	command -v docker >/dev/null 2>&1 || die "docker is not installed. See https://docs.docker.com/engine/install/"
	docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and is your user in the docker group?"
	[ -f "$COMPOSE_DIR/docker-compose.yml" ] || die "$COMPOSE_DIR/docker-compose.yml is missing. Re-run scripts/bootstrap.sh."

	# GitLab is not small. Warn rather than refuse: the numbers below are what
	# it needs to be usable, not what it needs to boot.
	local mem_kb
	mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 4000000 ]; then
		say "warning: GitLab wants ~4 GB of RAM and this host has $((mem_kb / 1024)) MB. Expect it to be slow or to be killed."
	fi
}

root_password() {
	# Omnibus writes the initial password here and deletes it after 24 hours.
	docker exec nsx-gitlab cat /etc/gitlab/initial_root_password 2>/dev/null |
		sed -n 's/^Password: //p' | head -1
}

wait_for_gitlab() {
	local deadline=$((SECONDS + WAIT_MINUTES * 60)) last=""
	say "waiting for GitLab to answer at $GITLAB_URL (first boot runs database migrations; up to $WAIT_MINUTES minutes)"
	while [ "$SECONDS" -lt "$deadline" ]; do
		local health
		health="$(docker inspect --format '{{.State.Health.Status}}' nsx-gitlab 2>/dev/null || echo unknown)"
		if [ "$health" != "$last" ]; then
			say "  container health: $health"
			last="$health"
		fi
		if curl -sf -o /dev/null --max-time 10 "$GITLAB_URL/-/readiness?all=1" 2>/dev/null ||
			curl -sf -o /dev/null --max-time 10 "$GITLAB_URL/users/sign_in" 2>/dev/null; then
			say "GitLab is up."
			return 0
		fi
		sleep 15
	done
	die "GitLab did not become ready within $WAIT_MINUTES minutes.
       Look at:  cd deploy/gitlab && docker compose logs --tail=100 gitlab
       Then re-run this script; it picks up where it left off."
}

api() {
	local method="$1" path="$2"
	shift 2
	curl -sS --fail-with-body --max-time 60 \
		--header "PRIVATE-TOKEN: $ROOT_TOKEN" \
		--request "$method" "$GITLAB_URL/api/v4$path" "$@"
}

make_root_token() {
	# A token minted through the Rails console, because there is no API to
	# create the first token without one.
	say "minting an API token for root..."
	ROOT_TOKEN="$(
		docker exec nsx-gitlab gitlab-rails runner "
          u = User.find_by_username('root')
          t = u.personal_access_tokens.create!(
                scopes: ['api','write_repository'],
                name: 'nsx-bootstrap',
                expires_at: 90.days.from_now)
          t.set_token('${TOKEN_SEED}')
          t.save!
          puts '${TOKEN_SEED}'
        " 2>/dev/null | tr -d '\r' | tail -1
	)"
	[ -n "$ROOT_TOKEN" ] || die "could not create an API token. Is GitLab fully started? Try: scripts/gitlab-up.sh --status"
}

create_project() {
	local existing
	existing="$(api GET "/projects/root%2F$PROJECT_NAME" 2>/dev/null || true)"
	if printf '%s' "$existing" | grep -q '"id"'; then
		say "project root/$PROJECT_NAME already exists; leaving it alone."
		return 0
	fi
	say "creating project root/$PROJECT_NAME..."
	api POST "/projects" \
		--data-urlencode "name=$PROJECT_NAME" \
		--data-urlencode "path=$PROJECT_NAME" \
		--data "visibility=private" \
		--data "initialize_with_readme=false" >/dev/null
}

push_repository() {
	local remote="http://root:${ROOT_TOKEN}@${GITLAB_HOST}:${GITLAB_PORT}/root/${PROJECT_NAME}.git"
	git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
		say "initialising a git repository in $REPO_ROOT"
		git -C "$REPO_ROOT" init -q
	}
	if [ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 2>/dev/null)" ] &&
		git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
		: # already committed
	else
		git -C "$REPO_ROOT" add -A
		git -C "$REPO_ROOT" -c user.name="${GIT_AUTHOR_NAME:-nsx-terraform}" \
			-c user.email="${GIT_AUTHOR_EMAIL:-nsx-terraform@localhost}" \
			commit -q -m "Initial NSX Terraform scaffold" || true
	fi

	# The URL carries a token, so it is set transiently and never stored.
	say "pushing to root/$PROJECT_NAME..."
	git -C "$REPO_ROOT" push -q "$remote" "HEAD:refs/heads/main" ||
		die "push failed. Check that GitLab is reachable at $GITLAB_URL"

	git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 ||
		git -C "$REPO_ROOT" remote add origin "http://${GITLAB_HOST}:${GITLAB_PORT}/root/${PROJECT_NAME}.git"
	say "remote 'origin' points at http://${GITLAB_HOST}:${GITLAB_PORT}/root/${PROJECT_NAME}.git"
	say "(the push used a token in the URL; it was not written to .git/config)"
}

register_runner() {
	# One implementation, shared with converge.sh: registers the runner and
	# configures it for this host's network (proxy, CA, pull policy).
	if [ -x "$REPO_ROOT/scripts/gitlab-runner.sh" ]; then
		GITLAB_HOST="$GITLAB_HOST" GITLAB_PORT="$GITLAB_PORT" GITLAB_SCHEME=http \
			"$REPO_ROOT/scripts/gitlab-runner.sh" --project "root/$PROJECT_NAME" ||
			say "note: runner registration failed; run scripts/converge.sh, or register one from the project's CI/CD settings."
	else
		say "note: scripts/gitlab-runner.sh is missing; register a runner from the project's CI/CD settings."
	fi
	# The image the pipeline's jobs run in, built here from Docker Hub images.
	if [ -x "$REPO_ROOT/scripts/ci-image.sh" ]; then
		"$REPO_ROOT/scripts/ci-image.sh" || say "note: the CI image could not be built; run scripts/converge.sh for details."
	fi
}

summary() {
	local pw
	pw="$(root_password || true)"
	cat <<SUMMARY

===================================================================
 GitLab is ready
===================================================================

  URL       $GITLAB_URL
  Project   $GITLAB_URL/root/$PROJECT_NAME
  Username  root
  Password  ${pw:-(expired — Omnibus deletes it 24h after first boot;
            reset with: docker exec -it nsx-gitlab gitlab-rake "gitlab:password:reset[root]")}

Change that password at first login.

Next, so the pipeline can reach your NSX managers — Settings -> CI/CD ->
Variables in the project. Either Vault:

  VAULT_ADDR          your Vault endpoint            masked
  VAULT_PLAN_TOKEN    a READ-ONLY token              masked
  VAULT_APPLY_TOKEN   a write token                  masked, PROTECTED

or the credentials themselves, held in GitLab:

  NSX_PLAN_USERNAME / NSX_PLAN_PASSWORD     a READ-ONLY NSX account   masked
  NSX_APPLY_USERNAME / NSX_APPLY_PASSWORD   a write NSX account       masked, PROTECTED
  NSX_CA_FILE_<SITE>  CA of that manager, if internal or self-signed  type File
                      (NSX_CA_FILE: the same for every other manager)

and, for plan comments on merge requests:

  CI_API_TOKEN        project token, 'api' scope     masked

Then protect the default branch (Settings -> Repository -> Protected branches)
so only the pipeline can apply. docs/GITOPS.md explains the whole flow.

SUMMARY
}

main() {
	case "${1:-}" in
	--status)
		preflight
		compose ps
		say ""
		say "URL: $GITLAB_URL"
		curl -sf -o /dev/null --max-time 10 "$GITLAB_URL/users/sign_in" &&
			say "state: answering" || say "state: not answering yet"
		exit 0
		;;
	--password)
		root_password || die "no initial password file; it expires 24h after first boot.
       Reset with: docker exec -it nsx-gitlab gitlab-rake \"gitlab:password:reset[root]\""
		exit 0
		;;
	--down)
		preflight
		compose down
		say "stopped. Data kept — 'scripts/gitlab-up.sh' brings it back."
		exit 0
		;;
	--destroy)
		preflight
		printf 'This deletes the GitLab volumes and everything in them.\nType "destroy gitlab" to continue: ' >&2
		local reply=""
		IFS= read -r reply </dev/tty || reply=""
		[ "$reply" = "destroy gitlab" ] || die "not confirmed; nothing was removed."
		compose down -v
		say "removed."
		exit 0
		;;
	"") ;;
	*) die "unknown option: ${1}. Try --status, --password, --down or --destroy." ;;
	esac

	preflight
	say "starting GitLab and a runner (deploy/gitlab/docker-compose.yml)..."
	compose up -d
	wait_for_gitlab

	TOKEN_SEED="nsxbootstrap$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	make_root_token

	# One implementation of "make a GitLab project ready", shared with the path
	# for a GitLab somebody already has. This script's job is the container.
	if [ -x "$REPO_ROOT/scripts/gitlab-setup.sh" ]; then
		GITLAB_TOKEN="$ROOT_TOKEN" "$REPO_ROOT/scripts/gitlab-setup.sh" \
			--url "$GITLAB_URL" \
			--token "$ROOT_TOKEN" \
			--project "root/$PROJECT_NAME" ||
			say "note: project setup reported a problem; see above."
	else
		create_project
		push_repository
	fi

	register_runner
	summary
}

main "$@"
SCAFFOLD_EOF
mark_executable scripts/gitlab-up.sh

write_file scripts/gitlab-https.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Serve the local GitLab over HTTPS and keep its certificate renewed.
#
#   scripts/gitlab-https.sh            set up, or re-apply: certificate, HTTPS on
#                                      8443, runner trust, daily renewal job
#   scripts/gitlab-https.sh --renew    reissue the certificate if it expires
#                                      within 30 days (what the daily job runs)
#   scripts/gitlab-https.sh --status   URL, certificate expiry, renewal job
#
# For the GitLab started by scripts/gitlab-up.sh. A private address cannot get a
# public certificate, so this keeps a small internal CA with openssl and issues
# 90-day server certificates from it. Clients import ca.crt once.
#
# Settings (environment, or deploy/gitlab/.env from a previous run):
#   GITLAB_HOST      name or IP clients use      (default: this host's first IP)
#   GITLAB_PORT      HTTPS port                  (default: 8443)
#   GITLAB_SSL_DIR   CA and certificate keys     (default: /opt/nsx-gitlab/ssl)
#
# Keys stay out of the repository: GITLAB_SSL_DIR is outside it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/deploy/gitlab"
ENV_FILE="$COMPOSE_DIR/.env"
RENEW_DAYS=30
VALID_DAYS=90

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

# Environment wins, then the file a previous run wrote, then a default.
saved() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 || true; }
GITLAB_HOST="${GITLAB_HOST:-$(saved GITLAB_HOST)}"
GITLAB_HOST="${GITLAB_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
GITLAB_PORT="${GITLAB_PORT:-$(saved GITLAB_PORT)}"
GITLAB_PORT="${GITLAB_PORT:-8443}"
GITLAB_SSL_DIR="${GITLAB_SSL_DIR:-$(saved GITLAB_SSL_DIR)}"
GITLAB_SSL_DIR="${GITLAB_SSL_DIR:-/opt/nsx-gitlab/ssl}"
[ -n "$GITLAB_HOST" ] || die "cannot work out this host's address. Set GITLAB_HOST."
URL="https://${GITLAB_HOST}:${GITLAB_PORT}"
CRON_FILE="${NSX_CRON_FILE:-/etc/cron.d/nsx-gitlab-cert}"

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required."; }

# One certificate operation at a time: the daily renewal and a manual run must
# not both rewrite server.key while nginx reads it.
lock_ssl() {
	mkdir -p "$GITLAB_SSL_DIR" 2>/dev/null
	# Docker creates a missing bind-mount directory as root, so a directory that
	# GitLab's first start made is not writable by an ordinary user.
	[ -w "$GITLAB_SSL_DIR" ] ||
		die "$GITLAB_SSL_DIR is not writable by $(id -un) (owner: $(stat -c %U "$GITLAB_SSL_DIR" 2>/dev/null || echo unknown)).
       Run as root, or: sudo chown -R $(id -un) $GITLAB_SSL_DIR"
	command -v flock >/dev/null 2>&1 || return 0
	exec 8>"$GITLAB_SSL_DIR/.lock" || return 0
	flock -w "${NSX_LOCK_WAIT:-120}" 8 || die "another certificate operation is running (lock: $GITLAB_SSL_DIR/.lock)."
}

compose() {
	if docker compose version >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && docker compose "$@")
	elif command -v docker-compose >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && docker-compose "$@")
	else
		die "neither 'docker compose' nor 'docker-compose' is available."
	fi
}

# Returns 0 if a valid certificate for this host exists with time to spare.
cert_ok() {
	[ -f "$GITLAB_SSL_DIR/server.crt" ] && [ -f "$GITLAB_SSL_DIR/server.key" ] || return 1
	openssl x509 -in "$GITLAB_SSL_DIR/server.crt" -noout -checkend $((RENEW_DAYS * 86400)) >/dev/null || return 1
	openssl x509 -in "$GITLAB_SSL_DIR/server.crt" -noout -text | grep -q -- "$GITLAB_HOST" || return 1
}

issue_cert() {
	local san
	umask 077
	mkdir -p "$GITLAB_SSL_DIR"
	cd "$GITLAB_SSL_DIR"
	if [[ "$GITLAB_HOST" =~ ^[0-9.]+$ ]]; then san="IP:$GITLAB_HOST"; else san="DNS:$GITLAB_HOST"; fi

	if [ ! -f ca.key ]; then
		say "creating the internal CA (10 years)..."
		openssl genrsa -out ca.key 4096 2>/dev/null
		openssl req -x509 -new -key ca.key -sha256 -days 3650 \
			-subj "/CN=NSX Estate Internal CA" -out ca.crt
	fi

	say "issuing a ${VALID_DAYS}-day certificate for $GITLAB_HOST..."
	# Build the pair under temporary names and move both into place, so nginx
	# (which may reload at any moment) never reads a new key beside an old cert.
	openssl genrsa -out server.key.new 2048 2>/dev/null
	openssl req -new -key server.key.new -subj "/CN=$GITLAB_HOST" -out server.csr
	printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$san" >ext.cnf
	openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
		-sha256 -days "$VALID_DAYS" -extfile ext.cnf -out server.crt.new 2>/dev/null
	rm -f server.csr ext.cnf
	chmod 600 server.key.new ca.key
	chmod 644 server.crt.new ca.crt
	mv -f server.key.new server.key
	mv -f server.crt.new server.crt
}

reload_nginx() {
	docker exec nsx-gitlab gitlab-ctl hup nginx >/dev/null 2>&1 &&
		say "nginx reloaded with the new certificate." || true
}

write_env() {
	cat >"$ENV_FILE" <<ENVFILE
# Written by scripts/gitlab-https.sh. Docker compose reads this automatically.
GITLAB_HOST=$GITLAB_HOST
GITLAB_PORT=$GITLAB_PORT
GITLAB_SCHEME=https
GITLAB_SSL_DIR=$GITLAB_SSL_DIR
ENVFILE
}

wait_for_https() {
	local deadline=$((SECONDS + 600))
	say "waiting for $URL (GitLab reconfigures itself; a few minutes)..."
	while [ "$SECONDS" -lt "$deadline" ]; do
		if curl -sf -o /dev/null --max-time 10 --cacert "$GITLAB_SSL_DIR/ca.crt" "$URL/users/sign_in"; then
			say "GitLab answers over HTTPS."
			return 0
		fi
		sleep 10
	done
	say "--- last lines from the container:"
	docker logs --tail=30 nsx-gitlab 2>&1 | sed 's/^/    /' || true
	die "no HTTPS answer within 10 minutes.
       To go back to plain HTTP:  rm $ENV_FILE && (cd $COMPOSE_DIR && docker compose up -d)"
}

trust_runner() {
	docker inspect nsx-gitlab-runner >/dev/null 2>&1 || {
		say "no runner container found; skipping runner trust."
		return 0
	}
	local certs=/etc/gitlab-runner/certs before after
	# Restarting the runner kills the job it is running, so only do it when its
	# trust or URL actually changed: this script is safe to run any time.
	state() { docker exec nsx-gitlab-runner sh -c "cat /etc/gitlab-runner/config.toml '$certs/${GITLAB_HOST}.crt' 2>/dev/null | sha256sum" 2>/dev/null; }
	before="$(state)"
	docker exec nsx-gitlab-runner mkdir -p "$certs"
	# GitLab CA plus the host trust store. Git in a job trusts only this file.
	"$REPO_ROOT/scripts/gitlab-runner.sh" --install-ca || die "could not install the CA bundle into the runner."
	docker exec nsx-gitlab-runner sh -c "
		f=/etc/gitlab-runner/config.toml
		[ -f \$f ] || exit 0
		sed -i 's|^\\([[:space:]]*url = \\)\".*\"|\\1\"${URL}/\"|' \$f
		grep -q tls-ca-file \$f || sed -i '/^[[:space:]]*url = /a\\  tls-ca-file = \"${certs}/${GITLAB_HOST}.crt\"' \$f
	"
	after="$(state)"
	if [ "$before" != "$after" ]; then
		docker restart nsx-gitlab-runner >/dev/null
		say "runner now trusts the CA and points at $URL."
	else
		say "runner already trusts the CA and points at $URL."
	fi
}

install_cron() {
	local line="17 3 * * * root GITLAB_HOST=$GITLAB_HOST GITLAB_PORT=$GITLAB_PORT GITLAB_SSL_DIR=$GITLAB_SSL_DIR $REPO_ROOT/scripts/gitlab-https.sh --renew >> /var/log/nsx-gitlab-cert.log 2>&1"
	if [ "$(id -u)" -eq 0 ] && [ -d "$(dirname "$CRON_FILE")" ]; then
		printf '%s\n' "$line" >"$CRON_FILE"
		chmod 644 "$CRON_FILE"
		say "daily renewal installed: $CRON_FILE"
	else
		say "not root: add this line to a crontab to renew automatically:"
		say "  $line"
	fi
}

port_clash() {
	# Our own container already publishing the port is fine.
	docker port nsx-gitlab 2>/dev/null | grep -q ":${GITLAB_PORT}\$" && return 1
	command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${GITLAB_PORT}\$"
}

status() {
	say "URL         $URL"
	say "SSL dir     $GITLAB_SSL_DIR"
	if [ -f "$GITLAB_SSL_DIR/server.crt" ]; then
		openssl x509 -in "$GITLAB_SSL_DIR/server.crt" -noout -enddate | sed 's/^/certificate  /'
	else
		say "certificate  none yet"
	fi
	[ -f "$CRON_FILE" ] && say "renewal job  $CRON_FILE" || say "renewal job  not installed"
	curl -sf -o /dev/null --max-time 10 --cacert "$GITLAB_SSL_DIR/ca.crt" "$URL/users/sign_in" 2>/dev/null &&
		say "state        answering over HTTPS" || say "state        not answering over HTTPS"
}

main() {
	need openssl
	case "${1:-}" in
	--status)
		status
		exit 0
		;;
	--renew)
		lock_ssl
		if cert_ok; then
			exit 0
		fi
		issue_cert
		reload_nginx
		exit 0
		;;
	"") ;;
	*) die "unknown option: $1. Try --renew or --status." ;;
	esac

	# Checks that only read the compose file come first: they need no Docker, and
	# they explain what to do even on a host where Docker is not running yet.
	[ -f "$COMPOSE_DIR/docker-compose.yml" ] || die "$COMPOSE_DIR/docker-compose.yml is missing."
	grep -q GITLAB_SCHEME "$COMPOSE_DIR/docker-compose.yml" ||
		die "docker-compose.yml predates HTTPS support. Bring the tree up to date first: update.sh in your clone of the generator."
	# GitLab 16.3 removed bundled Grafana; any grafana[...] setting makes
	# 'gitlab-ctl reconfigure' abort, and the container then cannot start.
	grep -Eq "^[[:space:]]*grafana\[" "$COMPOSE_DIR/docker-compose.yml" &&
		die "docker-compose.yml has a grafana[...] setting, which GitLab 17 rejects. Bring the tree up to date first (update.sh), or delete that line."
	need docker
	need curl
	docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon."
	lock_ssl
	if port_clash; then
		die "port $GITLAB_PORT is already in use on this host by something else."
	fi

	cert_ok || issue_cert
	write_env
	compose config -q || die "docker-compose.yml is not valid; nothing was restarted."
	say "restarting GitLab with $URL (data is kept)..."
	compose up -d
	wait_for_https
	trust_runner
	install_cron

	cat <<DONE

===================================================================
 GitLab is serving HTTPS
===================================================================

  URL      $URL
  CA       $GITLAB_SSL_DIR/ca.crt   (import into browsers and other clients)

Point existing clones at it:

  git remote set-url origin $URL/<group>/<project>.git
  git config http.sslCAInfo $GITLAB_SSL_DIR/ca.crt

and use $URL as --url for scripts/gitlab-setup.sh.
Certificate renews itself when under ${RENEW_DAYS} days remain.

DONE
}

main "$@"
SCAFFOLD_EOF
mark_executable scripts/gitlab-https.sh

write_file deploy/ci-image/Dockerfile <<'SCAFFOLD_EOF'
# The image every pipeline job runs in.
#
# Built on the runner host by scripts/ci-image.sh from these two Docker Hub
# images and nothing else: no apk, apt or pip. A network that blocks package
# mirrors but allows Docker Hub (the usual corporate shape) therefore still
# works, and jobs start with everything already installed.
#
# Python 3 (validation and pipeline generation), Terraform, and the tools the
# scripts use: bash, curl, git, make. Changing this file or providers.tf
# changes the image's hash, and the next converge rebuilds the image.
#
# The NSX provider pinned in providers.tf is in the image too, so a plan never
# downloads it. ci-image.sh fetches it into plugins/ on the host before the
# build, the way jobs reach the internet. Likewise the Python packages pinned in
# requirements.txt (PyYAML, so validation reads YAML with a full parser), into
# wheels/, installed here from those files alone. Terraform uses
# /usr/local/share/terraform/plugins on its own (an implied local mirror):
# providers found there are never looked up anywhere else. A job that sets
# NSX_TF_NETWORK_MIRROR or NSX_TF_FS_MIRROR uses that instead.

FROM hashicorp/terraform:1.9.8 AS terraform
FROM python:3.12-bookworm

COPY --from=terraform /bin/terraform /usr/local/bin/terraform
COPY plugins/ /usr/local/share/terraform/plugins/
COPY wheels/ /tmp/wheels/
RUN if ls /tmp/wheels/*.whl >/dev/null 2>&1; then \
      pip install --no-index --no-deps --no-cache-dir --disable-pip-version-check /tmp/wheels/*.whl; \
    fi && rm -rf /tmp/wheels

ENV TF_IN_AUTOMATION=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Fail the build, not a job, if anything the scripts rely on is missing.
# No ENTRYPOINT. GitLab starts the job with 'sh -c'. An image whose entrypoint
# is terraform (or anything else) is handed 'sh' and exits 1 at once.
ENTRYPOINT []
CMD ["bash"]

RUN terraform version && python3 --version && bash --version >/dev/null \
    && curl --version >/dev/null && git --version && make --version >/dev/null
SCAFFOLD_EOF

write_file deploy/ci-image/requirements.txt <<'SCAFFOLD_EOF'
# Python packages built into the CI image (see Dockerfile), exact versions.
# PyYAML: scripts/validate-data.py and the pipeline scripts read YAML with it.
# Without it they fall back to a reader for a subset of YAML, which refuses
# valid YAML outside that subset.
PyYAML==6.0.2
SCAFFOLD_EOF

write_file deploy/ci-image/providers.tf <<'SCAFFOLD_EOF'
# The providers built into the CI image (see Dockerfile). An exact version, so
# every job of every pipeline runs the same provider until this changes. It
# must satisfy the stacks' own constraint ("~> 3.9"). Changing it rebuilds the
# image at the next scripts/converge.sh.
terraform {
  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "3.12.1"
    }
  }
}
SCAFFOLD_EOF

write_file scripts/tf-mirror.sh <<'SCAFFOLD_EOF'
# shellcheck shell=bash
# Provider installation for networks that cannot reach registry.terraform.io.
# Source this file, then call nsx_tf_mirror_setup before 'terraform init'.
#
#   NSX_TF_NETWORK_MIRROR   https://mirror.example/terraform/providers/
#                           an internal network mirror (Artifactory, Nexus, ...)
#   NSX_TF_FS_MIRROR        /path/inside/the/job
#                           a directory made with 'terraform providers mirror'
#
# Set them as CI/CD variables (Settings -> CI/CD -> Variables). With neither set,
# Terraform installs providers directly from registry.terraform.io, as usual.
# A TF_CLI_CONFIG_FILE that is already set is left alone.

nsx_tf_mirror_setup() {
	[ -n "${TF_CLI_CONFIG_FILE:-}" ] && return 0
	local rc
	if [ -n "${NSX_TF_NETWORK_MIRROR:-}" ]; then
		rc="$(mktemp "${TMPDIR:-/tmp}/nsx-terraformrc.XXXXXX")"
		printf 'provider_installation {\n  network_mirror {\n    url = "%s"\n  }\n}\n' "$NSX_TF_NETWORK_MIRROR" >"$rc"
	elif [ -n "${NSX_TF_FS_MIRROR:-}" ]; then
		rc="$(mktemp "${TMPDIR:-/tmp}/nsx-terraformrc.XXXXXX")"
		printf 'provider_installation {\n  filesystem_mirror {\n    path = "%s"\n  }\n  direct {}\n}\n' "$NSX_TF_FS_MIRROR" >"$rc"
	else
		return 0
	fi
	export TF_CLI_CONFIG_FILE="$rc"
}
SCAFFOLD_EOF

write_file scripts/ci-terraform-validate.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# The 'terraform' validate job: formatting, then init + validate for every stack.
#
# Formatting is offline and always runs. 'init' has to download providers, which
# a locked-down network may not allow. That case is reported as a WARNING, not
# a failure, and never silently:
#
#   exit 0    everything checked
#   exit 1    a real problem: unformatted code, an invalid stack, a provider
#             version that does not exist
#   exit 42   formatting passed but providers could not be downloaded, so
#             'terraform validate' did not run. The pipeline marks this job
#             as passed-with-warnings (allow_failure: exit_codes: 42).
#
# To make validation run on such a network, give the job a provider mirror:
# CI/CD variable NSX_TF_NETWORK_MIRROR or NSX_TF_FS_MIRROR (see tf-mirror.sh),
# or open egress to registry.terraform.io and releases.hashicorp.com.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/tf-mirror.sh
. scripts/tf-mirror.sh
nsx_tf_mirror_setup

failed=0
skipped=()

# A download problem, as opposed to a problem with the code or the constraints.
network_failure() {
	# A constraint that matches nothing is a problem in the code, even though
	# Terraform introduces it with the same "Failed to query" line as a download.
	grep -Eqi 'no available releases match|checksum mismatch' <<<"$1" && return 1
	grep -Eqi 'dial tcp|no such host|lookup [^ ]+: |i/o timeout|timeout awaiting|connection refused|connection reset|network is unreachable|proxyconnect|tls: |x509:|unexpected EOF|could not connect to|failed to query available provider packages|failed to install provider|403 forbidden|407 proxy|client\.timeout|context deadline exceeded|tls handshake timeout|certificate signed by unknown|self-signed|self signed' <<<"$1"
}

echo "--- terraform fmt"
terraform fmt -recursive -check -diff . || failed=1

for stack in stacks/*/; do
	echo "--- ${stack}"
	out=""
	ok=0
	for attempt in 1 2 3; do
		if out="$(terraform -chdir="${stack}" init -backend=false -input=false -no-color 2>&1)"; then
			ok=1
			break
		fi
		network_failure "$out" || break # a real error will not fix itself
		echo "init failed (attempt $attempt of 3), retrying..." >&2
		sleep $((attempt * ${NSX_INIT_RETRY_SLEEP:-4}))
	done
	if [ "$ok" = 1 ]; then
		printf '%s\n' "$out" | tail -3
		terraform -chdir="${stack}" validate -no-color || failed=1
	elif network_failure "$out"; then
		printf '%s\n' "$out" | tail -8
		skipped+=("${stack}")
	else
		printf '%s\n' "$out"
		failed=1
	fi
done

[ "$failed" -eq 0 ] || exit 1

if [ "${#skipped[@]}" -gt 0 ]; then
	cat <<MSG

==============================================================================
 WARNING: terraform validate did NOT run for ${#skipped[@]} stack(s):
   ${skipped[*]}
 Providers could not be downloaded from this job. Formatting passed.
 Fix it once and this warning goes away:
   * set the CI/CD variable NSX_TF_NETWORK_MIRROR (an internal provider mirror), or
   * allow this runner to reach registry.terraform.io and releases.hashicorp.com.
 Plan and apply jobs need the same access; they will fail at 'init' without it.
==============================================================================
MSG
	exit 42
fi
SCAFFOLD_EOF
mark_executable scripts/ci-terraform-validate.sh

write_file scripts/ci-image.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Build the image every pipeline job runs in, and prove it works.
#
#   scripts/ci-image.sh            build if missing or out of date, then verify
#   scripts/ci-image.sh --check    report only; exit 1 if it is missing or stale
#
# The image holds everything a job needs (Python, Terraform, bash, curl, git),
# so jobs never download packages. It is built here, on the runner host, from
# two Docker Hub images and nothing else: no apk, apt or pip, which a locked-down
# network usually blocks even when Docker Hub is reachable through a proxy.
#
# The NSX provider pinned in deploy/ci-image/providers.tf goes into the image
# too, so plans and applies never download it. It is fetched before the build
# by 'terraform providers mirror' in the Terraform base image, with the proxy
# settings jobs get (scripts/gitlab-runner.sh --print-env) and the host's CA
# bundle. If that fetch fails the image is still built, without the provider,
# and this exits 2: jobs then download it themselves, and the next run tries
# again.
#
# The Python packages pinned in deploy/ci-image/requirements.txt (PyYAML) are
# fetched the same way, with pip in the Python base image: from PyPI through the
# job proxy, or from NSX_PIP_INDEX_URL (your own PyPI mirror) when set. If that
# fails the image is still built, validation falls back to its built-in YAML
# reader, and this exits 2 and tries again next time.
#
# NSX_CI_IMAGE (default nsx-ci:1). A name that does not start with 'nsx-ci:' is
# treated as an image from your own registry: it is pulled, not built.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${NSX_CI_IMAGE:-nsx-ci:1}"
CONTEXT="$REPO_ROOT/deploy/ci-image"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

command -v docker >/dev/null 2>&1 || die "docker is not installed."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and are you root or in the docker group?"

verify() {
	# Do not pass --entrypoint. GitLab starts a job with 'sh -c', and an image
	# whose entrypoint is terraform turns that into 'terraform sh' and exits 1
	# at once. Clearing the entrypoint here would hide that image.
	docker run --rm "$IMAGE" sh -c \
		'terraform version >/dev/null && python3 --version >/dev/null && bash --version >/dev/null && curl --version >/dev/null && git --version >/dev/null' \
		>/dev/null 2>&1
}

PLUGINS="$CONTEXT/plugins"
WHEELS="$CONTEXT/wheels"
PROVIDER_DIR="registry.terraform.io/vmware/nsxt"
pyyaml_inside() { docker run --rm "$IMAGE" python3 -c 'import yaml' >/dev/null 2>&1; }
baked() { # the image holds the pinned provider for this host's platform
	docker run --rm "$IMAGE" sh -c "ls /usr/local/share/terraform/plugins/$PROVIDER_DIR/terraform-provider-nsxt_$(provider_version)_linux_$(platform)*.zip" >/dev/null 2>&1
}
provider_version() { sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONTEXT/providers.tf" | head -1; }
platform() {
	case "$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)" in
	aarch64 | arm64) echo arm64 ;;
	*) echo amd64 ;;
	esac
}

# Fetch the pinned providers into $PLUGINS, the way a job would reach the
# internet. Returns 1, with the reason in $log, if it could not.
fetch_providers() {
	local envfile bundle=() attempt tfimg
	tfimg="$(bases | head -1)"
	rm -rf "$PLUGINS"
	mkdir -p "$PLUGINS"
	envfile="$(mktemp)"
	[ -x "$REPO_ROOT/scripts/gitlab-runner.sh" ] && "$REPO_ROOT/scripts/gitlab-runner.sh" --print-env >"$envfile" 2>/dev/null
	# The host trust store, so a TLS-inspecting proxy's CA is trusted as on the host.
	for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
		[ -f "$ca" ] && bundle=(-v "$ca:/etc/ssl/certs/ca-certificates.crt:ro") && break
	done
	for attempt in 1 2 3; do
		say "fetching vmware/nsxt $(provider_version) for the CI image (attempt $attempt of 3)..."
		# As this user, so the next run can replace what it writes; HOME for
		# Terraform's own files, which an arbitrary user cannot write in /root.
		if docker run --rm --network host --env-file "$envfile" ${bundle[@]+"${bundle[@]}"} \
			--user "$(id -u):$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 \
			-v "$CONTEXT:/ctx" -w /ctx "$tfimg" providers mirror -platform="linux_$(platform)" /ctx/plugins >>"$log" 2>&1 &&
			ls "$PLUGINS/$PROVIDER_DIR"/*.zip >/dev/null 2>&1; then
			rm -f "$envfile"
			return 0
		fi
		[ "$attempt" -lt 3 ] && sleep $((attempt * ${NSX_PULL_RETRY_SLEEP:-15}))
	done
	rm -f "$envfile"
	rm -rf "$PLUGINS"
	mkdir -p "$PLUGINS"
	return 1
}

# Fetch the pinned Python packages into $WHEELS with pip, as a job would reach
# the internet. Returns 1, with the reason in $log, if it could not.
fetch_wheels() {
	local envfile bundle=() attempt pyimg index=()
	pyimg="$(bases | sed -n 2p)"
	rm -rf "$WHEELS"
	mkdir -p "$WHEELS"
	envfile="$(mktemp)"
	[ -x "$REPO_ROOT/scripts/gitlab-runner.sh" ] && "$REPO_ROOT/scripts/gitlab-runner.sh" --print-env >"$envfile" 2>/dev/null
	for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
		[ -f "$ca" ] && bundle=(-v "$ca:/etc/ssl/certs/ca-certificates.crt:ro" -e PIP_CERT=/etc/ssl/certs/ca-certificates.crt) && break
	done
	[ -z "${NSX_PIP_INDEX_URL:-}" ] || index=(-e "PIP_INDEX_URL=$NSX_PIP_INDEX_URL")
	for attempt in 1 2 3; do
		say "fetching Python packages for the CI image (attempt $attempt of 3)..."
		if docker run --rm --network host --env-file "$envfile" ${bundle[@]+"${bundle[@]}"} ${index[@]+"${index[@]}"} \
			--user "$(id -u):$(id -g)" -e HOME=/tmp -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
			-v "$CONTEXT:/ctx" -w /ctx "$pyimg" pip download --only-binary=:all: --no-deps -r /ctx/requirements.txt -d /ctx/wheels >>"$log" 2>&1 &&
			ls "$WHEELS"/*.whl >/dev/null 2>&1; then
			rm -f "$envfile"
			return 0
		fi
		[ "$attempt" -lt 3 ] && sleep $((attempt * ${NSX_PULL_RETRY_SLEEP:-15}))
	done
	rm -f "$envfile"
	rm -rf "$WHEELS"
	mkdir -p "$WHEELS"
	return 1
}

why_build_failed() {
	local log="$1"
	if grep -Eqi 'toomanyrequests|too many requests|rate limit|\b429\b' "$log"; then
		say "  Docker Hub is rate-limiting this host (anonymous pulls are limited per address; the limit resets after a few"
		say "  hours). Run 'docker login' with a Docker Hub account, or wait and re-run scripts/converge.sh. Once the base"
		say "  images are on this host the build needs no registry at all."
	elif grep -Eqi 'x509|certificate' "$log"; then
		say "  A TLS certificate problem reaching Docker Hub (an inspecting proxy?). The Docker daemon must trust"
		say "  your proxy's CA: install it in the host trust store (update-ca-certificates) and restart Docker."
	elif grep -Eqi 'dial tcp|no such host|lookup |timeout|proxyconnect|connection refused|unreachable' "$log"; then
		say "  This host cannot reach Docker Hub. Configure the Docker daemon's proxy (systemd drop-in with"
		say "  HTTPS_PROXY/NO_PROXY, then 'systemctl restart docker'), or point NSX_CI_IMAGE at an image in a registry you can reach."
	else
		say "  See the build output above."
	fi
}

if [[ "$IMAGE" != nsx-ci:* ]]; then
	# An image from the operator's own registry.
	if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
		[ "$CHECK" = 1 ] && die "$IMAGE is not on this host."
		say "pulling $IMAGE..."
		docker pull "$IMAGE" >/dev/null 2>&1 || die "could not pull $IMAGE. Is the registry reachable from this host?"
	fi
	verify || die "$IMAGE is present but lacks a tool the pipeline needs (terraform, python3, bash, curl, git)."
	say "CI image $IMAGE (external) ready."
	exit 0
fi

[ -f "$CONTEXT/Dockerfile" ] || die "$CONTEXT/Dockerfile is missing. Bring the tree up to date with update.sh."
[ -f "$CONTEXT/providers.tf" ] || die "$CONTEXT/providers.tf is missing. Bring the tree up to date with update.sh."
[ -f "$CONTEXT/requirements.txt" ] || die "$CONTEXT/requirements.txt is missing. Bring the tree up to date with update.sh."
want="$(cat "$CONTEXT/Dockerfile" "$CONTEXT/providers.tf" "$CONTEXT/requirements.txt" | sha256sum | cut -c1-12)"
have="$(docker image inspect -f '{{ index .Config.Labels "nsx.dockerfile" }}' "$IMAGE" 2>/dev/null || true)"

# An image built without the provider or the Python packages is labelled
# <hash>-noprovider and/or -nopython, and is rebuilt (the fetch tried again)
# on every run until the fetch works.
if [ "$have" = "$want" ]; then
	if verify && baked && pyyaml_inside; then
		say "CI image $IMAGE is current (vmware/nsxt $(provider_version) and PyYAML inside)."
		exit 0
	fi
	say "CI image $IMAGE is present but does not pass its checks; rebuilding."
elif [[ "$have" == "$want"-no* ]]; then
	[ "$CHECK" = 1 ] && { say "CI image $IMAGE is incomplete (${have#"$want"-}): run scripts/converge.sh to try again."; exit 2; }
	say "CI image $IMAGE is incomplete (${have#"$want"-}); trying again."
elif [ -n "$have" ]; then
	say "CI image $IMAGE is out of date; rebuilding."
fi
[ "$CHECK" = 1 ] && die "CI image $IMAGE is missing or out of date."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# The base images named by FROM lines.
bases() { sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/Ip' "$CONTEXT/Dockerfile"; }

# Get the base images into the local image store first, retrying: Docker Hub rate-limits
# anonymous pulls and networks blip. A build from images already here needs no registry.
ensure_bases() {
	local b attempt plog
	plog="$(mktemp)"
	for b in $(bases); do
		docker image inspect "$b" >/dev/null 2>&1 && continue
		for attempt in 1 2 3; do
			say "pulling $b (attempt $attempt of 3)..."
			docker pull -q "$b" >"$plog" 2>&1 && break
			cat "$plog" >>"$log"
			[ "$attempt" -lt 3 ] && sleep $((attempt * ${NSX_PULL_RETRY_SLEEP:-15}))
		done
	done
	rm -f "$plog"
}

ensure_bases
label="$want"
if ! fetch_providers; then
	label="$want-noprovider"
	fetch_failed="$(grep -Ei 'error|failed|could not|timeout|x509|proxy' "$log" | tail -6)"
fi
: >"$log.pip"
if ! log="$log.pip" fetch_wheels; then
	[ "$label" = "$want" ] && label="$want-nopython" || label="$label-nopython"
	pip_failed="$(grep -Ei 'error|failed|could not|timeout|x509|proxy|ssl' "$log.pip" | tail -4)"
fi
cat "$log.pip" >>"$log"
rm -f "$log.pip"
say "building CI image $IMAGE (a minute or two the first time)..."
if ! docker build --pull=false --label "nsx.dockerfile=$label" -t "$IMAGE" "$CONTEXT" >>"$log" 2>&1; then
	# Registry metadata lookups can fail where a plain build of cached images still works.
	if ! DOCKER_BUILDKIT=0 docker build --pull=false --label "nsx.dockerfile=$label" -t "$IMAGE" "$CONTEXT" >>"$log" 2>&1; then
		tail -15 "$log" | sed 's/^/    /' >&2
		why_build_failed "$log" >&2
		die "could not build $IMAGE."
	fi
fi
verify || {
	tail -5 "$log" | sed 's/^/    /' >&2
	die "built $IMAGE but it failed its own checks."
}
if [ "$label" != "$want" ]; then
	if [[ "$label" == *-noprovider* ]]; then
		printf '%s\n' "${fetch_failed:-(no error text)}" | sed 's/^/    /'
		say "  The NSX provider could not be fetched from this host the way jobs reach the internet, so"
		say "  jobs will download it themselves. Fix the network (NSX_HTTPS_PROXY in deploy/gitlab/ci-network.env,"
		say "  the proxy allowing registry.terraform.io, releases.hashicorp.com and release-assets.githubusercontent.com),"
		say "  or set the CI/CD variable NSX_TF_NETWORK_MIRROR, then run scripts/converge.sh again."
		say "CI image $IMAGE built and verified, WITHOUT the NSX provider."
	fi
	if [[ "$label" == *-nopython* ]]; then
		printf '%s\n' "${pip_failed:-(no error text)}" | sed 's/^/    /'
		say "  PyYAML could not be fetched from this host the way jobs reach the internet, so validation"
		say "  uses its built-in reader, which accepts only the YAML this repository writes. Let the proxy"
		say "  reach pypi.org and files.pythonhosted.org, or set NSX_PIP_INDEX_URL to your own PyPI mirror,"
		say "  then run scripts/converge.sh again."
		say "CI image $IMAGE built and verified, WITHOUT PyYAML."
	fi
	exit 2
fi
baked || die "built $IMAGE but vmware/nsxt $(provider_version) is not inside it."
pyyaml_inside || die "built $IMAGE but PyYAML is not inside it."
say "CI image $IMAGE built and verified (vmware/nsxt $(provider_version) and PyYAML inside)."
SCAFFOLD_EOF
mark_executable scripts/ci-image.sh

write_file scripts/gitlab-runner.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Make this host's GitLab runner registered, online and configured for the
# network it is on. Safe to run any number of times.
#
#   scripts/gitlab-runner.sh                 converge
#   scripts/gitlab-runner.sh --print-profile show what it would configure; change nothing
#   scripts/gitlab-runner.sh --print-env     the proxy variables jobs will get (KEY=VALUE)
#   scripts/gitlab-runner.sh --install-ca    refresh the CA bundle in the runner; change nothing else
#   scripts/gitlab-runner.sh --bundle-ca F   write that bundle to F; change nothing (for tests)
#
# It looks at this host and configures the runner to match:
#   * docker executor, image NSX_CI_IMAGE (default nsx-ci:1), host network
#   * pull_policy if-not-present: the CI image is built here, there is nothing to pull
#   * the host proxy for internet access. Jobs get HTTP(S)_PROXY from this
#     shell, then from the Docker daemon. If the host set only one of them, it
#     is used for both. NSX_HTTP_PROXY / NSX_HTTPS_PROXY override that.
#   * NO_PROXY is the only default written into the container config: localhost,
#     this host, GitLab, and every private range (RFC 1918). The host's own
#     NO_PROXY is not copied. NSX_NO_PROXY adds extra entries on top.
#   * the host's CA bundle mounted into jobs, so a TLS-inspecting proxy does not break them
#   * GitLab's own CA plus the host trust store, when GitLab is served over HTTPS.
#     Git in a job trusts only that file, so a TLS-inspecting proxy that the
#     runner itself accepts will otherwise fail every clone with exit 1.
#   * a pre-get-sources script that copies CI_SERVER_TLS_CA_FILE into the
#     helper's temp dir (readable path) and sets sslCAInfo for this GitLab URL.
#     A direct pointer at the runner's path often fails with "Problem with the
#     SSL CA cert (path? access rights?)" during git clone.
# Overrides, if you need them, go in deploy/gitlab/ci-network.env (KEY=VALUE lines).
# When GitLab is on another host, set NSX_GITLAB_CA_FILE to that GitLab's ca.crt
# on this machine (the file install_ca copies into the runner container).
#
# If anything about that differs from what the runner has, the runner is
# re-registered (its old registration is removed). Otherwise nothing is touched,
# so running this never interrupts a job.
#
# Registration needs an admin token. On the host that runs GitLab in Docker it is
# minted on the spot and revoked afterwards. For another GitLab, export
# GITLAB_TOKEN (scope api, Maintainer on the project).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/deploy/gitlab"
ENV_FILE="$COMPOSE_DIR/.env"
NET_FILE="$COMPOSE_DIR/ci-network.env"
RUNNER=nsx-gitlab-runner
GITLAB=nsx-gitlab
MODE=converge
PROJECT="${GITLAB_PROJECT:-}"
BUNDLE_OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
	--print-profile) MODE=profile ;;
	--print-env) MODE="env" ;;
	--install-ca) MODE=install-ca ;;
	--bundle-ca)
		MODE=bundle
		BUNDLE_OUT="${2:?--bundle-ca needs a path}"
		shift
		;;
	--project)
		PROJECT="${2:?--project needs GROUP/NAME}"
		shift
		;;
	*)
		printf 'error: unknown option %s\n' "$1" >&2
		exit 1
		;;
	esac
	shift
done

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

saved() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 || true; }
if [ -f "$NET_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$NET_FILE"
	set +a
fi

SCHEME="${GITLAB_SCHEME:-$(saved GITLAB_SCHEME)}"
SCHEME="${SCHEME:-http}"
HOST="${GITLAB_HOST:-$(saved GITLAB_HOST)}"
HOST="${HOST:-localhost}"
if [ "$SCHEME" = https ]; then PORT="${GITLAB_PORT:-$(saved GITLAB_PORT)}"; PORT="${PORT:-8443}"; else PORT="${GITLAB_PORT:-$(saved GITLAB_PORT)}"; PORT="${PORT:-8929}"; fi
URL="$SCHEME://$HOST:$PORT"
SSL_DIR="${GITLAB_SSL_DIR:-$(saved GITLAB_SSL_DIR)}"
SSL_DIR="${SSL_DIR:-/opt/nsx-gitlab/ssl}"
CA="$SSL_DIR/ca.crt"
[ -n "${NSX_GITLAB_CA_FILE:-}" ] && [ -f "$NSX_GITLAB_CA_FILE" ] && CA="$NSX_GITLAB_CA_FILE"
CI_IMAGE="${NSX_CI_IMAGE:-nsx-ci:1}"
HOST_CA_BUNDLE="${NSX_HOST_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# One line for --pre-get-sources-script. Git clone runs in the helper; the path in
# CI_SERVER_TLS_CA_FILE is not always readable there. Copy to RUNNER_TEMP_PROJECT_DIR.
PRE_GET_SOURCES_CA='if [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then _d="${RUNNER_TEMP_PROJECT_DIR:-/tmp}"; _f="${_d}/nsx-gitlab-ca.pem"; mkdir -p "$_d" 2>/dev/null || true; cp "$CI_SERVER_TLS_CA_FILE" "$_f" && chmod 644 "$_f" && git config --global --unset-all http.sslCAInfo 2>/dev/null || true; if [ -n "${CI_SERVER_URL:-}" ]; then _u="${CI_SERVER_URL%/}"; git config --global "http.${_u}.sslCAInfo" "$_f"; git config --global "http.${_u}/.sslCAInfo" "$_f"; fi; fi'

# The file git is told to trust (http.<gitlab>/.sslCAInfo) REPLACES the system
# store. The runner's own client trusts this file AND the system store. A proxy
# that re-signs TLS is therefore fine for the runner and fatal for every clone
# unless the host bundle is in this file too.
write_ca_bundle() { # write_ca_bundle DEST
	local dest="$1"
	[ -f "$CA" ] || return 1
	cat "$CA" >"$dest"
	if [ -n "$HOST_CA_BUNDLE" ] && [ -f "$HOST_CA_BUNDLE" ]; then
		printf '\n' >>"$dest"
		cat "$HOST_CA_BUNDLE" >>"$dest"
	fi
}

install_ca_into_runner() {
	[ "$SCHEME" = https ] || return 0
	[ -f "$CA" ] || return 0
	docker inspect "$RUNNER" >/dev/null 2>&1 || return 0
	local tmp
	tmp="$(mktemp)"
	write_ca_bundle "$tmp" || { rm -f "$tmp"; return 1; }
	docker exec "$RUNNER" mkdir -p /etc/gitlab-runner/certs || { rm -f "$tmp"; return 1; }
	docker cp "$tmp" "$RUNNER:/etc/gitlab-runner/certs/$HOST.crt" >/dev/null || { rm -f "$tmp"; return 1; }
	docker cp "$tmp" "$RUNNER:/etc/gitlab-runner/certs/ca.crt" >/dev/null || { rm -f "$tmp"; return 1; }
	rm -f "$tmp"
	# The runner process and the helper's git must be able to read tls-ca-file.
	docker exec "$RUNNER" chmod 644 "/etc/gitlab-runner/certs/$HOST.crt" "/etc/gitlab-runner/certs/ca.crt" >/dev/null 2>&1 || true
}

runner_ca_bundle_ok() {
	[ "$SCHEME" = https ] || return 0
	docker exec "$RUNNER" sh -c "test -r /etc/gitlab-runner/certs/$HOST.crt && grep -q BEGIN /etc/gitlab-runner/certs/$HOST.crt" >/dev/null 2>&1
}

# --- the profile: what the runner should look like on this host ---------------

daemon_proxy() { # daemon_proxy HTTPProxy|HTTPSProxy|NoProxy
	command -v docker >/dev/null 2>&1 || return 0
	docker info --format "{{.$1}}" 2>/dev/null || true
}

compute_profile() {
	# Internet access uses the host proxy. An explicit NSX_* value wins, then
	# this shell, then the Docker daemon. One value covers both schemes when
	# the host only exported one.
	p_http="${NSX_HTTP_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
	p_https="${NSX_HTTPS_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"
	[ -n "$p_http" ] || p_http="$(daemon_proxy HTTPProxy)"
	[ -n "$p_https" ] || p_https="$(daemon_proxy HTTPSProxy)"
	[ -n "$p_https" ] || p_https="$p_http"
	[ -n "$p_http" ] || p_http="$p_https"
	# Test hook: make every outside address unreachable, as on a network with no egress.
	if [ "${NSX_TEST_BLOCK_EGRESS:-}" = 1 ]; then
		p_http="http://127.0.0.1:9"
		p_https="http://127.0.0.1:9"
	fi
	# The only default in the container config. The host's NO_PROXY is not
	# copied; a re-register must not drop these or send private addresses out
	# through the proxy. NSX_NO_PROXY adds to this list.
	p_no=""
	append_no_proxy() {
		[ -n "$1" ] || return 0
		case ",${p_no}," in
		*",$1,"*) ;;
		*) p_no="${p_no:+$p_no,}$1" ;;
		esac
	}
	for item in localhost 127.0.0.1 "$HOST" "$GITLAB" 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
		append_no_proxy "$item"
	done
	if [ -n "${NSX_NO_PROXY:-}" ]; then
		local oldifs="$IFS"
		IFS=','
		for item in $NSX_NO_PROXY; do
			append_no_proxy "$item"
		done
		IFS="$oldifs"
	fi
	envs=()
	[ -n "$p_http" ] && envs+=("HTTP_PROXY=$p_http" "http_proxy=$p_http")
	[ -n "$p_https" ] && envs+=("HTTPS_PROXY=$p_https" "https_proxy=$p_https")
	envs+=("NO_PROXY=$p_no" "no_proxy=$p_no")
	flags=(--executor docker --docker-image "$CI_IMAGE" --docker-network-mode host
		--docker-pull-policy if-not-present --docker-volumes /cache)
	[ -f "$HOST_CA_BUNDLE" ] && flags+=(--docker-volumes "$HOST_CA_BUNDLE:$HOST_CA_BUNDLE:ro")
	[ "$SCHEME" = https ] && flags+=(--tls-ca-file "/etc/gitlab-runner/certs/$HOST.crt")
	for kv in ${envs[@]+"${envs[@]}"}; do flags+=(--env "$kv"); done
	flags+=(--pre-get-sources-script "$PRE_GET_SOURCES_CA")
	profile_hash="$(printf '%s\n' "$URL" "${flags[@]}" | sha256sum | cut -c1-16)"
}
compute_profile

case "$MODE" in
profile)
	say "gitlab     $URL"
	say "project    ${PROJECT:-(taken from the git remote)}"
	say "ci image   $CI_IMAGE"
	say "profile    $profile_hash"
	printf '  %s\n' "${flags[@]}"
	exit 0
	;;
env)
	printf '%s\n' ${envs[@]+"${envs[@]}"}
	exit 0
	;;
bundle)
	write_ca_bundle "$BUNDLE_OUT" || die "CA not found at $CA"
	exit 0
	;;
install-ca)
	command -v docker >/dev/null 2>&1 || die "docker is not installed."
	docker inspect "$RUNNER" >/dev/null 2>&1 || die "the runner container '$RUNNER' is not running."
	[ "$SCHEME" = https ] || { say "GitLab is not on HTTPS; no CA to install."; exit 0; }
	[ -f "$CA" ] || die "CA not found at $CA"
	install_ca_into_runner || die "could not install the CA bundle into the runner."
	say "CA bundle installed for $HOST (GitLab CA plus the host trust store)."
	exit 0
	;;
esac

# --- converge -----------------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker is not installed."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon."

if [ -z "$PROJECT" ]; then
	remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
	PROJECT="$(printf '%s' "$remote" | sed -E 's#^(https?://[^/]+/|[^@]+@[^:]+:)##; s#\.git$##')"
fi
[ -n "$PROJECT" ] || die "cannot tell which GitLab project this runner belongs to. Pass --project GROUP/NAME."

curl_gl() { # curl_gl <curl args...> against GitLab, trusting our CA when on HTTPS
	local ca=()
	[ "$SCHEME" = https ] && [ -f "$CA" ] && ca=(--cacert "$CA")
	curl -sS --max-time 60 ${ca[@]+"${ca[@]}"} --noproxy '*' "$@"
}

runner_up() {
	docker inspect -f '{{.State.Running}}' "$RUNNER" 2>/dev/null | grep -q true && return 0
	[ -f "$COMPOSE_DIR/docker-compose.yml" ] || return 1
	say "starting the runner container..."
	if docker compose version >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && docker compose up -d runner >/dev/null 2>&1)
	elif command -v docker-compose >/dev/null 2>&1; then
		(cd "$COMPOSE_DIR" && docker-compose up -d runner >/dev/null 2>&1)
	fi
	sleep 3
	docker inspect -f '{{.State.Running}}' "$RUNNER" 2>/dev/null | grep -q true
}
runner_up || die "the runner container '$RUNNER' is not running and could not be started."

# Refresh even when the registration itself is already current: the runner
# re-reads this file, and the next job's git clone receives it. No restart.
install_ca_into_runner || die "could not install the CA bundle into the runner ($CA)."

registered() { docker exec "$RUNNER" grep -q '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null; }
valid() { docker exec "$RUNNER" gitlab-runner verify 2>&1 | grep -qi 'is valid'; }
have_profile() { docker exec "$RUNNER" cat /etc/gitlab-runner/nsx-profile 2>/dev/null | tr -d '\r\n'; }

if registered && valid && [ "$(have_profile)" = "$profile_hash" ]; then
	say "runner already registered and current ($profile_hash)."
	exit 0
fi

if registered; then
	if valid; then say "runner settings changed for this host; re-registering."; else say "runner registration is no longer valid on GitLab; re-registering."; fi
else
	say "runner is not registered; registering."
fi

# A token that can create a runner.
seed=""
revoke() { [ -n "$seed" ] && docker exec "$GITLAB" gitlab-rails runner "PersonalAccessToken.find_by_token('$seed')&.revoke!" >/dev/null 2>&1; }
trap revoke EXIT
token="${GITLAB_TOKEN:-}"
if [ -z "$token" ]; then
	docker inspect "$GITLAB" >/dev/null 2>&1 || die "no GitLab container ('$GITLAB') on this host and no GITLAB_TOKEN set, so a runner token cannot be created. Export GITLAB_TOKEN (scope api) and re-run."
	seed="nsxrunner$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	got="$(docker exec "$GITLAB" gitlab-rails runner "
		u = User.find_by_username('root')
		t = u.personal_access_tokens.create!(scopes: ['api'], name: 'nsx-runner', expires_at: 1.day.from_now)
		t.set_token('$seed'); t.save!
		puts '$seed'" 2>/dev/null | tr -d '\r' | tail -1)"
	[ "$got" = "$seed" ] || die "could not mint a token inside $GITLAB. Is GitLab fully started? Check: docker logs --tail=50 $GITLAB"
	token="$seed"
fi

pid="$(curl_gl -H "PRIVATE-TOKEN: $token" "$URL/api/v4/projects/$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
[ -n "$pid" ] || die "GitLab at $URL does not know a project '$PROJECT' (or $URL is not reachable from this host / its certificate is not trusted: $CA)."

# Clear the old registration first, so runners never pile up.
if registered; then docker exec "$RUNNER" gitlab-runner unregister --all-runners >/dev/null 2>&1; fi

install_ca_into_runner || die "could not install the CA bundle into the runner ($CA)."
runner_ca_bundle_ok || die "the CA bundle in the runner is missing or not readable at /etc/gitlab-runner/certs/$HOST.crt. For GitLab on another host, copy its ca.crt here and set NSX_GITLAB_CA_FILE, then run scripts/converge.sh again."

resp="$(curl_gl -H "PRIVATE-TOKEN: $token" -X POST "$URL/api/v4/user/runners" \
	--data runner_type=project_type --data "project_id=$pid" --data run_untagged=true \
	--data-urlencode "description=nsx-$(hostname -s 2>/dev/null || echo host)")"
rtoken="$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
rid="$(printf '%s' "$resp" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
[ -n "$rtoken" ] || die "GitLab refused to create a runner: $resp"

out="$(docker exec "$RUNNER" gitlab-runner register --non-interactive --url "$URL/" --token "$rtoken" "${flags[@]}" 2>&1)" ||
	die "runner registration failed: $(printf '%s' "$out" | tail -3)"
docker exec "$RUNNER" sh -c "printf '%s\n' '$profile_hash' >/etc/gitlab-runner/nsx-profile"

valid || die "the runner registered but 'gitlab-runner verify' does not say it is valid. See: docker logs --tail=30 $RUNNER"

# Wait until GitLab sees it online.
online=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
	if curl_gl -H "PRIVATE-TOKEN: $token" "$URL/api/v4/runners/$rid" | grep -q '"online":true'; then
		online=1
		break
	fi
	sleep 5
done
[ "$online" = 1 ] || die "the runner registered but GitLab does not show it online after 90 s. See: docker logs --tail=30 $RUNNER"
say "runner registered, valid and online ($profile_hash)."
SCAFFOLD_EOF
mark_executable scripts/gitlab-runner.sh

write_file scripts/converge.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Bring this host to the state this release expects, and say plainly what it found.
#
#   scripts/converge.sh             do it
#   scripts/converge.sh --check     only look and report; change nothing
#
# update.sh runs this after every update, so a release that needs something new
# from the host (a CI image, runner settings, a GitLab container setting) just
# arrives. Run it by hand whenever you want to know whether the host is healthy.
#
# Every step is independent: one failing does not stop the others from being
# checked, and each failure says what to do about it. It exits non-zero only
# when something essential (the CI image, GitLab, the runner) is not working.
# Network limits that only affect Terraform provider downloads are warnings.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/deploy/gitlab"
ENV_FILE="$COMPOSE_DIR/.env"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
CI_IMAGE="${NSX_CI_IMAGE:-nsx-ci:1}"

fails=0
warns=0
ok() { printf '  [ ok ]  %s\n' "$*"; }
warn() {
	printf '  [warn]  %s\n' "$1"
	shift
	for l in "$@"; do printf '          %s\n' "$l"; done
	warns=$((warns + 1))
}
fail() {
	printf '  [FAIL]  %s\n' "$1"
	shift
	for l in "$@"; do printf '          %s\n' "$l"; done
	fails=$((fails + 1))
}
indent() { sed 's/^/          /'; }

echo "converge: $REPO_ROOT"

# --- Docker --------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
	fail "Docker is not installed" "Install Docker Engine: https://docs.docker.com/engine/install/"
	echo
	echo "converge: cannot continue without Docker."
	exit 1
elif ! docker info >/dev/null 2>&1; then
	fail "Cannot talk to the Docker daemon" "Is it running (systemctl status docker)? Are you root or in the docker group?"
	echo
	echo "converge: cannot continue without Docker."
	exit 1
fi
ok "Docker is reachable"

# --- the CI image ---------------------------------------------------------------
img_args=()
[ "$CHECK" = 1 ] && img_args=(--check)
out="$("$REPO_ROOT/scripts/ci-image.sh" ${img_args[@]+"${img_args[@]}"} 2>&1)"
case $? in
0) ok "$(printf '%s' "$out" | tail -1)" ;;
2)
	# Built and working, but without the NSX provider and/or PyYAML: say which.
	missing=()
	grep -q "WITHOUT the NSX provider\|no NSX provider inside\|incomplete (noprovider" <<<"$out" && missing+=("no NSX provider inside")
	grep -q "WITHOUT PyYAML\|nopython" <<<"$out" && missing+=("no PyYAML inside (validation reads YAML with Terraform instead)")
	[ "${#missing[@]}" -gt 0 ] || missing=("incomplete")
	warn "CI image $CI_IMAGE has $(IFS=';'; printf '%s' "${missing[*]}" | sed 's/;/; /g')" "$(printf '%s' "$out" | tail -16 | sed 's/^/ /')"
	;;
*) fail "CI image $CI_IMAGE" "$(printf '%s' "$out" | tail -12 | sed 's/^/ /')" ;;
esac

# --- GitLab on this host ---------------------------------------------------------
gitlab_here=0
if docker inspect nsx-gitlab >/dev/null 2>&1; then
	gitlab_here=1
	if [ "$CHECK" = 1 ]; then
		if [ "$(docker inspect -f '{{.State.Health.Status}}' nsx-gitlab 2>/dev/null)" = healthy ]; then
			ok "GitLab container is healthy"
		else
			fail "GitLab container is not healthy" "docker logs --tail=50 nsx-gitlab"
		fi
	elif [ -f "$ENV_FILE" ] && grep -q '^GITLAB_SCHEME=https' "$ENV_FILE"; then
		# Idempotent: re-applies compose changes, waits for HTTPS, keeps the runner's trust current.
		if out="$("$REPO_ROOT/scripts/gitlab-https.sh" 2>&1)"; then
			ok "GitLab is serving HTTPS ($(sed -n 's/^GITLAB_HOST=//p' "$ENV_FILE"):$(sed -n 's/^GITLAB_PORT=//p' "$ENV_FILE"))"
		else
			fail "GitLab HTTPS" "$(printf '%s' "$out" | tail -12 | sed 's/^/ /')"
		fi
	else
		if (cd "$COMPOSE_DIR" && docker compose up -d >/dev/null 2>&1); then
			ok "GitLab and the runner are up (plain HTTP; run scripts/gitlab-https.sh for HTTPS)"
		else
			fail "Could not start GitLab" "cd deploy/gitlab && docker compose up -d   (then: docker compose logs --tail=50 gitlab)"
		fi
	fi
else
	ok "No GitLab container on this host (external GitLab): container steps skipped"
fi

# --- the runner --------------------------------------------------------------------
if [ "$gitlab_here" = 1 ] || [ -n "${GITLAB_TOKEN:-}" ]; then
	if [ "$CHECK" = 1 ]; then
		if docker exec nsx-gitlab-runner gitlab-runner verify 2>&1 | grep -qi 'is valid'; then
			ok "Runner is registered and valid"
		else
			fail "Runner is not registered or not valid" "Run scripts/converge.sh (without --check) to register it."
		fi
	else
		if out="$("$REPO_ROOT/scripts/gitlab-runner.sh" 2>&1)"; then
			ok "$(printf '%s' "$out" | tail -1)"
		else
			fail "Runner" "$(printf '%s' "$out" | tail -8 | sed 's/^/ /')"
		fi
	fi
else
	warn "Runner not checked" "GitLab is not on this host and GITLAB_TOKEN is not set. Register a runner with the CI image '$CI_IMAGE' yourself, or export GITLAB_TOKEN and re-run."
fi

# --- can a job container reach what Terraform needs? -------------------------------
if docker image inspect "$CI_IMAGE" >/dev/null 2>&1; then
	envfile="$(mktemp)"
	trap 'rm -f "$envfile"' EXIT
	"$REPO_ROOT/scripts/gitlab-runner.sh" --print-env >"$envfile" 2>/dev/null
	bundle=()
	[ -f /etc/ssl/certs/ca-certificates.crt ] && bundle=(-v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro)
	probe='
import urllib.request, sys
bad = 0
for url in ("https://registry.terraform.io/.well-known/terraform.json", "https://releases.hashicorp.com/"):
    host = url.split("/")[2]
    try:
        urllib.request.urlopen(url, timeout=10).read(1)
        print("PASS " + host)
    except Exception as e:
        print("FAIL " + host + ": " + str(getattr(e, "reason", e)))
        bad = 1
sys.exit(bad)'
	if out="$(docker run --rm --network host --env-file "$envfile" ${bundle[@]+"${bundle[@]}"} --entrypoint "" "$CI_IMAGE" python3 -c "$probe" 2>&1)"; then
		ok "Job containers can reach registry.terraform.io and releases.hashicorp.com"
	elif docker run --rm --entrypoint "" "$CI_IMAGE" sh -c 'ls /usr/local/share/terraform/plugins/registry.terraform.io/vmware/nsxt/*.zip' >/dev/null 2>&1; then
		ok "Job containers cannot reach the public Terraform registry, but the NSX provider is in the CI image"
	else
		mirror=""
		[ -f "$COMPOSE_DIR/ci-network.env" ] && mirror="$(grep -E '^NSX_TF_(NETWORK|FS)_MIRROR=' "$COMPOSE_DIR/ci-network.env" || true)"
		if [ -n "${NSX_TF_NETWORK_MIRROR:-}${NSX_TF_FS_MIRROR:-}$mirror" ]; then
			ok "Job containers cannot reach the public Terraform registry, but a provider mirror is configured"
		else
			warn "Job containers cannot download Terraform providers" \
				"$(printf '%s' "$out" | tr '\n' ' ')" \
				"What still works: validate-data, the matrix job, formatting. terraform validate shows a" \
				"warning instead of failing. Plan and apply need providers, so before using them:" \
				"  * set the GitLab CI/CD variable NSX_TF_NETWORK_MIRROR to an internal provider mirror, or" \
				"  * allow this host to reach registry.terraform.io and releases.hashicorp.com, through a" \
				"    proxy if that is how this network works (set NSX_HTTPS_PROXY in deploy/gitlab/ci-network.env," \
				"    then run scripts/converge.sh again)."
		fi
	fi
fi

echo
if [ "$fails" -gt 0 ]; then
	echo "converge: $fails problem(s) need attention, $warns warning(s)."
	exit 1
fi
echo "converge: healthy ($warns warning(s))."
SCAFFOLD_EOF
mark_executable scripts/converge.sh

write_file scripts/selftest.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Prove this repository does what it claims — everything that can be proved
# without a GitLab, a Vault or an NSX manager.
#
#   scripts/selftest.sh           full run
#   scripts/selftest.sh --quick   skip terraform init/validate (the slow part)
#
# Run it before trusting the generator, after changing it, and in CI. It exits
# non-zero on the first thing that is not true.
#
# What it CANNOT prove is listed at the end, and in docs/ACCEPTANCE.md: nothing
# here talks to a real GitLab, a real Vault, or a real NSX manager, so a green
# run means "the generator and the validators are correct", not "this is safe to
# apply to your estate".

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

pass=0
fail=0
skip=0
WORK=""

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

ok() {
	pass=$((pass + 1))
	printf '  PASS  %s\n' "$*"
}
bad() {
	fail=$((fail + 1))
	printf '  FAIL  %s\n' "$*"
}
skipped() {
	skip=$((skip + 1))
	printf '  SKIP  %s\n' "$*"
}
phase() { printf '\n== %s\n' "$*"; }

[ -x "$BOOTSTRAP" ] || {
	printf 'error: %s is missing or not executable\n' "$BOOTSTRAP" >&2
	exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nsx-selftest.XXXXXX")"
A="$WORK/a"
B="$WORK/b"
C="$WORK/c"
mkdir -p "$A" "$B" "$C"

# --------------------------------------------------------------------------
phase "1. the generator produces a tree"

if "$BOOTSTRAP" --dir "$A" --vcs none --quiet </dev/null >"$WORK/gen.log" 2>&1; then
	n="$(find "$A" -type f | wc -l | tr -d ' ')"
	[ "$n" -gt 80 ] && ok "generated $n files" || bad "only $n files generated"
else
	bad "generator exited non-zero — see $WORK/gen.log"
fi

for f in Makefile README.md docs/ARCHITECTURE.md scripts/validate-data.py \
	stacks/global-security/main.tf modules/dfw-policy/main.tf; do
	[ -f "$A/$f" ] && ok "present: $f" || bad "missing: $f"
done

# --------------------------------------------------------------------------
phase "2. shell and python syntax"

syn=0
for f in "$A"/scripts/*.sh; do bash -n "$f" 2>/dev/null || { bad "bash -n $f"; syn=1; }; done
for f in "$A"/scripts/*.py; do python3 -m py_compile "$f" 2>/dev/null || { bad "py_compile $f"; syn=1; }; done
[ "$syn" = 0 ] && ok "every generated script parses"

# --------------------------------------------------------------------------
phase "3. data validation"

if (cd "$A" && python3 scripts/validate-data.py >/dev/null 2>&1); then
	ok "validate-data.py passes on the example data"
else
	bad "validate-data.py fails on its own example data"
fi

# Planted defects. Each must be caught, or the validator is decoration.
plant() {
	local label="$1" file="$2" find_s="$3" repl="$4" expect="$5"
	local tmp="$WORK/plant"
	rm -rf "$tmp" && cp -r "$A" "$tmp"
	python3 - "$tmp/$file" "$find_s" "$repl" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
if sys.argv[2] not in t:
    sys.exit(3)
p.write_text(t.replace(sys.argv[2], sys.argv[3], 1))
PY
	case $? in
	3)
		skipped "$label (anchor not found)"
		return 0
		;;
	esac
	# Capture, then match. Piping straight into grep would be wrong under
	# 'set -o pipefail': validate-data.py exits 1 precisely when it has found
	# the defect, so the pipeline would report failure on success.
	local out
	out="$(cd "$tmp" && python3 scripts/validate-data.py 2>&1)"
	if printf '%s' "$out" | grep -q "$expect"; then
		ok "caught: $label"
	else
		bad "NOT caught: $label"
	fi
}

plant "tag scope owned by another system" \
	data/vm-tags/lon1.yaml "scope: workload" "scope: app" "owned by"
plant "unknown tag scope" \
	data/vm-tags/lon1.yaml "scope: workload" "scope: wrokload" "not in data/schema"
plant "duplicate sequence number" \
	data/policies/payments.yaml "sequence_number: 200" "sequence_number: 100" "already used"
plant "undefined group reference" \
	data/policies/payments.yaml "source_groups: [prod-payments-web]" \
	"source_groups: [does-not-exist]" "undefined group"
plant "credential in a data file" \
	inventory/managers.yaml "vault_path:" "password: hunter2
    vault_path:" "looks like a credential"

# --------------------------------------------------------------------------
phase "4. terraform"

if ! command -v terraform >/dev/null 2>&1; then
	skipped "terraform not installed — fmt and validate not run"
elif [ "$QUICK" = 1 ]; then
	if (cd "$A" && terraform fmt -recursive -check . >/dev/null 2>&1); then
		ok "terraform fmt is clean"
	else
		bad "terraform fmt reports changes"
	fi
	skipped "terraform validate (--quick)"
else
	if (cd "$A" && terraform fmt -recursive -check . >/dev/null 2>&1); then
		ok "terraform fmt is clean"
	else
		bad "terraform fmt reports changes"
	fi
	for s in "$A"/stacks/*/; do
		name="$(basename "$s")"
		if terraform -chdir="$s" init -backend=false -input=false >/dev/null 2>&1 &&
			terraform -chdir="$s" validate >/dev/null 2>&1; then
			ok "terraform validate: $name"
		else
			bad "terraform validate: $name"
		fi
	done
fi

# --------------------------------------------------------------------------
phase "5. generated YAML and pipelines"

ymls=0
for f in "$A"/.gitlab-ci.yml "$A"/.github/workflows/*.yml "$A"/deploy/gitlab/docker-compose.yml; do
	[ -f "$f" ] || continue
	ymls=$((ymls + 1))
	python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null ||
		bad "not valid YAML: ${f#"$A"/}"
done
[ "$ymls" -gt 0 ] && ok "$ymls generated YAML file(s) parse"

# A GitLab tree, so the child pipeline can be exercised.
G="$WORK/gitlab"
mkdir -p "$G"
if "$BOOTSTRAP" --dir "$G" --ci gitlab --vcs none --quiet </dev/null >/dev/null 2>&1; then
	mr="$(cd "$G" && python3 scripts/gitlab-child-pipeline.py 2>/dev/null)"
	main="$(cd "$G" && CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main python3 scripts/gitlab-child-pipeline.py 2>/dev/null)"

	printf '%s' "$mr" | python3 -c "import yaml,sys; yaml.safe_load(sys.stdin)" 2>/dev/null &&
		ok "merge-request pipeline is valid YAML" || bad "merge-request pipeline is not valid YAML"
	printf '%s' "$main" | python3 -c "import yaml,sys; yaml.safe_load(sys.stdin)" 2>/dev/null &&
		ok "default-branch pipeline is valid YAML" || bad "default-branch pipeline is not valid YAML"

	# The safety property: a merge request must never be able to apply.
	if printf '%s' "$mr" | grep -q '^"apply'; then
		bad "merge-request pipeline contains apply jobs — it must not"
	else
		ok "no apply jobs on a merge request"
	fi

	napply="$(printf '%s' "$main" | grep -c '^"apply' || true)"
	nmanual="$(printf '%s' "$main" | grep -c 'when: manual' || true)"
	if [ "$napply" -gt 0 ] && [ "$napply" = "$nmanual" ]; then
		ok "every apply job on the default branch is manual ($napply)"
	else
		bad "apply jobs: $napply, manual gates: $nmanual — they must match"
	fi

	if printf '%s' "$main" | grep -q 'VAULT_APPLY_TOKEN' &&
		printf '%s' "$mr" | grep -qv 'VAULT_APPLY_TOKEN'; then
		ok "the write credential appears only in apply jobs"
	fi
else
	bad "could not generate a GitLab tree"
fi

# --------------------------------------------------------------------------
phase "6. the generator is deterministic"

if "$A/scripts/bootstrap.sh" --dir "$B" --vcs none --quiet </dev/null >/dev/null 2>&1 &&
	"$B/scripts/bootstrap.sh" --dir "$C" --vcs none --quiet </dev/null >/dev/null 2>&1; then
	rm -rf "$B/.git" "$C/.git"
	if diff -r "$B" "$C" >/dev/null 2>&1; then
		ok "two generations are byte identical"
	else
		bad "generations differ — the generator is not deterministic"
	fi
else
	bad "could not regenerate from a generated tree"
fi

# Re-running in place must change nothing: same files, same content.
tree_sum() { (cd "$A" && find . -type f -not -path './.git/*' -exec cksum {} + | LC_ALL=C sort | cksum); }
before="$(tree_sum)"
if (cd "$A" && ./scripts/bootstrap.sh --dir . --quiet </dev/null >/dev/null 2>&1); then
	ok "re-running in place succeeds"
	if [ "$(tree_sum)" = "$before" ]; then
		ok "re-running in place changes no file"
	else
		bad "re-running in place changed files"
	fi
else
	bad "re-running in place failed"
fi

# --------------------------------------------------------------------------
phase "7. the overwrite guard"

edited="$A/modules/group/main.tf"
printf '\n# deliberate local edit\n' >>"$edited"
sum_before="$(cksum <"$edited")"

(cd "$A" && ./scripts/bootstrap.sh --dir . --quiet </dev/null >/dev/null 2>&1)
[ "$(cksum <"$edited")" = "$sum_before" ] &&
	ok "no flag: an edited file is untouched" || bad "no flag: an edited file was overwritten"

(cd "$A" && ./scripts/bootstrap.sh --dir . --force </dev/null >/dev/null 2>&1)
[ "$(cksum <"$edited")" = "$sum_before" ] &&
	ok "--force with no phrase: still untouched" || bad "--force with no phrase: file was overwritten"

(cd "$A" && ./scripts/bootstrap.sh --dir . --force --confirm 'wrong phrase' >/dev/null 2>&1)
[ "$(cksum <"$edited")" = "$sum_before" ] &&
	ok "--force with the wrong phrase: still untouched" || bad "wrong phrase overwrote the file"

(cd "$A" && ./scripts/bootstrap.sh --dir . --force --confirm 'wipe everything & start fresh' --quiet >/dev/null 2>&1)
[ "$(cksum <"$edited")" != "$sum_before" ] &&
	ok "--force with the phrase: file is refreshed" || bad "the phrase did not overwrite the file"

# Estate data must survive --force.
data_file="$A/data/groups/payments.yaml"
if [ -f "$data_file" ]; then
	printf '\n# local data edit\n' >>"$data_file"
	d_before="$(cksum <"$data_file")"
	(cd "$A" && ./scripts/bootstrap.sh --dir . --force --confirm 'wipe everything & start fresh' --quiet >/dev/null 2>&1)
	[ "$(cksum <"$data_file")" = "$d_before" ] &&
		ok "--force never touches estate data" || bad "--force overwrote estate data"
fi

# --------------------------------------------------------------------------
phase "8. readiness reports honestly"

R="$WORK/ready"
mkdir -p "$R"
"$BOOTSTRAP" --dir "$R" --quiet </dev/null >/dev/null 2>&1
if (cd "$R" && ./scripts/readiness.sh >/dev/null 2>&1); then
	bad "readiness says a fresh tree is production ready — it is not"
else
	ok "readiness exits non-zero on a fresh tree"
fi

# --------------------------------------------------------------------------
printf '\n===========================================================\n'
printf 'selftest: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"

cat <<'NOTE'

This proves the generator and the validators. It does NOT prove:

  * that GitLab starts, or that the project setup works against a real API
  * that a pipeline runs, or that a runner picks it up
  * that terraform init works against a real state backend
  * that terraform plan works against a real NSX manager
  * that an apply does what the plan said

Those need real infrastructure. docs/ACCEPTANCE.md is the plan for them.
NOTE

[ "$fail" -eq 0 ] || exit 1
exit 0
SCAFFOLD_EOF
mark_executable scripts/selftest.sh

write_file scripts/readiness.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Is this repository ready to run against a production estate?
#
#   scripts/readiness.sh            report; exit 1 if anything blocking remains
#   scripts/readiness.sh --quiet    summary only
#
# Everything here is offline. It answers the question bootstrap.sh cannot:
# generating the files is not the same as being ready to apply them, and the
# difference is a list of decisions and credentials that belong to you.
#
# BLOCK  must be fixed before applying to production
# WARN   should be fixed; not fatal
# MANUAL cannot be checked from here — it lives on the git host or in Vault

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

blocking=0
warnings=0

block() {
	blocking=$((blocking + 1))
	[ "$QUIET" = 1 ] || printf 'BLOCK   %s\n' "$*"
}
warn() {
	warnings=$((warnings + 1))
	[ "$QUIET" = 1 ] || printf 'WARN    %s\n' "$*"
}
ok() { [ "$QUIET" = 1 ] || printf 'ok      %s\n' "$*"; }
manual() { [ "$QUIET" = 1 ] || printf 'MANUAL  %s\n' "$*"; }
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

say ""
say "=== state ==================================================="

# The most common way to reach production with something unsafe.
if grep -rqs 'backend "local"' stacks/*/backend.tf; then
	block "state is still the placeholder local backend, which has NO LOCKING.
        scripts/bootstrap.sh --force --backend gitlab|s3|azure"
else
	backend="$(sed -n 's/.*backend "\([a-z0-9]*\)".*/\1/p' stacks/platform/backend.tf 2>/dev/null | head -1)"
	ok "state backend is '${backend:-unknown}', not the placeholder"
	if [ "$backend" = http ]; then
		if ls envs/*.backend.hcl >/dev/null 2>&1 && ! grep -lqs 'lock_address' envs/*.backend.hcl; then
			block "http backend with no lock_address in envs/*.backend.hcl — no locking"
		else
			ok "http backend declares lock_address"
		fi
	fi
fi

if [ -z "$(ls envs/*.backend.hcl 2>/dev/null)" ]; then
	block "no envs/<site>.backend.hcl — nothing can initialise"
else
	empty=0
	total=0
	for f in envs/*.backend.hcl; do
		total=$((total + 1))
		grep -qv '^[[:space:]]*\(#.*\)\?$' "$f" 2>/dev/null || empty=$((empty + 1))
	done
	if [ "$empty" -gt 0 ]; then
		warn "$empty of $total backend config file(s) contain only comments"
	else
		ok "every envs/*.backend.hcl has content"
	fi
fi

locks="$(find stacks -name .terraform.lock.hcl 2>/dev/null | wc -l | tr -d ' ')"
stacks="$(find stacks -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$locks" -eq 0 ]; then
	block "no .terraform.lock.hcl committed. Run terraform init in each stack and
        commit the lock files, or sites will realize different provider behaviour."
elif [ "$locks" -lt "$stacks" ]; then
	warn "$locks of $stacks stacks have a committed .terraform.lock.hcl"
else
	ok "every stack has a committed .terraform.lock.hcl"
fi

say ""
say "=== the estate ============================================="

if [ -f data/.example-content ]; then
	block "inventory/ and data/ are still the shipped EXAMPLE content, which
        describes no real site. Replace them, then delete data/.example-content."
else
	ok "example content marker is gone"
fi

if [ ! -f inventory/managers.yaml ]; then
	block "inventory/managers.yaml is missing — every run resolves its manager here"
else
	if grep -qs 'example\.internal\|example\.com' inventory/managers.yaml; then
		warn "inventory/managers.yaml still contains example hostnames"
	else
		ok "inventory hostnames look real"
	fi
	if ! grep -qs 'vault_path' inventory/managers.yaml; then
		block "no vault_path in the inventory — credentials cannot be resolved"
	else
		ok "every manager records a vault_path"
	fi
fi

say ""
say "=== validation ============================================="

if command -v python3 >/dev/null 2>&1; then
	if python3 scripts/validate-data.py >/dev/null 2>&1; then
		ok "scripts/validate-data.py passes"
	else
		block "scripts/validate-data.py fails. Run it for the detail."
	fi
else
	warn "python3 not found; data validation was not run"
fi

if command -v terraform >/dev/null 2>&1; then
	if terraform fmt -recursive -check . >/dev/null 2>&1; then
		ok "terraform fmt is clean"
	else
		warn "terraform fmt -recursive -check reports changes"
	fi
else
	warn "terraform not found; fmt was not run"
fi

say ""
say "=== review pipeline ========================================"

has_ci=0
[ -f .gitlab-ci.yml ] && {
	ok "GitLab pipeline present (.gitlab-ci.yml)"
	has_ci=1
}
[ -n "$(ls .github/workflows/*.yml 2>/dev/null)" ] && {
	ok "GitHub workflows present ($(ls .github/workflows/*.yml | wc -l | tr -d ' ') files)"
	has_ci=1
}
if [ "$has_ci" = 0 ]; then
	block "no pipeline. Every change would be applied by hand with no record of
        who approved it.  scripts/enable-gitops.sh"
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
	ok "this is a git working tree"
	if git remote get-url origin >/dev/null 2>&1; then
		ok "remote 'origin' is $(git remote get-url origin)"
	else
		block "no git remote. Nothing is pushed, so nothing can be reviewed."
	fi
	if [ -n "$(git status --porcelain=v1 2>/dev/null)" ]; then
		warn "working tree has uncommitted changes"
	else
		ok "working tree is clean"
	fi
	tracked_state="$(git ls-files 2>/dev/null | grep -E '\.tfstate|/tfplan$|\.tfplan$' || true)"
	if [ -n "$tracked_state" ]; then
		block "state or plan files are tracked in git: $tracked_state"
	else
		ok "no state or plan files tracked in git"
	fi
else
	block "not a git repository. There is no history of who changed a rule.
        scripts/enable-gitops.sh"
fi

say ""
say "=== cannot be checked from here ============================"
manual "branch protection on the default branch, so nobody can push to it"
manual "an approval requirement on merge/pull requests"
manual "NSX credentials for merge request plans, READ-ONLY: VAULT_ADDR with VAULT_PLAN_TOKEN, or NSX_PLAN_USERNAME / NSX_PLAN_PASSWORD (masked, not protected)"
manual "the apply credential, PROTECTED so only protected branches can apply: VAULT_APPLY_TOKEN, or NSX_APPLY_USERNAME / NSX_APPLY_PASSWORD"
manual "NSX_CA_FILE_<SITE> per manager, or NSX_CA_FILE for all (CI/CD variables of type File), when a manager's certificate is internal or self-signed"
manual "a protected environment (GitLab) or required reviewers (GitHub) on apply"
manual "a terraform plan actually run against a manager — schema validity is not API validity"

say ""
say "==========================================================="
printf 'readiness: %s blocking, %s warning(s)\n' "$blocking" "$warnings"
if [ "$blocking" -gt 0 ]; then
	say ""
	say "NOT ready for production. The BLOCK items above are the reason."
	exit 1
fi
say ""
say "No blocking items. The MANUAL list is still yours to confirm — this script"
say "cannot see your git host or your Vault."
exit 0
SCAFFOLD_EOF
mark_executable scripts/readiness.sh

write_file scripts/enable-gitops.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Put an existing tree under version control and turn on the review pipeline.
#
#   scripts/enable-gitops.sh                          # ask
#   scripts/enable-gitops.sh --remote URL             # use an existing repo
#   scripts/enable-gitops.sh --local-gitlab           # stand one up in Docker
#
# This is the migration path for a tree that was set up without versioning.
# Nothing about the Terraform changes — the pipeline files are already here,
# because bootstrap.sh always writes them. What is missing is a remote and a
# first commit, and that is all this does.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE=""
LOCAL_GITLAB=0
BRANCH="${GIT_BRANCH:-main}"
PLATFORM=gitlab   # gitlab | github | both

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--remote)
		REMOTE="${2:?--remote needs a URL}"
		shift 2
		;;
	--remote=*)
		REMOTE="${1#*=}"
		shift
		;;
	--local-gitlab)
		LOCAL_GITLAB=1
		shift
		;;
	--ci)
		PLATFORM="${2:?--ci needs gitlab, github or both}"
		shift 2
		;;
	--ci=*)
		PLATFORM="${1#*=}"
		shift
		;;
	--branch)
		BRANCH="${2:?--branch needs a name}"
		shift 2
		;;
	-h | --help)
		sed -n '2,14p' "$0"
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
done

# A tree set up as local-only has no pipeline definitions, because it asked for
# none. Adding version control without them would leave nothing to review, so
# write them first — bootstrap.sh never overwrites, so this only fills gaps.
ensure_pipeline() {
	local platform="${1:-gitlab}"
	if [ "$platform" = gitlab ] && [ -f "$REPO_ROOT/.gitlab-ci.yml" ]; then return 0; fi
	if [ "$platform" = github ] && [ -d "$REPO_ROOT/.github/workflows" ] &&
		[ -n "$(ls -A "$REPO_ROOT/.github/workflows" 2>/dev/null)" ]; then return 0; fi
	[ -x "$REPO_ROOT/scripts/bootstrap.sh" ] || {
		say "note: scripts/bootstrap.sh is missing, so the $platform pipeline could not be written."
		return 0
	}
	say "writing the $platform pipeline (none present)..."
	"$REPO_ROOT/scripts/bootstrap.sh" --dir "$REPO_ROOT" --ci "$platform" --quiet </dev/null ||
		say "note: could not write the pipeline; run scripts/bootstrap.sh --ci $platform by hand."
}

if [ "$LOCAL_GITLAB" = 1 ]; then
	ensure_pipeline gitlab
	exec "$REPO_ROOT/scripts/gitlab-up.sh"
fi

if [ -z "$REMOTE" ]; then
	if [ ! -r /dev/tty ]; then
		die "no --remote given and no terminal to ask on."
	fi
	say ""
	say "Where should these files live?"
	say ""
	say "  1) An existing git repository — I have the URL"
	say "  2) Stand up GitLab locally in Docker and create the repository"
	say "  3) Cancel"
	say ""
	printf 'Select [1]: '
	IFS= read -r choice </dev/tty || choice=""
	case "${choice:-1}" in
	1)
		printf 'Remote URL (git@host:group/repo.git or https://...): '
		IFS= read -r REMOTE </dev/tty || REMOTE=""
		[ -n "$REMOTE" ] || die "no URL given."
		printf 'Pipeline — 1) GitLab  2) GitHub  3) both [1]: '
		IFS= read -r plat </dev/tty || plat=""
		case "${plat:-1}" in
		2) PLATFORM=github ;;
		3) PLATFORM=both ;;
		*) PLATFORM=gitlab ;;
		esac
		;;
	2)
		ensure_pipeline gitlab
		exec "$REPO_ROOT/scripts/gitlab-up.sh"
		;;
	*) die "cancelled." ;;
	esac
fi

case "$PLATFORM" in
both)
	ensure_pipeline gitlab
	ensure_pipeline github
	;;
*) ensure_pipeline "$PLATFORM" ;;
esac

# --- git init, commit, remote ----------------------------------------------

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	say "initialising a git repository in $REPO_ROOT"
	git -C "$REPO_ROOT" init -q -b "$BRANCH"
fi

# .gitignore already excludes state, plans and reports. Verify rather than
# assume: committing a state file is the one mistake with no clean undo.
[ -f "$REPO_ROOT/.gitignore" ] || die ".gitignore is missing. Re-run scripts/bootstrap.sh before committing anything."
# -x, not a prefix match: '*.tfstate.*' starts with the same characters and
# would let a bare terraform.tfstate through.
grep -qx '\*\.tfstate' "$REPO_ROOT/.gitignore" || die ".gitignore does not exclude *.tfstate. Refusing to commit."

staged_state="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all |
	awk '{print $2}' | grep -E '\.tfstate|/tfplan$|\.tfplan$' || true)"
if [ -n "$staged_state" ]; then
	die "these look like state or plan files and must never be committed:
$staged_state
       Remove them, or add them to .gitignore, then re-run."
fi

if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
	git -C "$REPO_ROOT" add -A
	git -C "$REPO_ROOT" commit -q -m "Initial NSX Terraform scaffold"
	say "committed the tree."
fi

if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
	current="$(git -C "$REPO_ROOT" remote get-url origin)"
	if [ "$current" != "$REMOTE" ]; then
		say "note: 'origin' already points at $current — leaving it alone."
		say "      To change it: git remote set-url origin '$REMOTE'"
	fi
else
	git -C "$REPO_ROOT" remote add origin "$REMOTE"
	say "remote 'origin' set to $REMOTE"
fi

cat <<NEXT

Version control is on. What is left is on the git host, not here:

  1. Push:            git push -u origin $BRANCH
  2. Protect '$BRANCH' so nobody can push to it directly.
  3. Require an approval on merge requests / pull requests.
  4. Set the CI variables so the pipeline can plan:
       VAULT_ADDR, VAULT_PLAN_TOKEN (read-only),
       VAULT_APPLY_TOKEN (write, PROTECTED), CI_API_TOKEN
  5. Open a merge request with a small rule change and confirm the plan
     appears on it before trusting the pipeline with anything real.

docs/GITOPS.md is the whole flow, including who approves what.
NEXT
SCAFFOLD_EOF
mark_executable scripts/enable-gitops.sh

if wants_ci gitlab; then

write_file .gitlab/merge_request_templates/nsx-change.md <<'SCAFFOLD_EOF'
## What changed

<!-- One site or one application per merge request. One spanning several sites
     cannot be rolled back cleanly. -->

## Change class

- [ ] **Routine** — rule added/removed in an existing policy, or a member added
      to a static group
- [ ] **Elevated** — new policy or category, new or changed group criteria, new
      segment, new tag scope
- [ ] **Restricted** — default rule, Emergency category, tag scope rename or
      removal, GM/LM ownership move, anything in `platform`

Ticket:

## Plan review — read the PLAN, not the YAML

The pipeline posts a plan per manager onto this merge request.

- [ ] The resource **count delta** matches the intent
- [ ] **No unexpected destroys** — a destroy on an untouched rule means keys shifted
- [ ] No change to the **default rule** and none to the Emergency category
- [ ] Every new or changed rule has a **non-empty `scope`**
- [ ] Group criteria changes: **membership blast radius** checked in NSX *before* approval
- [ ] Sequence numbers do not collide and preserve intended ordering
- [ ] The change touches **one site's state**, unless deliberately global

## Rollback
SCAFFOLD_EOF

write_file .gitlab-ci.yml <<'SCAFFOLD_EOF'
# A rule change is a merge request, and the plan is the review artifact.
#
#   edit data/policies/*.yaml  ->  push  ->  MR
#     validate   schemas and conventions, offline, no credentials
#     plan       one job per manager, read-only credentials, posted to the MR
#     review     an approver reads the plan and approves the MR
#     merge      to the default branch
#     apply      MANUAL job, protected environment, applies the SAVED plan
#
# The apply never re-plans. It applies the artifact the approver looked at, so
# what was reviewed is what reaches the firewall.
#
# The per-manager jobs are generated from inventory/managers.yaml by a child
# pipeline, so adding an eleventh Local Manager stays a data change.
#
# Required CI/CD variables (Settings -> CI/CD -> Variables), all masked:
#   VAULT_ADDR          Vault endpoint
#   VAULT_PLAN_TOKEN    READ-ONLY. Available to every branch.
#   VAULT_APPLY_TOKEN   write. PROTECTED — protected branches and tags only.
# or the NSX credentials themselves (NSX_PLAN_*, NSX_APPLY_*). See docs/GITOPS.md.
#
# Adopting existing objects is a pipeline too: Run pipeline on the default branch
# with ADOPT_SITE (and ADOPT_POLICY) set runs only the 'adopt' job, which opens a
# merge request. docs/IMPORT.md.
#
# Mirror mode: a pipeline schedule (or Run pipeline) on the default branch with
# MIRROR_SITE set runs only the 'mirror' job, which keeps data/ a copy of the
# managers still run from the UI. docs/IMPORT.md, "Mirror mode".
#
# Cutover: Run pipeline on the default branch with CUTOVER_SITE runs only the
# 'cutover' job, which opens the merge request that takes a manager out of
# mirror mode. Drift: a schedule with DRIFT_SITE runs only the 'drift' job,
# which raises changes made in NSX as nsx-drift issues. docs/IMPORT.md.
#
# Change control (NSX_APPLY_MODE=approval): a pipeline schedule with
# APPROVAL_SWEEP=1 runs only the 'approvals' job, which starts the apply of
# every change request that has its approvals. docs/GITOPS.md.

stages:
  - adopt
  - validate
  - generate
  - plan
  - apply

default:
  # Everything a job needs is already in this image: Python, Terraform, bash,
  # curl and git. scripts/converge.sh builds it on the runner host from Docker
  # Hub images, so jobs never download packages (a locked-down network usually
  # blocks that). To use an image from your own registry instead, set the
  # CI/CD variable NSX_CI_IMAGE.
  #
  # The empty entrypoint is required. GitLab starts a job by running 'sh -c'.
  # If the image's own entrypoint is left in place and that entrypoint is
  # terraform (the hashicorp/terraform image, or an nsx-ci:1 that was tagged
  # from it), the job runs 'terraform sh' and exits 1 in a couple of seconds:
  # "Terraform has no command named sh". Every job fails the same way.
  image:
    name: $NSX_CI_IMAGE
    entrypoint: [""]
  interruptible: true

variables:
  GIT_DEPTH: "20"
  NSX_CI_IMAGE: "nsx-ci:1"

# --- adopt: bring existing NSX objects under management ---------------------
# Started by hand: Build -> Pipelines -> Run pipeline on the default branch, with
# ADOPT_SITE, and ADOPT_POLICY to adopt (without it, a survey that changes
# nothing). It reads the manager with the read-only plan credential and opens a
# merge request; it never applies and never pushes to the default branch.

adopt:
  stage: adopt
  variables:
    NSX_CRED_SCOPE: plan
    VAULT_TOKEN: $VAULT_PLAN_TOKEN
  script:
    - scripts/adopt.sh
  rules:
    - if: $ADOPT_SITE && $CI_PIPELINE_SOURCE == "web" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- mirror: keep data/ a copy of managers still run from the UI ------------
# Run from a pipeline schedule (Build -> Pipeline schedules) or Run pipeline on
# the default branch, with MIRROR_SITE (a manager in mode: mirror, or 'all').
# Reads with the read-only plan credential; keeps one merge request per manager
# up to date; never applies and never pushes to the default branch.

approvals:
  stage: adopt
  variables:
    GIT_DEPTH: "0"
  script:
    - python3 scripts/change-control.py sweep
  resource_group: nsx-approvals
  interruptible: false
  rules:
    - if: $APPROVAL_SWEEP && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule") && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

mirror:
  stage: adopt
  variables:
    NSX_CRED_SCOPE: plan
    VAULT_TOKEN: $VAULT_PLAN_TOKEN
    # Full history: drift is dated against when the copy was last merged.
    GIT_DEPTH: "0"
  script:
    - scripts/mirror.sh
  # One sync at a time, and never cancelled halfway through a push.
  resource_group: nsx-mirror
  interruptible: false
  rules:
    - if: $MIRROR_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule") && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- cutover: a manager leaves mirror mode ----------------------------------
# Run pipeline on the default branch with CUTOVER_SITE. Checks the manager still
# matches the repository, turns its copy into ordinary data files, plans it
# (must change nothing) and opens the merge request that is the cutover.

cutover:
  stage: adopt
  variables:
    NSX_CRED_SCOPE: plan
    VAULT_TOKEN: $VAULT_PLAN_TOKEN
  script:
    - scripts/cutover.sh
  # Never while a sync of the same copy runs.
  resource_group: nsx-mirror
  interruptible: false
  rules:
    - if: $CUTOVER_SITE && $CI_PIPELINE_SOURCE == "web" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- drift: changes made in NSX outside the repository -----------------------
# A pipeline schedule with DRIFT_SITE (a manager in mode: managed, or 'all').
# A refresh-only plan per manager and stack, read-only; each change found is
# raised as an nsx-drift issue. Managers in mirror mode: the mirror job does it.

drift:
  stage: adopt
  variables:
    NSX_CRED_SCOPE: plan
    VAULT_TOKEN: $VAULT_PLAN_TOKEN
  script:
    - scripts/drift-job.sh
  resource_group: nsx-drift
  interruptible: false
  rules:
    - if: $DRIFT_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule") && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- validate: offline, no credentials, runs on everything ------------------

data:
  stage: validate
  script:
    - python3 scripts/validate-data.py
  rules:
    - if: $ADOPT_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $MIRROR_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $APPROVAL_SWEEP && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CUTOVER_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $DRIFT_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

terraform:
  stage: validate
  script:
    # '|| exit $?' is deliberate. GitLab honours allow_failure:exit_codes only when
    # the job's own shell runs 'exit 42'; a command that merely returns 42 is
    # recorded as exit code 1 and the job would show as a hard failure.
    - bash scripts/ci-terraform-validate.sh || exit $?
  # Exit 42 means formatting passed but providers could not be downloaded from
  # this network, so 'validate' did not run: shown as a warning, never silent.
  allow_failure:
    exit_codes: 42
  rules:
    - if: $ADOPT_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $MIRROR_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $APPROVAL_SWEEP && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CUTOVER_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $DRIFT_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- generate: turn the inventory into per-manager jobs ---------------------

matrix:
  stage: generate
  script:
    - python3 scripts/gitlab-child-pipeline.py > generated-pipeline.yml
    - cat generated-pipeline.yml
  artifacts:
    paths: [generated-pipeline.yml]
    expire_in: 1 week
  rules:
    - if: $ADOPT_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $MIRROR_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $APPROVAL_SWEEP && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CUTOVER_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $DRIFT_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# --- plan and apply: one job per manager, from the generated pipeline -------

managers:
  stage: plan
  needs: [matrix]
  trigger:
    include:
      - artifact: generated-pipeline.yml
        job: matrix
    strategy: depend
  rules:
    - if: $ADOPT_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $MIRROR_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $APPROVAL_SWEEP && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CUTOVER_SITE && $CI_PIPELINE_SOURCE == "web"
      when: never
    - if: $DRIFT_SITE && ($CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "schedule")
      when: never
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
SCAFFOLD_EOF

write_file scripts/gitlab-child-pipeline.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Emit the per-manager half of the GitLab pipeline, from the inventory.

GitLab cannot build a job matrix out of a file at parse time, so the parent
pipeline runs this and triggers the result as a child pipeline. That is what
keeps "adding an eleventh Local Manager is a data change" true in CI as well as
in Terraform.

  scripts/gitlab-child-pipeline.py > generated-pipeline.yml

On a merge request it emits plan jobs only. On the default branch it emits plan
jobs plus a MANUAL apply job per manager, each applying the plan artifact its
own plan job produced — never a fresh one.

A manager in mirror mode (mode: mirror in the inventory) gets no apply job. On the default branch it gets an automatic sync-state job
instead, which applies its plan only if that plan just imports and refreshes,
with the read-only credential. Its plans do not hold up other managers' work:
they may fail (shown as a warning) except in its own mirror merge request.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ci_matrix_lib import entries  # noqa: E402

DEFAULT_BRANCH = os.environ.get("CI_DEFAULT_BRANCH", "main")
IS_DEFAULT_BRANCH = os.environ.get("CI_COMMIT_BRANCH") == DEFAULT_BRANCH
MR_SOURCE = os.environ.get("CI_MERGE_REQUEST_SOURCE_BRANCH_NAME", "")

# manual (default): merging queues the apply, and a human starts it with the
# plan in front of them. auto: apply runs on merge, no second pause.
#
# Set NSX_APPLY_MODE=auto in the project's CI/CD variables if the estate is a
# lab, or if the merge request approval is the only gate you want. On a
# production firewall across 10+ managers, keep it manual: an approved merge
# request says the change is wanted, not that this plan is what to apply now.
#
# approval: change control (scripts/change-control.py). The plans raise a Change
# Request issue; once it has its approvals, ONE 'approve and apply' job applies
# every manager's plan and records the result. GitLab Community Edition has no
# enforced approval rules, so the rules are enforced here and in that job.
APPLY_MODE = os.environ.get("NSX_APPLY_MODE", "manual").strip().lower()
if APPLY_MODE not in ("manual", "auto", "approval"):
    sys.exit(f"error: NSX_APPLY_MODE must be 'manual', 'auto' or 'approval', got {APPLY_MODE!r}")


def job_name(prefix: str, row: dict) -> str:
    return f"{prefix} {row['stack']} @ {row['site']}"


def image_block(indent: str = "  ") -> list[str]:
    # Empty entrypoint: see .gitlab-ci.yml. Without it a terraform entrypoint
    # turns every job into 'terraform sh', which exits 1 immediately.
    name = os.environ.get("NSX_CI_IMAGE", "nsx-ci:1")
    return [
        f"{indent}image:",
        f"{indent}  name: {name}",
        f'{indent}  entrypoint: [""]',
    ]


def main() -> int:
    rows = entries(None)
    if not rows:
        # An empty inventory must not fail the pipeline: a fresh repository has
        # no managers yet, and there is nothing to plan.
        print("workflow:\n  rules:\n    - when: always\n")
        print("no-managers:")
        print("  stage: plan")
        print("\n".join(image_block("  ")))
        print("  script:")
        print('    - echo "inventory/managers.yaml lists no enabled managers; nothing to plan."')
        return 0

    out: list[str] = []
    out.append("stages: [plan, review, apply]")
    out.append("")
    # A child of a merge request pipeline is itself a merge request pipeline.
    # Jobs with no rules default to 'only: branches, tags', which GitLab leaves
    # out of one, so without this every job is filtered and the trigger fails
    # with "the resulting pipeline would have been empty".
    out.append("workflow:")
    out.append("  rules:")
    out.append("    - when: always")
    out.append("")
    out.append("default:")
    # The same image as the parent pipeline, where it is a CI/CD variable.
    out.extend(image_block("  "))
    out.append("")

    for row in rows:
        plan = job_name("plan", row)
        out.append(f'"{plan}":')
        out.append("  stage: plan")
        out.append("  variables:")
        out.append(f'    SITE: "{row["site"]}"')
        out.append(f'    STACK: "{row["stack"]}"')
        out.append("    VAULT_TOKEN: $VAULT_PLAN_TOKEN")
        out.append("    NSX_CRED_SCOPE: plan")
        out.append("  script:")
        out.append('    - scripts/with-credentials.sh "$SITE" -- scripts/tf.sh plan "$STACK" "$SITE"')
        out.append('    - scripts/tf.sh show "$STACK" "$SITE" | tee "plan-$STACK-$SITE.txt"')
        out.append("    - scripts/post-plan-comment.sh \"$STACK\" \"$SITE\" \"plan-$STACK-$SITE.txt\"")
        # A copy under the manager's name: a job that takes several plans (the
        # change control's) would otherwise get one stack's plan per stack.
        out.append('    - mkdir -p "plans/$SITE/$STACK" && cp "stacks/$STACK/tfplan" "stacks/$STACK/tfplan.site" "plans/$SITE/$STACK/"')
        out.append("  artifacts:")
        out.append("    name: \"plan-$STACK-$SITE\"")
        out.append("    paths:")
        out.append(f'      - stacks/{row["stack"]}/tfplan')
        out.append(f'      - stacks/{row["stack"]}/tfplan.site')
        out.append(f'      - plans/{row["site"]}/{row["stack"]}/')
        out.append('      - "plan-$STACK-$SITE.txt"')
        out.append("    expire_in: 1 week")
        out.append("    when: always")
        # A failed plan at one site must not hide the others. A manager in
        # mirror mode is the exception: it changes in the UI between syncs, and
        # that must not block other managers' merge requests. Its own mirror
        # merge request is held to a clean plan.
        mirror = row.get("mode") == "mirror"
        lenient = mirror and MR_SOURCE != f"mirror/{row['site']}"
        out.append(f"  allow_failure: {'true' if lenient else 'false'}")
        out.append("")

        if not IS_DEFAULT_BRANCH:
            continue
        if mirror:
            # Still run from the UI: nothing is applied to it. Its state follows
            # NSX instead: this plan is applied only if it just imports and
            # refreshes (plan-guard --observe), with the read-only credential,
            # so it cannot write to NSX. Automatic, as it changes nothing.
            sync = job_name("sync-state", row)
            out.append(f'"{sync}":')
            out.append("  stage: apply")
            out.append("  needs:")
            out.append(f'    - job: "{plan}"')
            out.append("      artifacts: true")
            out.append("  allow_failure: true")
            out.append(f"  resource_group: nsx-state-{row['site']}-{row['stack']}")
            out.append("  variables:")
            out.append(f'    SITE: "{row["site"]}"')
            out.append(f'    STACK: "{row["stack"]}"')
            out.append("    VAULT_TOKEN: $VAULT_PLAN_TOKEN")
            out.append("    NSX_CRED_SCOPE: plan")
            out.append("    APPROVE: \"yes\"")
            out.append("  script:")
            out.append('    - test -f "stacks/$STACK/tfplan" || { echo "no saved plan, as its plan job failed; the next sync tries again" >&2; exit 1; }')
            out.append('    - scripts/with-credentials.sh "$SITE" -- scripts/tf.sh apply "$STACK" "$SITE"')
            out.append("")
            continue
        if APPLY_MODE == "approval":
            continue  # applied by the one 'approve and apply' job, below

        apply_job = job_name("apply", row)
        out.append(f'"{apply_job}":')
        out.append("  stage: apply")
        out.append("  needs:")
        out.append(f'    - job: "{plan}"')
        out.append("      artifacts: true")
        # The gate. A manual job will not start without a human, and a
        # protected environment restricts who that human can be.
        if APPLY_MODE == "manual":
            out.append("  when: manual")
            # Not blocking: the pipeline ends 'passed' with the apply waiting for
            # its button, instead of sitting 'blocked' until someone runs or
            # cancels it. The gate is the same; an apply that is run and fails
            # shows as a warning on the pipeline and as failed on the job.
            out.append("  allow_failure: true")
        else:
            out.append("  when: on_success")
            out.append("  allow_failure: false")
        out.append("  environment:")
        out.append(f'    name: nsx/{row["site"]}/{row["stack"]}')
        out.append("  variables:")
        out.append(f'    SITE: "{row["site"]}"')
        out.append(f'    STACK: "{row["stack"]}"')
        out.append("    VAULT_TOKEN: $VAULT_APPLY_TOKEN")
        out.append("    NSX_CRED_SCOPE: apply")
        out.append("    APPROVE: \"yes\"")
        out.append("  script:")
        # tf.sh refuses without a saved plan, so this cannot silently re-plan.
        out.append('    - test -f "stacks/$STACK/tfplan" || { echo "no saved plan artifact; re-run the plan job" >&2; exit 1; }')
        out.append('    - scripts/with-credentials.sh "$SITE" -- scripts/tf.sh apply "$STACK" "$SITE"')
        out.append("")

    managed = [r for r in rows if r.get("mode") != "mirror"]
    if APPLY_MODE == "approval" and IS_DEFAULT_BRANCH and managed:
        # GitLab allows 50 entries in needs; one change request takes them all.
        if len(managed) + 1 > 50:
            sys.exit(f"error: {len(managed)} manager stacks: change control needs one job to take every plan, "
                     "and GitLab allows 50. Split the inventory, or use NSX_APPLY_MODE=manual.")
        plans = [job_name("plan", r) for r in managed]
        out.append('"change request":')
        out.append("  stage: review")
        out.append("  needs:")
        for p in plans:
            out.append(f'    - job: "{p}"')
            out.append("      artifacts: true")
        out.append("  variables:")
        # Full history: every merge since the last applied change is checked.
        out.append('    GIT_DEPTH: "0"')
        out.append("  script:")
        out.append("    - python3 scripts/change-control.py open")
        out.append("  artifacts:")
        out.append("    reports:")
        out.append("      dotenv: change.env")
        out.append("")
        out.append(f'"{"approve and apply"}":')
        out.append("  stage: apply")
        out.append("  needs:")
        out.append('    - job: "change request"')
        out.append("      artifacts: true")
        for p in plans:
            out.append(f'    - job: "{p}"')
            out.append("      artifacts: true")
        # Started by a Maintainer, or by the approvals sweep once the change
        # request has its approvals. Either way the job checks them itself
        # before applying anything. Not blocking: the pipeline ends 'passed'
        # while the change waits for its approvals.
        out.append("  when: manual")
        out.append("  allow_failure: true")
        out.append("  resource_group: nsx-apply")
        out.append("  variables:")
        out.append('    GIT_DEPTH: "0"')
        out.append("    VAULT_TOKEN: $VAULT_APPLY_TOKEN")
        out.append("    NSX_CRED_SCOPE: apply")
        out.append("    APPROVE: \"yes\"")
        out.append("  script:")
        out.append("    - scripts/approve-apply.sh")
        out.append("")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/gitlab-child-pipeline.py

write_file scripts/change-control.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Change control on GitLab Community Edition: who may apply a change to NSX,
and a record of every one that was.

With NSX_APPLY_MODE=approval a change reaches NSX like this:

  1. A merge request passes its checks (format, validation, plans) and is
     merged into the default branch by another engineer: whoever merges it, or
     approves it, must not be its author.
  2. On the default branch every manager is planned, then 'open' raises a
     Change Request issue: what each plan changes, the merge requests in it, and
     who wrote and reviewed each one.
  3. Approvers give the issue a thumbs-up. It needs NSX_REQUIRED_APPROVALS of
     them (default 2), each from a Maintainer, or from an engineer a Maintainer
     has handed their approval to for a period (inventory/delegations.yaml);
     never from the author of a change in it.
  4. The 'approve and apply' job applies every manager's saved plan. A
     Maintainer can start it, or 'sweep' (a scheduled job) starts it once the
     approvals are in. 'gate' checks all of the above again first, whoever
     started it, so the button alone approves nothing.
  5. 'record' writes the result on the issue, closes it, and adds a line to the
     wiki page "NSX Change Log".

  scripts/change-control.py open                                 job 'change request'
  scripts/change-control.py gate                                 start of 'approve and apply'
  scripts/change-control.py record --result ok|failed --log FILE end of 'approve and apply'
  scripts/change-control.py sweep                                job 'approvals', scheduled

A newer change supersedes an older one still waiting: the newer plan already
holds every change on the branch, so the older issue is closed and its
approvals do not carry over.

Needs NSX_BOT_TOKEN (or NSX_ADOPT_TOKEN): a project access token with the api
scope and the Maintainer role. Exit status: 0 done or approved, 2 refused,
3 nothing to approve, 1 error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ci_matrix_lib import entries  # noqa: E402
from yamlcompat import load_yaml  # noqa: E402

LABEL = "nsx-change"
AWAITING = "nsx-awaiting-approval"
APPLYING = "nsx-applying"
APPLIED = "nsx-applied"
FAILED = "nsx-apply-failed"
SUPERSEDED = "nsx-superseded"
BLOCKED = "nsx-blocked"
WIKI_SLUG = "NSX-Change-Log"
WIKI_TITLE = "NSX Change Log"
APPROVE_JOB = "approve and apply"
MAINTAINER = 40
DEVELOPER = 30
MARK = re.compile(r"<!-- nsx-change pipeline=(\d+) sha=([0-9a-f]{7,40}) -->")
BOT = re.compile(r"^(project|group)_\d+_bot")
DELEGATIONS = REPO_ROOT / "inventory" / "delegations.yaml"
STATE = REPO_ROOT / "change-approvals.json"
PLAN_LINES = 300


def die(message: str, code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


class GitLab:
    """The few calls this needs, with the token in a header and GitLab's CA."""

    def __init__(self) -> None:
        self.api = os.environ.get("CI_API_V4_URL", "").rstrip("/")
        self.project = os.environ.get("CI_PROJECT_ID", "")
        self.token = os.environ.get("NSX_BOT_TOKEN") or os.environ.get("NSX_ADOPT_TOKEN") or ""
        if not (self.api and self.project):
            die("CI_API_V4_URL and CI_PROJECT_ID are not set: this runs in a GitLab job")
        if not self.token:
            die("NSX_BOT_TOKEN is not set: a project access token, role Maintainer, scope api, masked and protected")
        ca = os.environ.get("CI_SERVER_TLS_CA_FILE")
        self.ctx = ssl.create_default_context(cafile=ca) if ca and Path(ca).is_file() else ssl.create_default_context()
        # An internal CA without keyUsage is fine for GitLab's runner and git;
        # Python 3.13's strict checks would refuse it. Chain and name still checked.
        self.ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)

    def call(self, method: str, path: str, body: dict | None = None, query: dict | None = None,
             missing_ok: bool = False):
        url = f"{self.api}/projects/{urllib.parse.quote(self.project, safe='')}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query, doseq=True)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("PRIVATE-TOKEN", self.token)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, context=self.ctx, timeout=60) as response:
                text = response.read().decode() or "null"
                return json.loads(text), response.headers
        except urllib.error.HTTPError as exc:
            if missing_ok and exc.code == 404:
                return None, exc.headers
            detail = exc.read().decode(errors="replace")[:300]
            die(f"GitLab API {method} {path}: HTTP {exc.code} {detail}")
        except urllib.error.URLError as exc:
            die(f"GitLab API {method} {path}: {exc.reason}")

    def get(self, path: str, query: dict | None = None, missing_ok: bool = False):
        return self.call("GET", path, query=query, missing_ok=missing_ok)[0]

    def get_all(self, path: str, query: dict | None = None) -> list:
        out: list = []
        page = "1"
        while page:
            data, headers = self.call("GET", path, query=dict(query or {}, per_page=100, page=page))
            out.extend(data or [])
            page = (headers.get("X-Next-Page") or "").strip()
        return out

    def note(self, iid: int, body: str) -> None:
        self.call("POST", f"/issues/{iid}/notes", {"body": body})

    def labels(self, iid: int, *names: str, close: bool = False) -> None:
        body: dict = {"labels": ",".join((LABEL,) + names)}
        if close:
            body["state_event"] = "close"
        self.call("PUT", f"/issues/{iid}", body)


# --- who may approve ---------------------------------------------------------

def members(gl: GitLab) -> dict[str, int]:
    """username -> access level, inherited membership included; bots left out."""
    return {m["username"]: int(m.get("access_level", 0)) for m in gl.get_all("/members/all")
            if not BOT.match(m.get("username", ""))}


def as_date(value) -> date:
    """A YAML date as any reader gives it: a date (PyYAML), or a string, with a
    time (Terraform's yamldecode: 2026-11-01T00:00:00Z) or without."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value)
    if not re.match(r"^\d{4}-\d{2}-\d{2}(T00:00:00(Z|[+-]00:00)?)?$", text):
        raise ValueError(text)
    return date.fromisoformat(text[:10])


def delegations(today: date) -> list[dict]:
    """The standby approvals in force today: a Maintainer's approval handed to
    another engineer until a date (inclusive, UTC)."""
    if not DELEGATIONS.exists():
        return []
    doc = load_yaml(DELEGATIONS.read_text()) or {}
    active = []
    for d in doc.get("delegations") or []:
        try:
            until = as_date(d.get("until"))
        except ValueError:
            continue
        if d.get("from") and d.get("to") and today <= until:
            active.append({"from": str(d["from"]), "to": str(d["to"]), "until": until.isoformat()})
    return active


def principal(user: str, authors: set[str], levels: dict[str, int], standby: list[dict]) -> tuple[str | None, str]:
    """Whose approval a thumbs-up from user counts as, and why or why not."""
    if user in authors:
        return None, "an author of a change in it"
    if levels.get(user, 0) >= MAINTAINER:
        return user, "Maintainer"
    for d in standby:
        if d["to"] != user:
            continue
        if d["from"] in authors:
            continue
        if levels.get(d["from"], 0) >= MAINTAINER and levels.get(user, 0) >= DEVELOPER:
            return d["from"], f"standing in for {d['from']} until {d['until']}"
    return None, "not a Maintainer, and no standby approval in force"


def approvals(gl: GitLab, iid: int, authors: set[str]) -> tuple[list[tuple[str, str, str]], list[tuple[str, str]]]:
    """(accepted: user, counts as, why), (not counted: user, why). Each person
    counts once, and a stand-in and the Maintainer they stand in for count once
    between them."""
    levels = members(gl)
    standby = delegations(datetime.now(timezone.utc).date())
    accepted: list[tuple[str, str, str]] = []
    rejected: list[tuple[str, str]] = []
    seen: set[str] = set()
    for emoji in gl.get_all(f"/issues/{iid}/award_emoji"):
        if emoji.get("name") not in ("thumbsup", "+1"):
            continue
        user = (emoji.get("user") or {}).get("username", "")
        who, why = principal(user, authors, levels, standby)
        if who is None:
            rejected.append((user, why))
        elif who in seen:
            rejected.append((user, f"counts as {who}, who is counted already"))
        else:
            seen.add(who)
            accepted.append((user, who, why))
    return accepted, rejected


def required() -> int:
    try:
        n = int(os.environ.get("NSX_REQUIRED_APPROVALS", "2"))
    except ValueError:
        die("NSX_REQUIRED_APPROVALS must be a whole number")
    if n < 1:
        die("NSX_REQUIRED_APPROVALS must be at least 1")
    return n


# --- what is in the change, and was it reviewed --------------------------------

def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True, check=False).stdout.strip()


def last_applied(gl: GitLab) -> str | None:
    found = gl.get("/issues", {"labels": f"{LABEL},{APPLIED}", "state": "closed",
                               "order_by": "updated_at", "sort": "desc", "per_page": 1}) or []
    for issue in found:
        mark = MARK.search(issue.get("description") or "")
        if mark:
            return mark.group(2)
    return None


def commits_since(last: str | None, head: str) -> list[str]:
    """The default branch's own commits since the last applied change, oldest
    first. Without that history (first change, or rewritten), just this one."""
    if last and subprocess.run(["git", "merge-base", "--is-ancestor", last, head], cwd=REPO_ROOT,
                               capture_output=True).returncode == 0:
        listed = git("log", "--first-parent", "--reverse", "--format=%H", f"{last}..{head}").split()
        if listed:
            return listed
    return [head]


def review(gl: GitLab, head: str) -> tuple[list[dict], list[str]]:
    """Every merge request in this change, and what breaks the rule that another
    engineer reviewed each: merged it, or approved it."""
    branch = os.environ.get("CI_DEFAULT_BRANCH", "main")
    changes: dict[int, dict] = {}
    problems: list[str] = []
    for sha in commits_since(last_applied(gl), head):
        merged = [m for m in gl.get(f"/repository/commits/{sha}/merge_requests") or []
                  if m.get("state") == "merged" and m.get("target_branch", branch) == branch]
        if not merged:
            problems.append(f"commit {sha[:8]} reached {branch} without a merge request")
            continue
        mr = merged[0]
        if mr["iid"] in changes:
            continue
        author = (mr.get("author") or {}).get("username", "")
        merger = (mr.get("merge_user") or mr.get("merged_by") or {}).get("username")
        approved = gl.get(f"/merge_requests/{mr['iid']}/approvals") or {}
        approvers = [(a.get("user") or {}).get("username") for a in approved.get("approved_by") or []]
        reviewers = sorted({u for u in [merger, *approvers] if u and u != author})
        changes[mr["iid"]] = {"iid": mr["iid"], "title": mr.get("title", ""), "url": mr.get("web_url", ""),
                              "author": author, "reviewers": reviewers}
        if not reviewers:
            problems.append(f"!{mr['iid']} ({mr.get('title', '')}) was merged by its author {author}, "
                            "and no other engineer approved it")
    return list(changes.values()), problems


# --- the plans ---------------------------------------------------------------

def plan_summary(text: str | None) -> tuple[str, bool]:
    """(what the plan says, whether applying it changes anything)."""
    if text is None:
        return "no plan (its job did not produce one)", False
    for line in text.splitlines():
        if line.startswith("Plan:"):
            return line.strip(), True
        if line.startswith("No changes"):
            return "No changes.", False
    return "only output values change", False


def targets() -> list[dict]:
    """Managers this change control applies to: not those in mirror mode, whose
    state follows NSX on its own."""
    return [r for r in entries(None) if r["mode"] != "mirror"]


def plans() -> list[tuple[dict, str, bool, str | None]]:
    out = []
    for row in targets():
        path = REPO_ROOT / f"plan-{row['stack']}-{row['site']}.txt"
        text = path.read_text() if path.exists() else None
        summary, changes = plan_summary(text)
        out.append((row, summary, changes, text))
    return out


# --- commands ----------------------------------------------------------------

def mention(users) -> str:
    return ", ".join(f"@{u}" for u in users) or "nobody"


def cmd_open(gl: GitLab) -> int:
    pipeline = os.environ.get("CI_PIPELINE_ID", "")
    head = os.environ.get("CI_COMMIT_SHA") or git("rev-parse", "HEAD")
    dotenv = REPO_ROOT / "change.env"
    found = plans()
    if not any(changes for _, _, changes, _ in found):
        dotenv.write_text("CHANGE_ISSUE=\n")
        print("Nothing to approve: no plan changes anything in NSX.")
        return 0

    # A newer change holds every older one still waiting: close those.
    for issue in gl.get_all("/issues", {"labels": LABEL, "state": "opened"}):
        mark = MARK.search(issue.get("description") or "")
        if mark and mark.group(1) != pipeline and APPLYING not in issue.get("labels", []):
            gl.note(issue["iid"], f"Superseded: the default branch has moved on, and the change request for "
                                   f"pipeline {pipeline} holds this change too. Approve that one instead.")
            gl.labels(issue["iid"], SUPERSEDED, close=True)

    changes, problems = review(gl, head)
    authors = sorted({c["author"] for c in changes})
    title_parts = [c["title"] for c in changes] or [f"default branch at {head[:8]}"]
    title = "NSX change: " + "; ".join(title_parts)
    if len(title) > 200:
        title = title[:197] + "..."

    lines = [f"<!-- nsx-change pipeline={pipeline} sha={head} -->",
             f"**Change Request** for `{head[:8]}` on `{os.environ.get('CI_DEFAULT_BRANCH', 'main')}`"
             f" ([pipeline]({os.environ.get('CI_PIPELINE_URL', '')})).", "",
             "### What changes in NSX", "", "| Manager | Stack | Plan |", "|---|---|---|"]
    for row, summary, _, _ in found:
        lines.append(f"| {row['site']} | {row['stack']} | {summary} |")
    lines += ["", "### Merge requests in it", "", "| | Title | Author | Reviewed by |", "|---|---|---|---|"]
    for c in changes:
        lines.append(f"| [!{c['iid']}]({c['url']}) | {c['title']} | @{c['author']} | {mention(c['reviewers'])} |")
    if problems:
        lines += ["", "### Blocked: not every change was reviewed", ""]
        lines += [f"- {p}" for p in problems]
        lines += ["", "Nothing here can be applied. Revert the change, or open a merge request that another "
                      "engineer reviews; the next change request on the default branch replaces this one."]
    else:
        lines += ["", "### Approve", "",
                  f"Give this issue a :thumbsup:. It needs **{required()}** approval(s), each from a Maintainer, "
                  "or from an engineer standing in for one (`inventory/delegations.yaml`), and never from an author "
                  f"of a change in it ({mention(authors)}).", "",
                  f"Then the **{APPROVE_JOB}** job in the pipeline applies it: a Maintainer can start it, or the "
                  "approvals schedule starts it within minutes. The approvals are checked again before anything "
                  "is applied."]
    lines += ["", "### Plans", ""]
    for row, summary, _, text in found:
        body = (text or "").splitlines()
        shown = body[:PLAN_LINES]
        more = f"\n... {len(body) - PLAN_LINES} more line(s) in the plan job's log" if len(body) > PLAN_LINES else ""
        lines += [f"<details><summary>{row['site']} / {row['stack']}: {summary}</summary>", "", "```",
                  *shown, "```" + more, "", "</details>", ""]

    issue, _ = gl.call("POST", "/issues", {"title": title, "description": "\n".join(lines),
                                           "labels": ",".join((LABEL, BLOCKED if problems else AWAITING))})
    dotenv.write_text(f"CHANGE_ISSUE={issue['iid']}\n")
    print(f"change request: {issue.get('web_url', issue['iid'])}")
    if problems:
        print("BLOCKED: not every change was reviewed by another engineer:")
        for p in problems:
            print(f"  - {p}")
        return 2
    return 0


def check(gl: GitLab, iid: int, pipeline: str | None) -> tuple[dict, list[dict], list[tuple[str, str, str]], list[tuple[str, str]], list[str]]:
    """Everything that must hold before an apply. Returns the issue, its changes,
    the approvals counted and not, and what refuses it (empty when it may go)."""
    issue = gl.get(f"/issues/{iid}")
    mark = MARK.search(issue.get("description") or "")
    refusals: list[str] = []
    if not mark:
        die(f"issue #{iid} is not a change request")
    if pipeline and mark.group(1) != str(pipeline):
        refusals.append(f"issue #{iid} is the change request of pipeline {mark.group(1)}, not this one")
    labels = set(issue.get("labels") or [])
    if issue.get("state") != "opened" or labels & {SUPERSEDED, BLOCKED, APPLIED}:
        refusals.append(f"change request #{iid} is {issue.get('state')} ({', '.join(sorted(labels)) or 'no labels'})")
    changes, problems = review(gl, mark.group(2))
    refusals += problems
    authors = {c["author"] for c in changes}
    accepted, rejected = approvals(gl, iid, authors)
    need = required()
    if len(accepted) < need:
        refusals.append(f"{len(accepted)} of {need} approval(s)")
    return issue, changes, accepted, rejected, refusals


def show_approvals(accepted, rejected) -> None:
    for user, who, why in accepted:
        print(f"  counted      @{user} ({why})")
    for user, why in rejected:
        print(f"  not counted  @{user}: {why}")


def cmd_gate(gl: GitLab) -> int:
    iid = os.environ.get("CHANGE_ISSUE", "").strip()
    if not iid:
        print("Nothing to approve: no plan in this pipeline changes anything in NSX.")
        return 3
    issue, changes, accepted, rejected, refusals = check(gl, int(iid), os.environ.get("CI_PIPELINE_ID"))
    print(f"change request #{iid}: {issue.get('title', '')}")
    show_approvals(accepted, rejected)
    if refusals:
        print("REFUSED:")
        for r in refusals:
            print(f"  - {r}")
        return 2
    STATE.write_text(json.dumps({"issue": int(iid), "changes": changes,
                                 "approved": [{"user": u, "as": w, "why": y} for u, w, y in accepted]}))
    gl.labels(int(iid), APPLYING)
    gl.note(int(iid), f"Approved by {mention(u for u, _, _ in accepted)}. Applying: {os.environ.get('CI_JOB_URL', 'this pipeline')}")
    print("approved: applying.")
    return 0


def cmd_record(gl: GitLab, result: str, log: Path) -> int:
    if not STATE.exists():
        die("nothing to record: the gate did not approve this job")
    state = json.loads(STATE.read_text())
    iid = state["issue"]
    text = log.read_text() if log.exists() else ""
    rows, target = [], None
    for line in text.splitlines():
        if line.startswith("== "):
            target = line[3:].strip()
            if target.endswith("no changes, skipped"):
                rows.append((target.split(":")[0], "no changes, skipped"))
                target = None
        elif target and ("Apply complete!" in line or line.startswith("Error:") or "refusing to apply" in line):
            rows.append((target, line.strip()))
            target = None
    if target:
        rows.append((target, "did not finish"))
    job = os.environ.get("CI_JOB_URL", "")
    approved = state["approved"]
    who = ", ".join(f"@{a['user']}" + (f" (for @{a['as']})" if a["as"] != a["user"] else "") for a in approved)
    body = [f"**{'Applied' if result == 'ok' else 'Apply FAILED'}** by [{APPROVE_JOB}]({job}). Approved by {who}.", "",
            "| Target | Result |", "|---|---|", *(f"| {t} | {r} |" for t, r in rows)]
    if result != "ok":
        tail = text.splitlines()[-40:]
        body += ["", "Last lines of the apply:", "```", *tail, "```", "",
                 "The issue stays open. Fix the cause in a merge request; its change request replaces this one."]
    gl.note(iid, "\n".join(body))
    if result == "ok":
        gl.labels(iid, APPLIED, close=True)
    else:
        gl.labels(iid, FAILED)

    # The change log: one line per change, newest last.
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    issue_url = gl.get(f"/issues/{iid}").get("web_url", "")
    changes = state["changes"]
    mrs = ", ".join("!" + str(c["iid"]) for c in changes) or "-"
    row = (f"| {stamp} | [#{iid}]({issue_url}) | {mrs} "
           f"| {mention(sorted({c['author'] for c in changes}))} "
           f"| {mention(sorted({r for c in changes for r in c['reviewers']}))} | {who} "
           f"| {'applied' if result == 'ok' else 'FAILED'} | [job]({job}) |")
    page = gl.get(f"/wikis/{WIKI_SLUG}", missing_ok=True)
    if page is None:
        content = "\n".join([f"# {WIKI_TITLE}", "",
                             "Every change applied to NSX through the pipeline, written by scripts/change-control.py.", "",
                             "| When | Change request | Merge requests | Authors | Reviewed by | Approved by | Result | Job |",
                             "|---|---|---|---|---|---|---|---|", row, ""])
        gl.call("POST", "/wikis", {"title": WIKI_TITLE, "content": content})
    else:
        gl.call("PUT", f"/wikis/{WIKI_SLUG}", {"title": WIKI_TITLE, "content": page["content"].rstrip("\n") + "\n" + row + "\n"})
    print(f"recorded on #{iid} and in the wiki page {WIKI_TITLE}.")
    return 0


def cmd_sweep(gl: GitLab) -> int:
    started = 0
    for issue in gl.get_all("/issues", {"labels": f"{LABEL},{AWAITING}", "state": "opened"}):
        iid = issue["iid"]
        mark = MARK.search(issue.get("description") or "")
        if not mark:
            continue
        _, _, accepted, rejected, refusals = check(gl, iid, None)
        if refusals:
            print(f"#{iid}: waiting ({'; '.join(refusals)})")
            continue
        jobs = gl.get_all(f"/pipelines/{mark.group(1)}/jobs", {"scope[]": "manual"})
        job = next((j for j in jobs if j.get("name") == APPROVE_JOB), None)
        if not job:
            print(f"#{iid}: approved, but pipeline {mark.group(1)} has no '{APPROVE_JOB}' job waiting")
            continue
        gl.labels(iid, APPLYING)
        played, _ = gl.call("POST", f"/jobs/{job['id']}/play")
        gl.note(iid, f"Approvals complete ({mention(u for u, _, _ in accepted)}): started "
                     f"[{APPROVE_JOB}]({(played or {}).get('web_url', job.get('web_url', ''))}).")
        print(f"#{iid}: approved, apply started")
        started += 1
    print(f"{started} change(s) started.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("open")
    sub.add_parser("gate")
    rec = sub.add_parser("record")
    rec.add_argument("--result", choices=["ok", "failed"], required=True)
    rec.add_argument("--log", type=Path, required=True)
    sub.add_parser("sweep")
    args = ap.parse_args()
    gl = GitLab()
    if args.command == "open":
        return cmd_open(gl)
    if args.command == "gate":
        return cmd_gate(gl)
    if args.command == "record":
        return cmd_record(gl, args.result, args.log)
    return cmd_sweep(gl)


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/change-control.py

write_file scripts/approve-apply.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# The 'approve and apply' job of NSX_APPLY_MODE=approval: one per change.
#
#   scripts/approve-apply.sh
#
# 1. scripts/change-control.py gate: the change request has its approvals and
#    every change in it was reviewed. Whoever started this job, nothing below
#    runs otherwise.
# 2. Each manager's saved plan, in inventory order, through scripts/tf.sh apply
#    (which runs plan-guard again). A manager whose plan changes nothing is
#    skipped. The first failure stops the rest.
# 3. scripts/change-control.py record: the result on the change request, and a
#    line in the wiki change log, whether it worked or not.
#
# Plans arrive as artifacts under plans/<site>/<stack>/, so two managers that
# share a stack keep their own plan.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

python3 scripts/change-control.py gate
rc=$?
[ "$rc" -eq 3 ] && exit 0
[ "$rc" -eq 0 ] || exit "$rc"

log="$REPO_ROOT/apply.log"
: >"$log"
status=ok
while read -r site stack _; do
	[ -n "$site" ] || continue
	text="plan-$stack-$site.txt"
	if ! grep -q '^Plan:' "$text" 2>/dev/null; then
		echo "== $site/$stack: no changes, skipped" | tee -a "$log"
		continue
	fi
	echo "== $site/$stack" | tee -a "$log"
	if ! cp "plans/$site/$stack/tfplan" "plans/$site/$stack/tfplan.site" "stacks/$stack/" 2>>"$log"; then
		echo "error: no saved plan for $site/$stack in this pipeline" | tee -a "$log"
		status=failed
		break
	fi
	if ! scripts/with-credentials.sh "$site" -- scripts/tf.sh apply "$stack" "$site" 2>&1 | tee -a "$log"; then
		status=failed
		break
	fi
done < <(python3 scripts/ci-matrix.py --format lines --managed-only)

if ! python3 scripts/change-control.py record --result "$status" --log "$log"; then
	echo "error: the result could not be recorded on the change request; record it by hand." >&2
	exit 1
fi
[ "$status" = ok ]
SCAFFOLD_EOF
mark_executable scripts/approve-apply.sh

fi # wants_ci gitlab

write_file scripts/post-plan-comment.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Post a rendered plan onto the merge request or pull request, so the approver
# reads the plan in the review rather than digging through job logs.
#
#   scripts/post-plan-comment.sh <stack> <site> <rendered-plan-file>
#
# Works on GitLab and on GitHub Actions, detected from the environment, so the
# two platforms cannot drift apart in what a reviewer sees.
#
# Never posts the plan FILE — that is a sensitive artifact. It posts the
# rendered text, truncated, which is what a human needs to decide.
#
# A no-op outside a merge/pull request, or without a token. Safe to call
# unconditionally: a missing token must not fail the plan.

set -euo pipefail

stack="${1:?stack}"
site="${2:?site}"
plan_file="${3:?rendered plan file}"

[ -f "$plan_file" ] || {
	echo "no rendered plan at $plan_file; nothing to post."
	exit 0
}

# GitLab rejects very large notes, and nobody reads 4000 lines of plan anyway.
max_lines="${PLAN_COMMENT_MAX_LINES:-300}"
total="$(wc -l <"$plan_file" | tr -d ' ')"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

{
	printf '### Terraform plan — `%s` @ `%s`\n\n' "$stack" "$site"
	if grep -qE '^(Plan:|No changes)' "$plan_file"; then
		printf '**%s**\n\n' "$(grep -E '^(Plan:|No changes)' "$plan_file" | head -1)"
	fi
	printf '<details><summary>plan output (%s lines)</summary>\n\n```\n' "$total"
	head -n "$max_lines" "$plan_file"
	if [ "$total" -gt "$max_lines" ]; then
		printf '\n... truncated at %s lines. Full output in the job log.\n' "$max_lines"
	fi
	printf '```\n\n</details>\n\n'
	printf 'Reviewer checklist:\n\n'
	printf -- '- [ ] resource count delta matches the intent\n'
	printf -- '- [ ] no unexpected destroys\n'
	printf -- '- [ ] no change to the default rule or the Emergency category\n'
	printf -- '- [ ] every new or changed rule has a non-empty scope\n'
} >"$body_file"

post_gitlab() {
	[ -n "${CI_API_TOKEN:-}" ] || {
		echo "CI_API_TOKEN is not set; skipping the plan comment. Set it to post plans to the MR."
		return 0
	}
	curl --silent --show-error --fail-with-body --max-time 60 \
		${CI_SERVER_TLS_CA_FILE:+--cacert "$CI_SERVER_TLS_CA_FILE"} \
		--header "PRIVATE-TOKEN: ${CI_API_TOKEN}" \
		--data-urlencode "body@$body_file" \
		--request POST \
		"${CI_API_V4_URL:?}/projects/${CI_PROJECT_ID:?}/merge_requests/${CI_MERGE_REQUEST_IID}/notes" >/dev/null &&
		echo "posted the plan for $stack @ $site to merge request !${CI_MERGE_REQUEST_IID}"
}

post_github() {
	local token="${GITHUB_TOKEN:-}"
	[ -n "$token" ] || {
		echo "GITHUB_TOKEN is not set; skipping the plan comment."
		return 0
	}
	local pr
	pr="$(python3 -c "
import json, os, sys
p = os.environ.get('GITHUB_EVENT_PATH')
if not p or not os.path.exists(p):
    sys.exit(0)
with open(p) as f:
    ev = json.load(f)
n = (ev.get('pull_request') or {}).get('number') or (ev.get('issue') or {}).get('number')
print(n or '')
" 2>/dev/null || true)"
	[ -n "$pr" ] || {
		echo "not a pull request event; skipping the plan comment."
		return 0
	}
	# jq is not guaranteed on a runner; python is.
	python3 -c "
import json, sys
print(json.dumps({'body': open(sys.argv[1]).read()}))
" "$body_file" >"$body_file.json"
	curl --silent --show-error --fail-with-body --max-time 60 \
		--header "Authorization: Bearer ${token}" \
		--header "Accept: application/vnd.github+json" \
		--data "@$body_file.json" \
		--request POST \
		"${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}/issues/${pr}/comments" >/dev/null &&
		echo "posted the plan for $stack @ $site to pull request #${pr}"
	rm -f "$body_file.json"
}

if [ -n "${CI_MERGE_REQUEST_IID:-}" ]; then
	post_gitlab
elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
	post_github
else
	echo "not a merge or pull request pipeline; skipping the plan comment."
fi
SCAFFOLD_EOF
mark_executable scripts/post-plan-comment.sh

if wants_ci github; then

write_file .github/workflows/validate.yml <<'SCAFFOLD_EOF'
# Runs on every pull request. No credentials, no network access to any manager:
# everything here is offline validation of the data and the HCL.
name: validate

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  data:
    name: data schemas
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Validate data/ and inventory/
        run: python3 scripts/validate-data.py

  terraform:
    name: terraform fmt and validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
      - name: Format check
        run: terraform fmt -recursive -check -diff .
      - name: Validate each stack
        run: |
          set -euo pipefail
          for stack in stacks/*/; do
            echo "::group::${stack}"
            terraform -chdir="${stack}" init -backend=false -input=false
            terraform -chdir="${stack}" validate
            echo "::endgroup::"
          done
SCAFFOLD_EOF

write_file .github/workflows/plan.yml <<'SCAFFOLD_EOF'
# Plan every manager in the inventory, in parallel, with read-only credentials.
#
# The matrix comes from inventory/managers.yaml, so an eleventh Local Manager is
# a data change rather than a workflow change. Sites are independent: one site
# failing does not block the others.
#
# Before this can run, the repository owner must configure the secrets referenced
# below and decide the state backend (docs/ARCHITECTURE.md section 14).
name: plan

on:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  matrix:
    name: build matrix
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.build.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - id: build
        run: echo "matrix=$(python3 scripts/ci-matrix.py --format github)" >> "$GITHUB_OUTPUT"

  plan:
    name: ${{ matrix.stack }} @ ${{ matrix.site }}
    needs: matrix
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 4
      matrix: ${{ fromJson(needs.matrix.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - name: Plan
        env:
          # The plan identity is read-only. Only the apply workflow gets write
          # access — that is what makes it safe to plan on every pull request.
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_PLAN_TOKEN }}
        run: |
          scripts/with-credentials.sh "${{ matrix.site }}" -- \
            scripts/tf.sh plan "${{ matrix.stack }}" "${{ matrix.site }}"

      - name: Render plan summary
        run: |
          # The saved plan is a sensitive artifact. Render the summary, post
          # that, never the plan file itself.
          scripts/tf.sh show "${{ matrix.stack }}" "${{ matrix.site }}" \
            | tee "plan-${{ matrix.stack }}-${{ matrix.site }}.txt" \
            | tee -a "$GITHUB_STEP_SUMMARY" >/dev/null

      - name: Comment the plan on the pull request
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          scripts/post-plan-comment.sh "${{ matrix.stack }}" "${{ matrix.site }}" \
            "plan-${{ matrix.stack }}-${{ matrix.site }}.txt"

      - name: Keep the saved plan for the apply workflow
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ matrix.stack }}-${{ matrix.site }}
          path: |
            stacks/${{ matrix.stack }}/tfplan
            stacks/${{ matrix.stack }}/tfplan.site
          retention-days: 7
          if-no-files-found: error
SCAFFOLD_EOF

write_file .github/workflows/apply.yml <<'SCAFFOLD_EOF'
# CD. Runs on a push to the default branch — that is, on a merged pull request.
#
#   plan    re-plan on the merged tree, render it, keep it as an artifact
#   GATE    the apply job targets a GitHub Environment. Configure required
#           reviewers on that environment and the run pauses here until a human
#           approves, with the plan from the previous job in front of them.
#   apply   applies the SAVED plan from the plan job. Never a fresh one.
#
# The gate is a repository setting rather than something hard-coded here:
#   Settings -> Environments -> nsx-<site>-<stack> -> Required reviewers
# With no reviewers configured this applies automatically on merge, which is the
# right behaviour for a lab and the wrong one for a production firewall.
#
# See docs/GITOPS.md.
name: apply

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  # One apply at a time. Terraform state locking is the backstop, not the plan.
  group: nsx-apply-${{ github.ref }}
  cancel-in-progress: false

jobs:
  matrix:
    name: build matrix
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.build.outputs.matrix }}
      apply_matrix: ${{ steps.build.outputs.apply_matrix }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - id: build
        # Managers in mode: mirror are planned but never applied.
        run: |
          echo "matrix=$(python3 scripts/ci-matrix.py --format github)" >> "$GITHUB_OUTPUT"
          echo "apply_matrix=$(python3 scripts/ci-matrix.py --format github --managed-only)" >> "$GITHUB_OUTPUT"

  plan:
    name: plan ${{ matrix.stack }} @ ${{ matrix.site }}
    needs: matrix
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 4
      matrix: ${{ fromJson(needs.matrix.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - name: Plan
        env:
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_PLAN_TOKEN }}
        run: |
          scripts/with-credentials.sh "${{ matrix.site }}" -- \
            scripts/tf.sh plan "${{ matrix.stack }}" "${{ matrix.site }}"

      - name: Render it for the approver
        run: |
          scripts/tf.sh show "${{ matrix.stack }}" "${{ matrix.site }}" \
            | tee -a "$GITHUB_STEP_SUMMARY" >/dev/null

      - uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ matrix.stack }}-${{ matrix.site }}
          path: |
            stacks/${{ matrix.stack }}/tfplan
            stacks/${{ matrix.stack }}/tfplan.site
          retention-days: 7
          if-no-files-found: error

  apply:
    name: apply ${{ matrix.stack }} @ ${{ matrix.site }}
    needs: [matrix, plan]
    if: needs.matrix.outputs.apply_matrix != '{"include": []}'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix: ${{ fromJson(needs.matrix.outputs.apply_matrix) }}
    # The approval gate. Protect this environment to require a reviewer.
    environment: nsx-${{ matrix.site }}-${{ matrix.stack }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - uses: actions/download-artifact@v4
        with:
          name: tfplan-${{ matrix.stack }}-${{ matrix.site }}
          path: stacks/${{ matrix.stack }}/

      - name: Apply the plan that was approved
        env:
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_APPLY_TOKEN }}
          APPROVE: "yes"
        run: |
          test -f "stacks/${{ matrix.stack }}/tfplan" || {
            echo "no saved plan artifact; re-run the plan job" >&2; exit 1; }
          scripts/with-credentials.sh "${{ matrix.site }}" -- \
            scripts/tf.sh apply "${{ matrix.stack }}" "${{ matrix.site }}"
SCAFFOLD_EOF

write_file .github/pull_request_template.md <<'SCAFFOLD_EOF'
## What changed

<!-- One site or one application per PR. A PR spanning multiple sites cannot be
     rolled back cleanly. -->

## Change class

- [ ] **Routine** — rule added/removed in an existing policy, or a member added
      to a static group
- [ ] **Elevated** — new policy or category, new or changed group criteria, new
      segment, new tag scope
- [ ] **Restricted** — default rule, Emergency category, tag scope rename or
      removal, GM↔LM ownership move, anything in `platform`

Ticket:

## Plan review

- [ ] The resource **count delta** matches the intent
- [ ] **No unexpected destroys** — a destroy on an untouched rule means keys shifted
- [ ] No change to the **default rule** and none to the Emergency category
- [ ] Every new or changed rule has a **non-empty `scope`**
- [ ] Group criteria changes: **membership blast radius** checked in NSX *before* approval
- [ ] Sequence numbers do not collide and preserve intended ordering
- [ ] The change touches **one site's state**, unless deliberately global

## Rollback
SCAFFOLD_EOF

fi # wants_ci github

write_file inventory/README.md <<'SCAFFOLD_EOF'
# inventory

`managers.yaml` is the single registry of every NSX manager in the estate. It is
the only place a manager is declared: CI derives its run matrix from it,
`scripts/tf.sh` resolves host and domain from it, and
`scripts/with-credentials.sh` reads the Vault **path** from it.

It never contains a secret. `vault_path` records where the credential lives, not
what it is; `scripts/validate-data.py` fails the build if a key that looks like a
credential appears here.

## Adding a manager

1. Add the entry below the others, keyed by a short stable id (`lon1`, `nyc1`).
   That id is the site name used everywhere else — data files, backend config,
   CI job names.
2. Create `envs/<id>.backend.hcl`.
3. Store the credential in Vault at the recorded path.

Nothing else. If adding a manager requires editing Terraform code, the
abstraction is wrong.

## Fields

| Field | Meaning |
|---|---|
| `role` | `gm` (Global Manager) or `lm` (Local Manager) |
| `host` | Manager FQDN, exported as `NSXT_MANAGER_HOST` |
| `site` | Physical site this manager serves |
| `region` | Grouping for reporting |
| `vcf_instance` | Which VCF instance / SDDC Manager owns it |
| `sddc_manager` | SDDC Manager FQDN, for the VCF credential lookup |
| `vault_path` | Vault path holding the credential. Path only. |
| `tier` | `prod`, `preprod`, `nonprod`, `lab` |
| `domain` | NSX domain. On a GM, a domain id or site id — set it explicitly. |
| `stacks` | Which stacks run against this manager. Defaults by role. |
| `enabled` | Set `false` to drop a manager out of the CI matrix without deleting it |
SCAFFOLD_EOF

if [ "$WITH_EXAMPLES" = 1 ]; then

	write_file inventory/managers.yaml <<'SCAFFOLD_EOF'
# The single registry of every NSX manager in the estate.
#
# Paths, never secrets. See inventory/README.md.
#
# The entries below are a worked example with realistic shape — replace the
# hostnames, sites and Vault paths with the real estate. Delete any manager that
# does not exist rather than leaving it disabled.

managers:
  gm1:
    role: gm
    host: nsx-gm-01.example.internal
    site: lon1
    region: emea
    vcf_instance: vcf-lon-01
    sddc_manager: sddc-lon-01.example.internal
    vault_path: nsx/data/managers/gm1
    tier: prod
    domain: default   # the global domain, spanning every location
    stacks: [global-security]
    description: Global Manager. Owns the federated DFW for the whole estate.

  lon1:
    role: lm
    host: nsx-lm-lon-01.example.internal
    site: lon1
    region: emea
    vcf_instance: vcf-lon-01
    sddc_manager: sddc-lon-01.example.internal
    vault_path: nsx/data/managers/lon1
    tier: prod
    domain: default

  nyc1:
    role: lm
    host: nsx-lm-nyc-01.example.internal
    site: nyc1
    region: amer
    vcf_instance: vcf-nyc-01
    sddc_manager: sddc-nyc-01.example.internal
    vault_path: nsx/data/managers/nyc1
    tier: prod
    domain: default

  fra1:
    role: lm
    host: nsx-lm-fra-01.example.internal
    site: fra1
    region: emea
    vcf_instance: vcf-fra-01
    sddc_manager: sddc-fra-01.example.internal
    vault_path: nsx/data/managers/fra1
    tier: preprod
    domain: default
SCAFFOLD_EOF

	# Note the heredoc rather than a pipe: each stage of a pipeline runs in a
	# subshell, so a piped write_file could not update the counters or the
	# skipped-file exit status.
	for site in gm1 lon1 nyc1 fra1; do
		write_file "envs/${site}.backend.hcl" <<-EOF
			# Partial backend configuration for ${site}.
			#
			# The backend type is an open decision (docs/ARCHITECTURE.md section 14.1).
			# While the stacks are on the placeholder local backend, scripts/tf.sh
			# supplies the state path itself and this file holds nothing. Once the
			# backend is chosen, put its per-manager settings here — see
			# envs/example.backend.hcl.example.
		EOF
	done

	write_file data/groups/payments.yaml <<'SCAFFOLD_EOF'
# Groups for the payments application.
#
# Federated groups omit the site element of the naming convention on purpose:
# they span every site, so <env>-<app>-<role> is the whole name.
#
# Membership is dynamic. The tags these criteria match are written by the system
# that provisions the workload — this repository only consumes them.

groups:
  prod-payments-all:
    display_name: prod-payments-all
    description: Every payments workload in production. Used as Apply To for the policy.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"

  prod-payments-web:
    display_name: prod-payments-web
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|web"

  prod-payments-app:
    display_name: prod-payments-app
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|app"

  prod-payments-db:
    display_name: prod-payments-db
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|db"

  prod-payments-segments:
    display_name: prod-payments-segments
    description: >
      Subnet-based membership. Matches the segment tag rather than a CIDR: the
      segment is Terraform-owned, so its tags are reliable, and a CIDR here would
      be a duplicated fact that drifts from the segment's real definition.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: Segment
            operator: EQUALS
            value: "app|payments"
SCAFFOLD_EOF

	write_file data/groups/infrastructure.yaml <<'SCAFFOLD_EOF'
# Shared infrastructure groups and the quarantine mechanism.

groups:
  prod-lb:
    display_name: prod-lb
    description: Physical load balancer VIPs in front of production.
    owner: gm
    why_static: >
      Physical appliances with no VM object in NSX, so no tag can be applied to
      them. This becomes dynamic if the appliances are replaced by virtual
      editions that the provisioning system tags.
    criteria:
      - ip_addresses:
          - 10.10.0.10
          - 10.10.0.11
          - 10.20.0.10

  corp-dns:
    display_name: corp-dns
    description: Corporate DNS resolvers.
    owner: gm
    why_static: >
      Managed outside VCF by the platform team; not VM workloads in any of these
      managers. Becomes dynamic if DNS moves onto tagged VCF workloads.
    criteria:
      - ip_addresses:
          - 10.0.0.53
          - 10.0.1.53

  quarantine-active:
    display_name: quarantine-active
    description: >
      Incident response. Membership is one tag on a VM, applied by an operator —
      no Terraform run, no PR, no plan. Terraform owns the mechanism, not the
      act of quarantining.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "quarantine|active"

  lon1-legacy-hosts:
    display_name: prod-lon1-legacy-hosts
    description: Pre-VCF hosts at lon1 that predate the tagging estate.
    owner: lm
    sites: [lon1]
    why_static: >
      These workloads are not in the CMDB and nothing tags them. They become
      dynamic once the lon1 migration completes and the CMDB sync owns them.
    criteria:
      - ip_addresses:
          - 10.31.14.0/24

  lon1-app-frontend:
    display_name: prod-lon1-app-frontend
    description: Site-local frontend workloads at lon1.
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "zone|dmz"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
SCAFFOLD_EOF

	write_file data/services/common.yaml <<'SCAFFOLD_EOF'
# Services referenced by rules, by logical name.
#
# 'predefined' names are looked up in NSX rather than recreated, so there is one
# definition of HTTPS in the estate instead of one per repository.

predefined:
  https: HTTPS
  http: HTTP
  ssh: SSH
  dns-udp: DNS-UDP
  ntp: NTP

custom:
  payments-api:
    display_name: payments-api
    description: Payments service API listener.
    owner: gm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["8443"]

  payments-db:
    display_name: payments-db
    description: Payments database listener.
    owner: gm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["5432"]
SCAFFOLD_EOF

	write_file data/policies/payments.yaml <<'SCAFFOLD_EOF'
# Payments application policy. Federated: owned by the Global Manager.
#
# Adding a rule here is a routine change — edit this file, run 'make validate',
# open a PR. No HCL changes.
#
# Map keys are the stable identity. 'web-from-lb' is the Terraform address:
# changing a value updates the rule in place, renaming the key destroys and
# recreates it. Never renumber keys.

policy:
  id: prod-payments
  name: prod-payments
  description: East-west policy for the payments application.
  category: Application
  owner: gm
  sequence_number: 1000
  rule_management: standalone
  # Apply To. Mandatory: without it every rule below is pushed to every
  # hypervisor in the federation span.
  scope: [prod-payments-all]

rules:
  web-from-lb:
    name: web-from-lb
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [prod-lb]
    destination_groups: [prod-payments-web]
    services: [https]
    scope: [prod-payments-web]
    logged: true

  app-from-web:
    name: app-from-web
    sequence_number: 200
    action: ALLOW
    direction: IN
    source_groups: [prod-payments-web]
    destination_groups: [prod-payments-app]
    services: [payments-api]
    scope: [prod-payments-app]
    logged: true

  db-from-app:
    name: db-from-app
    sequence_number: 300
    action: ALLOW
    direction: IN
    source_groups: [prod-payments-app]
    destination_groups: [prod-payments-db]
    services: [payments-db]
    scope: [prod-payments-db]
    logged: true

  # Policy-level deny. This is not the DFW default rule — that one is never
  # touched by a routine change.
  deny-other:
    name: deny-other
    description: Anything not allowed above is dropped inside the application.
    sequence_number: 900
    action: DROP
    direction: IN_OUT
    source_groups: [ANY]
    destination_groups: [prod-payments-all]
    scope: [prod-payments-all]
    logged: true
SCAFFOLD_EOF

	write_file data/policies/infrastructure-baseline.yaml <<'SCAFFOLD_EOF'
# Estate-wide infrastructure services. Federated.

policy:
  id: infra-baseline
  name: infra-baseline
  description: DNS and NTP to the corporate resolvers, everywhere.
  category: Infrastructure
  owner: gm
  sequence_number: 100
  rule_management: standalone
  scope: [prod-payments-all]

rules:
  dns-to-corp:
    name: dns-to-corp
    sequence_number: 100
    action: ALLOW
    direction: OUT
    source_groups: [prod-payments-all]
    destination_groups: [corp-dns]
    services: [dns-udp]
    scope: [prod-payments-all]
    logged: false

  ntp-to-corp:
    name: ntp-to-corp
    sequence_number: 200
    action: ALLOW
    direction: OUT
    source_groups: [prod-payments-all]
    destination_groups: [corp-dns]
    services: [ntp]
    scope: [prod-payments-all]
    logged: false
SCAFFOLD_EOF

	write_file data/policies/emergency-quarantine.yaml <<'SCAFFOLD_EOF'
# Standing quarantine mechanism. RESTRICTED — changes here go through change
# advisory with a named approver.
#
# The point of this policy is that using it requires no Terraform run at all:
# incident response applies the tag 'quarantine|active' to a VM and the group
# picks it up. Incident response must not depend on a pipeline being healthy.
#
# Terraform owns the mechanism. Operators use it without Terraform in the loop.

policy:
  id: emergency-quarantine
  name: emergency-quarantine
  description: Isolate any workload tagged quarantine|active.
  category: Emergency
  owner: gm
  sequence_number: 10
  rule_management: standalone
  scope: [quarantine-active]

rules:
  quarantine-in:
    name: quarantine-in
    sequence_number: 100
    action: DROP
    direction: IN
    source_groups: [ANY]
    destination_groups: [quarantine-active]
    scope: [quarantine-active]
    logged: true

  quarantine-out:
    name: quarantine-out
    sequence_number: 200
    action: DROP
    direction: OUT
    source_groups: [quarantine-active]
    destination_groups: [ANY]
    scope: [quarantine-active]
    logged: true
SCAFFOLD_EOF

	write_file data/policies/lon1-legacy.yaml <<'SCAFFOLD_EOF'
# Site-local exception at lon1. Owned by the Local Manager, not the GM.
#
# Everything referenced here is site-local: a Local Manager policy and a
# federated group are on opposite sides of the ownership boundary.

policy:
  id: lon1-legacy
  name: prod-lon1-legacy
  description: Temporary allowance for pre-VCF hosts at lon1 during migration.
  category: Application
  owner: lm
  sites: [lon1]
  sequence_number: 2000
  rule_management: standalone
  scope: [lon1-app-frontend]

rules:
  frontend-from-legacy:
    name: frontend-from-legacy
    description: Remove when the lon1 migration completes.
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [lon1-legacy-hosts]
    destination_groups: [lon1-app-frontend]
    services: [https]
    scope: [lon1-app-frontend]
    logged: true
SCAFFOLD_EOF

	write_file data/network/lon1.yaml <<'SCAFFOLD_EOF'
# Segments and tier-1 gateways at lon1. Consumed by the local-network stack.
#
# Segment tags are set here because segments are Terraform-owned infrastructure.
# Those tags are what lets a group select workloads by subnet without hardcoding
# a CIDR into group criteria.

site: lon1

tier1s:
  t1-payments:
    display_name: prod-lon1-payments-t1
    tier0_display_name: prod-lon1-t0
    edge_cluster_display_name: edge-cluster-lon1
    failover_mode: NON_PREEMPTIVE
    route_advertisement_types:
      - TIER1_CONNECTED
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod

segments:
  seg-payments-web:
    display_name: prod-lon1-payments-web
    tier1: t1-payments
    transport_zone_display_name: overlay-tz-lon1
    subnets:
      - cidr: 10.30.1.1/24
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod
      - scope: zone
        tag: dmz

  seg-payments-db:
    display_name: prod-lon1-payments-db
    tier1: t1-payments
    transport_zone_display_name: overlay-tz-lon1
    subnets:
      - cidr: 10.30.3.1/24
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod
      - scope: zone
        tag: internal
SCAFFOLD_EOF

	write_file data/platform/lon1.yaml <<'SCAFFOLD_EOF'
# Platform objects at lon1. RESTRICTED — change advisory, named approver,
# rollback plan, out-of-hours. Nothing with a daily cadence belongs in this file.

site: lon1

tier0s:
  t0-lon1:
    display_name: prod-lon1-t0
    ha_mode: ACTIVE_ACTIVE
    failover_mode: NON_PREEMPTIVE
    edge_cluster_display_name: edge-cluster-lon1
    transit_subnets:
      - 100.64.0.0/16
    bgp:
      enabled: true
      local_as_num: "65001"
      ecmp: true
    tags:
      - scope: env
        tag: prod
SCAFFOLD_EOF

	if [ "$SEEDED_ALREADY" = 0 ]; then
		write_file data/.example-content <<'SCAFFOLD_EOF'
This file marks inventory/ and data/ as the shipped EXAMPLE content: four
managers and one site that exist nowhere, written so the validators and
terraform have something to chew on.

scripts/readiness.sh treats its presence as "this estate is not real yet".
DELETE IT once you have replaced the example data with your own; re-running the
generator will not bring it back.
SCAFFOLD_EOF
	fi

	write_file data/vm-tags/lon1.yaml <<'SCAFFOLD_EOF'
# VM tag assignments at lon1 — variant B in docs/TAGGING.md.
#
# Terraform owns the COMPLETE tag set of every VM listed here. A tag removed
# from this file is removed from the VM on the next apply, and deleting a VM
# entry strips every tag it has. That is a property of nsxt_policy_vm_tags, not
# a choice this repository made: the resource has no per-tag ownership.
#
# Only scopes recorded as 'owner: terraform' in data/schema/tag-scopes.yaml may
# appear here. make validate enforces it. If VCF automation or a CMDB tags these
# workloads, this file should be empty and the groups should consume those tags
# instead — read docs/TAGGING.md before adding to it.
#
#   make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
#   make tags SITE=lon1

site: lon1

sole_tagger: >
  Example content. These are hand-built workloads that predate the CMDB
  onboarding, so nothing else writes their NSX tags. Replace this with the real
  reason for your estate, or delete the file.

vms:
  payments-web-01:
    # external_id is preferred over display_name: it survives a vCenter rename
    # and is unambiguous across vCenters. Take it from the NSX inventory.
    display_name: payments-web-01
    description: Hand-built; not onboarded to the CMDB.
    tags:
      - { scope: workload, tag: payments-web }

  payments-db-01:
    display_name: payments-db-01
    description: Hand-built; not onboarded to the CMDB.
    tags:
      - { scope: workload, tag: payments-db }
SCAFFOLD_EOF

fi # WITH_EXAMPLES

# ---------------------------------------------------------------------------
# 8. Finish
# ---------------------------------------------------------------------------

# Leave a copy of this script in the scaffold, so the tree it produces can
# regenerate and update itself without reaching back to wherever it came from.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
if [ -f "$SELF" ] && [ "$SELF" != "$ROOT/scripts/bootstrap.sh" ]; then
	write_file scripts/bootstrap.sh <"$SELF"
	mark_executable scripts/bootstrap.sh
fi

# ARCHITECTURE.md and SETUP.md are referenced throughout the generated tree and
# are too long to embed here, so they are carried across rather than written out.
# They travel beside the script, so a scaffold generated from a scaffold keeps
# them and their cross-references keep resolving.
for doc in ARCHITECTURE SETUP; do
	src="$SELF_DIR/../docs/$doc.md"
	if [ -f "$src" ] && [ "$src" != "$ROOT/docs/$doc.md" ]; then
		write_file "docs/$doc.md" <"$src"
	elif [ ! -f "$ROOT/docs/$doc.md" ]; then
		warn "docs/$doc.md was not found next to this script and has not been written.
         The generated tree references it. Copy it in from the repository this
         script came from."
	fi
done

if [ "$DRY_RUN" != 1 ]; then
	for f in $EXECUTABLES; do
		[ -e "$ROOT/$f" ] && chmod +x "$ROOT/$f"
	done
fi

# Any version-control choice implies a working tree; only 'none' does not.
vcs_wants_git() {
	case "$VCS" in
	git | github | gitlab | gitlab-docker) return 0 ;;
	*) return 1 ;;
	esac
}

if { [ "$WITH_GIT" = 1 ] || vcs_wants_git; } && [ "$DRY_RUN" != 1 ]; then
	if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		log ""
		log "git: already a working tree, left alone"
	else
		log ""
		git -C "$ROOT" init -q -b "$GIT_BRANCH" 2>/dev/null ||
			git -C "$ROOT" init -q # -b needs git 2.28+; older git gets its default
		log "git: initialised a repository in $ROOT"
	fi
fi

# Merge what this run wrote into the tree's record of generator output.
if [ "$DRY_RUN" != 1 ] && [ -s "$STAGE/generated.sha256" ]; then
	{
		cat "$STAGE/generated.sha256"
		[ -f "$ROOT/.nsx-generated.sha256" ] && cat "$ROOT/.nsx-generated.sha256"
		true # no earlier record is not a failure
	} | LC_ALL=C sort -k2,2 -s -u >"$STAGE/merged.sha256" &&
		cat "$STAGE/merged.sha256" >"$ROOT/.nsx-generated.sha256" 2>/dev/null ||
		warn "could not write $ROOT/.nsx-generated.sha256; scripts/update.sh will treat differing files as conflicts"
fi

# The release this tree was generated at, so update.sh can show what is new.
if [ "$DRY_RUN" != 1 ]; then
	printf '%s\n' "$VERSION" >"$ROOT/.nsx-generator-version" 2>/dev/null || true
fi

# Remember the answers, so a later bare re-run does not quietly change the shape
# of the tree. Written last, once everything has succeeded.
if [ "$DRY_RUN" != 1 ]; then
	{
		printf '# Written by scripts/bootstrap.sh. Read on re-run so the answers\n'
		printf '# given once are not silently re-derived from the defaults.\n'
		printf '# Safe to edit; safe to delete (you just get asked again).\n'
		printf 'SAVED_VCS=%s\n' "$VCS"
		printf 'SAVED_CI_PLATFORM=%s\n' "$CI_PLATFORM"
		printf 'SAVED_BACKEND=%s\n' "$BACKEND"
		printf 'SAVED_GIT_REMOTE=%s\n' "$(printf '%s' "$GIT_REMOTE" | sed "s/'/'\\\\''/g")"
		printf 'SAVED_GIT_BRANCH=%s\n' "$GIT_BRANCH"
	} >"$ROOT/.nsx-bootstrap.conf" 2>/dev/null ||
		warn "could not write $ROOT/.nsx-bootstrap.conf; re-runs will use the defaults"
fi

# --- what the version-control choice actually does -------------------------
#
# Deliberately after every file is written, and never in a dry run. Generation
# is identical whatever is chosen here — .gitlab-ci.yml, the GitHub workflows
# and the helper scripts are always present — so this only wires up a remote or
# starts a container. That is what makes "decide later" free.

if [ "$DRY_RUN" != 1 ]; then
	case "$VCS" in
	git | github)
		if [ -n "$GIT_REMOTE" ]; then
			if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
				log "git: 'origin' already set to $(git -C "$ROOT" remote get-url origin), left alone"
			else
				git -C "$ROOT" remote add origin "$GIT_REMOTE" &&
					log "git: remote 'origin' set to $GIT_REMOTE"
			fi
			log ""
			log "next, to turn on the review pipeline:"
			log "  git add -A && git commit -m 'Initial NSX Terraform scaffold'"
			log "  git push -u origin $GIT_BRANCH"
			log "  then protect '$GIT_BRANCH', require an approval, and set the CI"
			log "  variables listed in docs/GITOPS.md."
		fi
		log ""
		log "your CI definitions are here — point your host at them:"
		wants_ci gitlab && log "  .gitlab-ci.yml            GitLab (child pipeline: scripts/gitlab-child-pipeline.py)"
		wants_ci github && log "  .github/workflows/        validate.yml, plan.yml, apply.yml"
		[ "$CI_PLATFORM" = none ] && log "  (none written — re-run with --ci gitlab or --ci github)"
		true
		;;
	gitlab)
		if [ -n "$GIT_REMOTE" ]; then
			if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
				log "git: 'origin' already set to $(git -C "$ROOT" remote get-url origin), left alone"
			else
				git -C "$ROOT" remote add origin "$GIT_REMOTE" &&
					log "git: remote 'origin' set to $GIT_REMOTE"
			fi
		fi
		if [ -n "$GITLAB_URL_ARG" ] && [ -n "$GITLAB_TOKEN_ARG" ] && [ -n "$GITLAB_PROJECT_ARG" ]; then
			log ""
			log "setting the GitLab project up..."
			GITLAB_TOKEN="$GITLAB_TOKEN_ARG" "$ROOT/scripts/gitlab-setup.sh" \
				--url "$GITLAB_URL_ARG" \
				--token "$GITLAB_TOKEN_ARG" \
				--project "$GITLAB_PROJECT_ARG" \
				--branch "$GIT_BRANCH" ||
				warn "GitLab setup reported a problem. The repository is complete and
         unaffected; re-run when ready:
           scripts/gitlab-setup.sh --url URL --token TOKEN --project group/name"
		else
			log ""
			log "the pipeline is written but nothing was created on GitLab, because no"
			log "URL, token and project were given. When you have them:"
			log "  scripts/gitlab-setup.sh --url https://gitlab.example.com \\"
			log "      --token glpat-xxxx --project group/nsx-terraform"
			log ""
			log "that creates the project, pushes, sets the CI variables and protects"
			log "the default branch. Or push by hand and configure it yourself."
		fi
		;;
	gitlab-docker)
		log ""
		log "starting GitLab in Docker..."
		if [ -x "$ROOT/scripts/gitlab-up.sh" ]; then
			# Not fatal: the files are written and correct either way, and the
			# script is re-runnable.
			"$ROOT/scripts/gitlab-up.sh" || {
				warn "GitLab did not come up. The repository is complete and unaffected.
         Re-run when Docker is ready:  scripts/gitlab-up.sh"
			}
		else
			warn "scripts/gitlab-up.sh is missing or not executable."
		fi
		;;
	none)
		log ""
		log "local files only — no version control and no pipeline."
		log ""
		log "the manual workflow, which is what you have:"
		log "    make validate                              schemas and conventions"
		log "    make plan  STACK=local-security SITE=lon1  writes a saved plan"
		log "    make show  STACK=local-security SITE=lon1  read it before applying"
		log "    APPROVE=yes make apply STACK=local-security SITE=lon1"
		log ""
		log "apply still refuses without a saved plan and without APPROVE=yes, so"
		log "the review step survives even with nobody to review it. What is missing"
		log "is the record: nothing says who changed a rule, when, or why."
		log ""
		log "when you want that:  scripts/enable-gitops.sh"
		;;
	esac
fi

log ""
log "summary"
log "  created   $created"
log "  updated   $updated"
log "  unchanged $unchanged"
[ "$skipped" -gt 0 ] && log "  skipped   $skipped (existing files with different content)"
[ "$protected" -gt 0 ] && log "  protected $protected (your estate data, left untouched)"

if [ "$DRY_RUN" = 1 ]; then
	log ""
	log "dry run — nothing was written."
	exit 0
fi

if [ "$QUIET" != 1 ]; then
	cat <<'NEXT'

next steps
  1. make preflight              check the tools this repository needs
  2. make validate               schema + convention checks, offline
  3. Edit inventory/managers.yaml so it describes the real estate, and add one
     envs/<site>.backend.hcl per manager.
  4. Decide the state backend and replace the placeholder in stacks/*/backend.tf.
     The local backend is not acceptable for a real manager.
  5. terraform init in one stack, then commit the generated .terraform.lock.hcl.

what still needs a human decision (docs/ARCHITECTURE.md section 14)
  * state backend, encryption and locking
  * Vault mount, path convention, and auth method for the pipeline
  * whether Application category is GM-owned or delegated per site
  * which site is the brownfield import pilot
NEXT
fi

if [ "$skipped" -gt 0 ]; then
	exit 2
fi
exit 0
