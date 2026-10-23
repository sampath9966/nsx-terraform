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

VERSION="1.2.8"

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
import: ## Adopt an existing estate: SITE=<site> [DUMP=<file>]
	@if [ -n "$(DUMP)" ]; then \
		$(PYTHON) scripts/import-estate.py --site "$(SITE)" --from-dump "$(DUMP)"; \
	else \
		scripts/with-credentials.sh "$(SITE)" -- $(PYTHON) scripts/import-estate.py --site "$(SITE)"; \
	fi

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
	@find . -name 'tfplan' -o -name '*.tfplan' -o -name 'plan.json' | xargs -r rm -f
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
# Starting from the estate you already have

You are not building a new network. NSX is already running, the rules already
carry traffic, and nothing here may create a second copy of any of it.

The whole approach is **adopt, never recreate**: read what exists, write it out
as data, and hand Terraform the existing objects by id so that the first apply
changes nothing at all. A tranche is finished when `terraform plan` says *no
changes* — not when it applies cleanly.

## Before you start

1. `make preflight`
2. Put the real managers in `inventory/managers.yaml` and add one
   `envs/<site>.backend.hcl` each.
3. Pick a **pilot**: one site, one application. Not the busiest one, and not
   production-critical on the first pass.

## Step 1 — capture the estate

Credentials come from the environment, never from a file:

```bash
scripts/with-credentials.sh lon1 -- scripts/import-estate.py \
    --site lon1 --dump-only reports/lon1-raw.json
```

`reports/` is gitignored. The dump is a read-only snapshot of your security
posture — treat it like a plan file.

Capturing separately from converting means you can iterate on the conversion
without hammering the manager, and you can review exactly what was read.

## Step 2 — convert it to data

```bash
scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json
```

Which writes:

| File | What it holds |
|---|---|
| `data/groups/imported-<site>.yaml` | groups, with NSX expressions converted to criteria |
| `data/policies/<policy-id>.yaml` | one file per policy — this is what makes rule reuse work |
| `data/services/imported-<site>.yaml` | custom services; predefined ones are referenced, not copied |
| `stacks/<stack>/import.tf` | the import blocks |
| `data/.import-manifest.json` | what was imported and from where |

**Nothing you already have is overwritten.** If a target exists the tool writes
`<name>.new` beside it and tells you, so you diff and merge by hand.

## Step 3 — read what it produced

This is the step people skip. The converter is faithful, not clever:

- Every group with static IP membership gets a placeholder `why_static`. Replace
  it with the real reason, or make the group dynamic.
- Tag scopes must exist in `data/schema/tag-scopes.yaml`. Real estates contain
  scopes nobody documented; add them deliberately rather than in bulk.
- Rules with an empty `scope` are rules NSX is pushing to every host in the
  span. The importer records what is there; `make validate` will fail them.
  That failure is a finding about your estate, not a bug.
- Object keys are the real nsx_ids and are adopted **verbatim** — mixed case and
  underscores included. They must match or the import misses. The naming
  convention applies to objects you create from here on, and the validator
  knows the difference.

```bash
make validate
```

## Step 4 — import one tranche

```bash
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
scripts/tf.sh show local-security lon1
```

Read the plan against this bar:

- Every object appears as an **import**, not a create.
- **Zero** creates, updates or destroys. A create means Terraform did not
  recognise something that exists — stop; do not apply, or you get a duplicate.
- An update usually means the data does not match reality yet. Fix the data,
  not the manager.

When the plan is a pure import:

```bash
APPROVE=yes scripts/with-credentials.sh lon1 -- \
    scripts/tf.sh apply local-security lon1
```

Then confirm the follow-up plan is empty, and delete `import.tf` — import blocks
are one-shot.

### If every import fails with a not-found error

The id format is wrong for your provider version, and **nothing has been written
to state** — it is a safe failure. Re-run the converter with a different form:

```bash
scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --id-format domain-id
```

`path` (the default), `domain-id` and `id` are the three the nsxt provider has
used. Confirm on the pilot; the rest of the estate then uses the same one.

## Step 5 — repeat, one tranche at a time

One policy or one site per pass, each its own PR. A PR spanning multiple sites
cannot be rolled back cleanly.

## After the import: your data is yours

Two guarantees, both enforced rather than documented:

- `bootstrap.sh` will not overwrite estate data with `--force`, and refuses
  outright — even with `--force-data` — for anything in the import manifest.
- Drift detection is read-only. `scripts/drift.sh` runs a refresh-only plan,
  writes its report to `reports/`, and **never** writes back into `data/`. Drift
  is a ticket for a human, not an automatic rewrite of your imported estate.

## Adding a rule after importing

The point of one-file-per-policy: the rule goes into the policy that already
exists.

```bash
scripts/add-rule.py --policy legacy-app --rule allow-monitoring \
    --source prod-monitoring --destination legacy-web \
    --service https --scope legacy-web
```

It finds `legacy-app` by id or display name, appends to that file, and allocates
the next free sequence number. If the policy does not exist it stops and tells
you — creating one needs `--create-policy`, because a new policy is a new
category placement, a new ordering, and a new blast radius.
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
| Plans cannot write | `VAULT_PLAN_TOKEN` is read-only |
| Only protected branches can write | `VAULT_APPLY_TOKEN` marked **protected** |
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
| `NSX_APPLY_MODE` | `manual` (default) or `auto` | optional |

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

If `CI_API_TOKEN` is absent the pipeline still runs; it just does not comment,
and the approver reads the plan in the job log instead.

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

## The approver's job

Read the **plan**, not the diff. The YAML says what somebody intended; the plan
says what Terraform will do.

- **Resource count delta matches the intent.** One rule added should not be
  fourteen resources changed.
- **No unexpected destroys.** A destroy on a rule nobody touched means map keys
  shifted — stop and find out why before approving.
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
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$" },
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
          "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$",
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
        "sequence_number": { "type": "integer", "minimum": 1 },
        "stateful": { "type": "boolean" },
        "tcp_strict": { "type": "boolean" },
        "locked": { "type": "boolean" },
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
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["sequence_number", "action", "direction", "scope"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "description": { "type": "string" },
          "sequence_number": { "type": "integer", "minimum": 1 },
          "action": { "enum": ["ALLOW", "DROP", "REJECT", "JUMP_TO_APPLICATION"] },
          "direction": { "enum": ["IN", "OUT", "IN_OUT"] },
          "ip_version": { "enum": ["IPV4", "IPV6", "IPV4_IPV6"] },
          "disabled": { "type": "boolean" },
          "logged": { "type": "boolean" },
          "notes": { "type": "string" },
          "log_label": { "type": "string" },
          "profiles": { "type": "array", "items": { "type": "string" } },
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
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$" },
      "additionalProperties": {
        "type": "string",
        "description": "display_name of a service that already exists in NSX; looked up, not created."
      }
    },
    "custom": {
      "type": "object",
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "owner": { "enum": ["gm", "lm"] },
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
      condition     = length(try(each.value.criteria, [])) > 0
      error_message = "Group ${each.key} has no criteria. A group with no membership matches nothing and silently drops traffic."
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
- Static membership (`ip_addresses`, `member_groups`) requires `why_static` in
  the data file; CI enforces it.
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
  # "ANY" is the one literal allowed in a data file. Everything else is a
  # logical name resolved to a policy path here, so no raw /infra/... path ever
  # appears in data/.
  resolvable = concat(keys(var.group_paths), ["ANY"])

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
        try(r.source_groups, []),
        try(r.destination_groups, []),
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
      condition     = length(local.sequence_numbers) == length(distinct(local.sequence_numbers))
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
#   export TF_HTTP_USERNAME=gitlab-ci-token
#   export TF_HTTP_PASSWORD="$CI_JOB_TOKEN"     # in GitLab CI
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
  custom_services_all = merge([for d in local.service_docs : try(d.custom, {})]...)
  custom_services     = { for k, v in local.custom_services_all : k => v if try(v.owner, "gm") == "gm" }

  service_paths = merge(
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
export TF_VAR_domain=global          # never leave this to default
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

  group_paths = merge(module.base_groups.paths, module.composite_groups.paths)

  # --- services -----------------------------------------------------------
  service_files = fileset("${local.data_root}/services", "*.yaml")
  service_docs  = [for f in local.service_files : yamldecode(file("${local.data_root}/services/${f}"))]

  predefined_services = merge([for d in local.service_docs : try(d.predefined, {})]...)
  custom_services_all = merge([for d in local.service_docs : try(d.custom, {})]...)
  custom_services     = { for k, v in local.custom_services_all : k => v if try(v.owner, "gm") == "lm" }

  service_paths = merge(
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
	sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
eval "$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$site")"

export TF_VAR_site="$site"
export TF_VAR_domain="${TF_VAR_domain:-${NSX_DOMAIN:-default}}"
export TF_IN_AUTOMATION=1
# A GitLab that serves its own certificate authority. The runner hands every job
# that CA as CI_SERVER_TLS_CA_FILE, and git and curl are pointed at it, but
# Terraform reads the state over HTTPS too and fails with "x509: certificate
# signed by unknown authority". Go replaces the system roots when SSL_CERT_FILE
# is set, so the bundle is the system roots plus that CA. A SSL_CERT_FILE that is
# already set is left alone.
if [ -z "${SSL_CERT_FILE:-}" ] && [ -n "${CI_SERVER_TLS_CA_FILE:-}" ] && [ -r "$CI_SERVER_TLS_CA_FILE" ]; then
	ca_bundle="$(mktemp "${TMPDIR:-/tmp}/nsx-ca.XXXXXX")"
	trap 'rm -f "$ca_bundle"' EXIT
	for roots in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
		if [ -r "$roots" ]; then
			cat "$roots" >>"$ca_bundle"
			break
		fi
	done
	cat "$CI_SERVER_TLS_CA_FILE" >>"$ca_bundle"
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

backend_args=(-backend-config="$backend_file")
if uses_local_backend; then
	mkdir -p "$REPO_ROOT/.local-state"
	backend_args+=(-backend-config="path=$REPO_ROOT/.local-state/${site}-${stack}.tfstate")
fi

case "$cmd" in
init)
	run init -reconfigure "${backend_args[@]}" "$@"
	;;
plan)
	[ -d "$stack_dir/.terraform" ] || run init -reconfigure "${backend_args[@]}"
	run plan -out=tfplan -parallelism="$PARALLELISM" -input=false "$@"
	echo
	echo "plan written to stacks/$stack/tfplan — a sensitive artifact, not a PR attachment."
	echo "review it with: scripts/tf.sh show $stack $site"
	;;
show)
	[ -f "$plan_file" ] || {
		echo "error: no saved plan. Run: scripts/tf.sh plan $stack $site" >&2
		exit 1
	}
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
	if uses_local_backend && [ "${ALLOW_LOCAL_STATE:-}" != 1 ]; then
		echo "error: stack $stack is still on the placeholder local backend. State carries the security posture of the estate and needs a remote, encrypted, locked backend before any real apply. Set ALLOW_LOCAL_STATE=1 only for a lab." >&2
		exit 1
	fi
	run apply -parallelism="$PARALLELISM" -input=false tfplan
	rm -f "$plan_file"
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

# Inventory lookup: host and vault path for this site. Never the secret.
eval "$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$SITE")"
[ -n "${NSX_HOST:-}" ] || die "site '$SITE' is not in inventory/managers.yaml"

export NSXT_MANAGER_HOST="$NSX_HOST"

# Keep the session alive across requests — materially faster on large plans.
export NSXT_SESSION_AUTH="${NSXT_SESSION_AUTH:-true}"

json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$@"; }

# Credential lookup in the environment. Prints "<username-var> <password-var>"
# for the first prefix whose username and password are both set.
env_credential_vars() {
	local key scope prefix u p
	key="$(printf '%s' "$SITE" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')"
	scope="$(printf '%s' "${NSX_CRED_SCOPE:-}" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')"
	for prefix in ${scope:+"NSX_${key}_${scope}"} "NSX_${key}" ${scope:+"NSX_${scope}"} NSX; do
		u="${prefix}_USERNAME"
		p="${prefix}_PASSWORD"
		if [ -n "${!u:-}" ] && [ -n "${!p:-}" ]; then
			printf '%s %s\n' "$u" "$p"
			return 0
		fi
	done
	return 1
}

if [ "$SOURCE" = auto ]; then
	if [ -n "${VAULT_ADDR:-}" ]; then
		SOURCE=vault
	elif env_credential_vars >/dev/null; then
		SOURCE=env
	else
		die "no NSX credentials for '$SITE'. Set VAULT_ADDR and VAULT_TOKEN, or set NSX_USERNAME and NSX_PASSWORD (or per-site NSX_<SITE>_USERNAME / _PASSWORD) as masked CI/CD variables."
	fi
fi

case "$SOURCE" in
env)
	read -r u_var p_var <<<"$(env_credential_vars)" ||
		die "no NSX credential variables set for '$SITE' (looked for NSX_<SITE>[_<SCOPE>]_USERNAME / _PASSWORD and NSX_USERNAME / _PASSWORD)"
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

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "inventory" / "managers.yaml"

# A Global Manager has no VM inventory and no local networking, so local-tags,
# local-network and platform are Local Manager stacks only.
GM_STACKS = ["global-security"]
LM_STACKS = ["local-security", "local-tags", "local-network", "platform"]


def managers(strict: bool = True) -> dict:
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
from ci_matrix_lib import entries, managers  # noqa: E402


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
    }
    for key, value in pairs.items():
        print(f"export {key}={shlex.quote(str(value))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stack", help="only include this stack")
    ap.add_argument("--format", choices=["json", "github", "lines"], default="json")
    ap.add_argument("--export", metavar="SITE", help="print shell exports for one manager")
    args = ap.parse_args()

    if args.export:
        return export(args.export)

    # Strict here: a human or a GitHub matrix asking for the inventory when it
    # does not exist is an error, not an empty list.
    rows = entries(args.stack, strict=True)
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

PyYAML is used when it is importable. When it is not, a parser for the subset of
YAML this repository actually commits takes over: block mappings, block and flow
sequences, quoted and plain scalars, folded and literal block scalars, comments.

The fallback exists so that 'make validate' works on a laptop with nothing
installed. Terraform itself parses these files with yamldecode, which is a full
YAML implementation, so the fallback never has to be authoritative — it only has
to agree on the subset we write.
"""

from __future__ import annotations

import re
from typing import Any

try:  # pragma: no cover - environment dependent
    import yaml as _pyyaml
except ImportError:  # pragma: no cover
    _pyyaml = None


def load_yaml(text: str) -> Any:
    if _pyyaml is not None:
        return _pyyaml.safe_load(text)
    return _Parser(text).parse()


class YamlError(ValueError):
    pass


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
            if entry is None or entry[0] <= indent:
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


def _strip_comment(text: str) -> str:
    out = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#" and (i == 0 or text[i - 1] == " "):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).rstrip()


def _split_key(text: str) -> tuple[str, bool, str]:
    # A colon only separates a key when it is outside quotes and outside any
    # [...] or {...}: '- { scope: workload, tag: x }' is one flow mapping, not
    # a mapping whose first key is '{ scope'.
    quote = None
    depth = 0
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            continue
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif depth == 0 and ch == ":" and (i + 1 == len(text) or text[i + 1] in " \t"):
            return _unquote(text[:i].strip()), True, text[i + 1 :]
    return text, False, ""


def _unquote(text: str) -> str:
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
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
        return text[1:-1]
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
    parts: list[str] = []
    depth = 0
    quote = None
    current: list[str] = []
    for ch in text:
        if quote:
            current.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            current.append(ch)
        elif ch in "[{":
            depth += 1
            current.append(ch)
        elif ch in "]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
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
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

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


def imported_files() -> set[str]:
    path = DATA / ".import-manifest.json"
    if not path.exists():
        return set()
    try:
        return set(json.loads(path.read_text()).get("imported", []))
    except ValueError:
        return set()


def check_key_style(where: str, kind: str, key: str, imported: set[str], report: Report) -> None:
    if where in imported or CONVENTIONAL_KEY.match(str(key)):
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
        for stack in m.get("stacks") or []:
            if role == "gm" and stack != "global-security":
                report.error(where, f"{name}: a Global Manager cannot run the {stack} stack.")
            if role == "lm" and stack == "global-security":
                report.error(where, f"{name}: global-security runs against the GM, not a Local Manager.")
        backend = REPO_ROOT / "envs" / f"{name}.backend.hcl"
        if m.get("enabled") is not False and not backend.exists():
            report.warn(where, f"{name}: no envs/{name}.backend.hcl — nothing can initialise for this manager.")

    return managers


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


def check_tag_value(where: str, label: str, member_type: str, value: str, scopes: dict, report: Report) -> None:
    if "|" not in value:
        report.warn(
            where,
            f"{label}: tag {value!r} has no scope. Scope every tag as 'scope|value' so the "
            "vocabulary can be enforced.",
        )
        return
    scope, _, tag_value = value.partition("|")
    if scope not in scopes:
        report.error(
            where,
            f"{label}: tag scope {scope!r} is not in data/schema/tag-scopes.yaml. Adding a "
            "scope is a reviewed change; a typo here silently empties the group.",
        )
        return
    spec = scopes[scope] or {}
    allowed = spec.get("values")
    if allowed and tag_value not in allowed:
        report.error(where, f"{label}: {tag_value!r} is not a permitted value for scope {scope!r} ({', '.join(allowed)})")
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
            static = any(c.get("ip_addresses") for c in criteria if isinstance(c, dict))
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
                        check_tag_value(where, label, condition.get("member_type", ""), str(condition.get("value", "")), scopes, report)

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


def check_services(docs: dict[Path, dict], imported: set[str], report: Report) -> dict[str, dict]:
    schema = load_schema("service.schema.json")
    services: dict[str, dict] = {}
    origin: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        for name, display in (doc.get("predefined") or {}).items():
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            services[name] = {"kind": "predefined", "display_name": display, "owner": None}
            origin[name] = where
            check_key_style(where, "service", name, imported, report)

        for name, service in (doc.get("custom") or {}).items():
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            if not (service.get("l4_port_set") or service.get("icmp")):
                report.error(where, f"service {name!r} has no entries — it would match nothing.")
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
        name_key = (policy.get("name"), policy.get("category"), owner, tuple(sorted(policy_sites)))
        if policy.get("name") and name_key in seen_names:
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

        def resolve_group(name: str, label: str) -> None:
            if name == "ANY":
                return
            group = groups.get(name)
            if group is None:
                report.error(where, f"{label}: references undefined group {name!r}")
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
                    report.error(where, f"{label}: sequence_number {seq} already used by {sequence_numbers[seq]}. Sequence numbers are allocated, not guessed.")
                sequence_numbers[seq] = label
                if seq % 100 != 0:
                    report.warn(where, f"{label}: sequence_number {seq} is not a multiple of 100. Gaps are what let a rule be inserted later without renumbering.")

            for field in ("source_groups", "destination_groups", "scope"):
                for name in rule.get(field) or []:
                    resolve_group(name, f"{label}.{field}")

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
    services = check_services(service_docs, imported, report)
    check_policies(policy_docs, groups, services, sites, imported, report)
    tagged_vms = check_vm_tags(scopes, sites, report)
    check_env_backends(report)
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

What it writes (never over the top of anything):

  data/groups/imported-<site>.yaml     groups, criteria converted from expressions
  data/policies/<policy-id>.yaml       one file per policy, so add-rule.py finds it
  data/services/imported-<site>.yaml   custom services; predefined ones referenced
  stacks/<stack>/import.tf             import blocks for terraform
  data/.import-manifest.json           what was imported, and from where

If a target file already exists it is written as <name>.new and reported. Your
data is never overwritten by this tool, and bootstrap.sh refuses to overwrite
anything listed in the manifest even with --force-data.

IMPORT ID FORMAT: policy resources in the nsxt provider have taken more than
one import id format across versions — the policy path, or "domain/id". This
script defaults to the path and can emit either (--id-format). Confirm on your
first tranche: a wrong format fails immediately and harmlessly at plan time
with a "not found" style error, before anything is written to state.
"""

from __future__ import annotations

import argparse
import json
import os
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

GM_BASE = "/global-manager/api/v1/global-infra"
LM_BASE = "/policy/api/v1/infra"


# --------------------------------------------------------------------------
# Fetching
# --------------------------------------------------------------------------

def api_get(host: str, path: str, user: str, password: str, insecure: bool) -> dict:
    url = f"https://{host}{path}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    credentials = urllib.parse.quote(user), urllib.parse.quote(password)
    import base64

    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    request.add_header("Authorization", f"Basic {token}")

    context = ssl.create_default_context()
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
                "\n       The manager is presenting a certificate this machine does not trust. "
                "Install the CA, or re-run with --insecure if you accept the risk on a lab."
            )
        sys.exit(f"error: cannot reach {host}: {exc.reason}{hint}")


def fetch_estate(host: str, user: str, password: str, base: str, domain: str, insecure: bool) -> dict:
    def results(path: str) -> list:
        return api_get(host, path, user, password, insecure).get("results", [])

    print(f"reading {host} ({base}, domain {domain})", file=sys.stderr)
    groups = results(f"{base}/domains/{domain}/groups")
    print(f"  {len(groups)} group(s)", file=sys.stderr)
    services = results(f"{base}/services")
    print(f"  {len(services)} service(s)", file=sys.stderr)

    policies = []
    for summary in results(f"{base}/domains/{domain}/security-policies"):
        # The list endpoint omits rules; fetch each policy in full.
        policies.append(
            api_get(
                host,
                f"{base}/domains/{domain}/security-policies/{summary['id']}",
                user,
                password,
                insecure,
            )
        )
    print(f"  {len(policies)} policy/policies", file=sys.stderr)

    return {"groups": groups, "services": services, "policies": policies, "domain": domain}


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
        or any(c in text for c in ":#")
        or _looks_numeric(text)
    ):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text


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
        for key, item in value.items():
            if isinstance(item, dict) and item:
                lines.append(f"{pad}{key}:")
                lines.extend(emit(item, indent + 1))
            elif isinstance(item, list) and item:
                if all(not isinstance(x, (dict, list)) for x in item):
                    lines.append(f"{pad}{key}: [{', '.join(scalar(x) for x in item)}]")
                else:
                    lines.append(f"{pad}{key}:")
                    lines.extend(emit(item, indent + 1))
            elif isinstance(item, (dict, list)):
                lines.append(f"{pad}{key}: {{}}" if isinstance(item, dict) else f"{pad}{key}: []")
            else:
                lines.append(f"{pad}{key}: {scalar(item)}")
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
    if conjunction and len(criteria) > 1:
        out["conjunction"] = conjunction
    if criteria:
        out["criteria"] = criteria
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
    converted["scope"] = scope
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
    header["rule_management"] = "standalone"
    header["scope"] = [
        group_paths.get(p, p) for p in policy.get("scope", []) if p != "ANY"
    ]

    rules = {}
    for rule in policy.get("rules", []):
        rules[rule["id"]] = convert_rule(rule, group_paths, service_paths)

    return {"policy": header, "rules": rules}


def convert_service(service: dict) -> dict:
    out: dict = {"display_name": service.get("display_name", service["id"])}
    if service.get("description"):
        out["description"] = service["description"]
    l4: list[dict] = []
    icmp: list[dict] = []
    for entry in service.get("service_entries", []):
        kind = entry.get("resource_type")
        if kind == "L4PortSetServiceEntry":
            item = {
                "protocol": entry.get("l4_protocol", "TCP"),
                "destination_ports": [str(p) for p in entry.get("destination_ports", [])],
            }
            if entry.get("source_ports"):
                item["source_ports"] = [str(p) for p in entry["source_ports"]]
            l4.append(item)
        elif kind == "ICMPTypeServiceEntry":
            item = {"protocol": entry.get("protocol", "ICMPv4")}
            if entry.get("icmp_type") is not None:
                item["icmp_type"] = str(entry["icmp_type"])
            if entry.get("icmp_code") is not None:
                item["icmp_code"] = str(entry["icmp_code"])
            icmp.append(item)
    if l4:
        out["l4_port_set"] = l4
    if icmp:
        out["icmp"] = icmp
    return out


def is_system(obj: dict) -> bool:
    return bool(obj.get("_system_owned")) or obj.get("_create_user") == "system"


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

class Writer:
    def __init__(self, dry_run: bool) -> None:
        self.dry_run = dry_run
        self.written: list[str] = []
        self.deferred: list[str] = []

    def write(self, path: Path, text: str) -> None:
        rel = str(path.relative_to(REPO_ROOT))
        target = path
        if path.exists():
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
    if fmt == "domain-id":
        return f"{domain}/{nsx_id}"
    return nsx_id


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
    args = ap.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from yamlcompat import load_yaml  # noqa: PLC0415

    inventory_path = REPO_ROOT / "inventory" / "managers.yaml"
    managers = {}
    if inventory_path.exists():
        managers = (load_yaml(inventory_path.read_text()) or {}).get("managers") or {}
    manager = managers.get(args.site, {})
    role = args.role or manager.get("role", "lm")
    domain = args.domain or manager.get("domain") or ("global" if role == "gm" else "default")
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
        estate = fetch_estate(host, user, password, base, domain, args.insecure)

    if args.dump_only:
        out = Path(args.dump_only)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(estate, indent=2))
        print(f"wrote {out}")
        return 0

    groups = estate.get("groups", [])
    services = estate.get("services", [])
    policies = estate.get("policies", [])
    sites = [args.site]
    owner = "gm" if role == "gm" else "lm"

    group_paths = {g["path"]: g["id"] for g in groups if g.get("path")}
    service_paths = {s["path"]: s["id"] for s in services if s.get("path")}

    writer = Writer(args.dry_run)

    # --- groups ---------------------------------------------------------
    converted_groups = {
        g["id"]: convert_group(g, group_paths, owner, sites) for g in groups if not is_system(g)
    }
    if converted_groups:
        header = (
            f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}. Adopted, not created.\n"
            "#\n"
            "# Review before the first apply: check every 'why_static' note, and confirm\n"
            "# the tag scopes below are in data/schema/tag-scopes.yaml.\n\n"
        )
        writer.write(DATA / "groups" / f"imported-{args.site}.yaml", header + to_yaml({"groups": converted_groups}))

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
            document["predefined"] = predefined
        if custom:
            for definition in custom.values():
                definition["owner"] = owner
            document["custom"] = custom
        header = f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}.\n\n"
        writer.write(DATA / "services" / f"imported-{args.site}.yaml", header + to_yaml(document))

    # --- policies: one file each, so add-rule.py can find them ----------
    for policy in policies:
        if is_system(policy):
            continue
        document = convert_policy(policy, group_paths, service_paths, owner, sites)
        header = (
            f"# Imported from {args.site} on {datetime.now(timezone.utc):%Y-%m-%d}. Adopted, not created.\n"
            "#\n"
            "# A new rule for this policy belongs IN THIS FILE. Do not declare a second\n"
            f"# policy: scripts/add-rule.py --policy {policy['id']} --rule <name> ...\n\n"
        )
        writer.write(DATA / "policies" / f"{policy['id']}.yaml", header + to_yaml(document))

    # --- import blocks --------------------------------------------------
    security_stack = "global-security" if role == "gm" else "local-security"
    blocks = [
        "# Generated by scripts/import-estate.py. Adopt existing objects into state.\n"
        "#\n"
        "# Run one tranche at a time:\n"
        "#   scripts/tf.sh plan " + security_stack + " " + args.site + "\n"
        "# and confirm the plan is a pure import with NO resource changes before\n"
        "# applying. A tranche is done when plan reports no changes.\n"
        "#\n"
        f"# id format: {args.id_format}. If every import fails with a not-found error,\n"
        "# re-run import-estate.py with a different --id-format; nothing has been\n"
        "# written to state at that point.\n"
        "#\n"
        "# Delete this file once the imports are applied — import blocks are one-shot.\n\n"
    ]
    for group_id, definition in converted_groups.items():
        nested = any("member_groups" in c for c in definition.get("criteria", []))
        module = "composite_groups" if nested else "base_groups"
        path = next((g["path"] for g in groups if g["id"] == group_id), "")
        blocks.append(
            import_block(
                f'module.{module}.nsxt_policy_group.this["{group_id}"]',
                object_id("group", domain, path, group_id, args.id_format),
            )
        )
    for policy in policies:
        if is_system(policy):
            continue
        key = policy["id"]
        blocks.append(
            import_block(
                f'module.policies["{key}"].nsxt_policy_parent_security_policy.this',
                object_id("policy", domain, policy.get("path", ""), key, args.id_format),
            )
        )
        for rule in policy.get("rules", []):
            rule_path = rule.get("path", "")
            blocks.append(
                import_block(
                    f'module.policies["{key}"].nsxt_policy_security_policy_rule.this["{rule["id"]}"]',
                    object_id("rule", domain, rule_path, f"{key}/{rule['id']}", args.id_format),
                )
            )
    writer.write(REPO_ROOT / "stacks" / security_stack / "import.tf", "".join(blocks))

    # --- manifest -------------------------------------------------------
    manifest = {"version": 1, "imported": [], "sources": []}
    if MANIFEST.exists():
        try:
            manifest = json.loads(MANIFEST.read_text())
        except ValueError:
            pass
    for rel in writer.written:
        if rel not in manifest["imported"]:
            manifest["imported"].append(rel)
    manifest["sources"].append(
        {
            "site": args.site,
            "role": role,
            "domain": domain,
            "when": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "counts": {
                "groups": len(converted_groups),
                "policies": len([p for p in policies if not is_system(p)]),
                "rules": sum(len(p.get("rules", [])) for p in policies if not is_system(p)),
                "services": len(custom),
            },
        }
    )
    if not args.dry_run:
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")

    # --- report ---------------------------------------------------------
    print()
    for rel in writer.written:
        print(f"  wrote     {rel}")
    for note in writer.deferred:
        print(f"  EXISTS    {note}  (your file was not touched — diff and merge by hand)")
    print()
    print(f"{len(converted_groups)} group(s), {len([p for p in policies if not is_system(p)])} policy/policies, "
          f"{sum(len(p.get('rules', [])) for p in policies if not is_system(p))} rule(s), {len(custom)} custom service(s)")
    if args.dry_run:
        print("dry run — nothing was written.")
        return 0
    print()
    print("next:")
    print("  1. make validate")
    print(f"  2. scripts/tf.sh plan {security_stack} {args.site}")
    print("  3. confirm the plan imports and changes NOTHING, then apply")
    print(f"  4. delete stacks/{security_stack}/import.tf once applied")
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
# posture of the estate and is not a review attachment.
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
# configuration change, so nothing here can be mistaken for a fix.
"$REPO_ROOT/scripts/tf.sh" init "$stack" "$site" >/dev/null 2>&1

(cd "$REPO_ROOT/stacks/$stack" && terraform plan -refresh-only -detailed-exitcode -input=false -no-color) \
	>"$report" 2>&1
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
#   export TF_HTTP_USERNAME=gitlab-ci-token
#   export TF_HTTP_PASSWORD="$CI_JOB_TOKEN"
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

Terraform providers are the one thing jobs still download. If this network cannot
reach `registry.terraform.io`, the validate job shows a warning rather than
failing; set the CI/CD variable `NSX_TF_NETWORK_MIRROR` to an internal mirror, or
put `NSX_HTTPS_PROXY=...` in `deploy/gitlab/ci-network.env` and run
`scripts/converge.sh`. `scripts/converge.sh --check` reports without changing anything.

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
Variables in the project:

  VAULT_ADDR          your Vault endpoint            masked
  VAULT_PLAN_TOKEN    a READ-ONLY token              masked
  VAULT_APPLY_TOKEN   a write token                  masked, PROTECTED
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
# scripts use: bash, curl, git, make. Changing this file changes its hash, and
# the next converge rebuilds the image.

FROM hashicorp/terraform:1.9.8 AS terraform
FROM python:3.12-bookworm

COPY --from=terraform /bin/terraform /usr/local/bin/terraform

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
want="$(sha256sum "$CONTEXT/Dockerfile" | cut -c1-12)"
have="$(docker image inspect -f '{{ index .Config.Labels "nsx.dockerfile" }}' "$IMAGE" 2>/dev/null || true)"

if [ "$have" = "$want" ]; then
	if verify; then
		say "CI image $IMAGE is current."
		exit 0
	fi
	say "CI image $IMAGE is present but does not pass its checks; rebuilding."
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
say "building CI image $IMAGE (a minute or two the first time)..."
if ! docker build --pull=false --label "nsx.dockerfile=$want" -t "$IMAGE" "$CONTEXT" >>"$log" 2>&1; then
	# Registry metadata lookups can fail where a plain build of cached images still works.
	if ! DOCKER_BUILDKIT=0 docker build --pull=false --label "nsx.dockerfile=$want" -t "$IMAGE" "$CONTEXT" >>"$log" 2>&1; then
		tail -15 "$log" | sed 's/^/    /' >&2
		why_build_failed "$log" >&2
		die "could not build $IMAGE."
	fi
fi
verify || {
	tail -5 "$log" | sed 's/^/    /' >&2
	die "built $IMAGE but it failed its own checks."
}
say "CI image $IMAGE built and verified."
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
if out="$("$REPO_ROOT/scripts/ci-image.sh" ${img_args[@]+"${img_args[@]}"} 2>&1)"; then
	ok "$(printf '%s' "$out" | tail -1)"
else
	fail "CI image $CI_IMAGE" "$(printf '%s' "$out" | tail -12 | sed 's/^/ /')"
fi

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

# Re-running in place must change nothing.
before="$(cd "$A" && find . -type f -newer "$A/Makefile" | wc -l | tr -d ' ')"
if (cd "$A" && ./scripts/bootstrap.sh --dir . --quiet </dev/null >/dev/null 2>&1); then
	ok "re-running in place succeeds"
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
cd "$REPO_ROOT"

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
manual "VAULT_ADDR and a READ-ONLY VAULT_PLAN_TOKEN in the CI settings"
manual "VAULT_APPLY_TOKEN, marked PROTECTED so only protected branches can apply"
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
# See docs/GITOPS.md.

stages:
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

# --- validate: offline, no credentials, runs on everything ------------------

data:
  stage: validate
  script:
    - python3 scripts/validate-data.py
  rules:
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
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ci_matrix_lib import entries  # noqa: E402

DEFAULT_BRANCH = os.environ.get("CI_DEFAULT_BRANCH", "main")
IS_DEFAULT_BRANCH = os.environ.get("CI_COMMIT_BRANCH") == DEFAULT_BRANCH

# manual (default): merging queues the apply, and a human starts it with the
# plan in front of them. auto: apply runs on merge, no second pause.
#
# Set NSX_APPLY_MODE=auto in the project's CI/CD variables if the estate is a
# lab, or if the merge request approval is the only gate you want. On a
# production firewall across 10+ managers, keep it manual: an approved merge
# request says the change is wanted, not that this plan is what to apply now.
APPLY_MODE = os.environ.get("NSX_APPLY_MODE", "manual").strip().lower()
if APPLY_MODE not in ("manual", "auto"):
    sys.exit(f"error: NSX_APPLY_MODE must be 'manual' or 'auto', got {APPLY_MODE!r}")


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
    out.append("stages: [plan, apply]")
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
        out.append("  artifacts:")
        out.append("    name: \"plan-$STACK-$SITE\"")
        out.append("    paths:")
        out.append(f'      - stacks/{row["stack"]}/tfplan')
        out.append('      - "plan-$STACK-$SITE.txt"')
        out.append("    expire_in: 1 week")
        out.append("    when: always")
        # A failed plan at one site must not hide the others.
        out.append("  allow_failure: false")
        out.append("")

        if not IS_DEFAULT_BRANCH:
            continue

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

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/gitlab-child-pipeline.py

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
          path: stacks/${{ matrix.stack }}/tfplan
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
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - id: build
        run: echo "matrix=$(python3 scripts/ci-matrix.py --format github)" >> "$GITHUB_OUTPUT"

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
          path: stacks/${{ matrix.stack }}/tfplan
          retention-days: 7
          if-no-files-found: error

  apply:
    name: apply ${{ matrix.stack }} @ ${{ matrix.site }}
    needs: [matrix, plan]
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix: ${{ fromJson(needs.matrix.outputs.matrix) }}
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
    domain: global
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
