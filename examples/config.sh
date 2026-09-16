# Example kikori configuration.
#
# Place per-user settings in  ${XDG_CONFIG_HOME:-~/.config}/kikori/config.sh
# and per-repository settings in  <repo>/.kikori/config.sh  (requires
# `kikori trust` — see README "Security model").
#
# This file is sourced as bash: plain variables plus optional hook functions.

# --- variables -------------------------------------------------------------------

# Remote and main branch. Detected automatically (remote HEAD) when unset.
#KIKORI_REMOTE="origin"
#KIKORI_MAIN_BRANCH="main"

# Default base for new session worktrees.
#KIKORI_BASE_BRANCH="origin/main"

# Where session worktrees are created. Default: "<main checkout>-worktrees".
#KIKORI_WORKTREES_DIR="${HOME}/worktrees/myproject"

# File listing untracked paths to copy into each new worktree
# (root-relative, glob allowed, one per line, # comments). Default: .kikori-copy
#KIKORI_COPY_FILE=".kikori-copy"

# Extra branches cleanup must never touch (whitespace-separated).
# The main branch, the current branch, and branches checked out in worktrees
# outside KIKORI_WORKTREES_DIR are always protected.
#KIKORI_PROTECTED_BRANCHES="develop release/next"

# Cleaner plugins outside <repo>/.kikori/cleaners/ (whitespace-separated paths,
# relative to the main checkout). Executables in .kikori/cleaners/ are
# discovered automatically.
#KIKORI_CLEANERS="tools/my-cleaner"

# --- hooks -----------------------------------------------------------------------

# Branch slug from the task description you type at `kikori start`.
# Output that is not slug-shaped ([a-z0-9-], <= 50 chars) is discarded and the
# timestamp fallback is used, so it is safe to let an LLM generate it.
#kikori_slug() {
#    claude -p --model haiku "Turn this task description into a git branch slug.
#Rules: lowercase letters, digits and hyphens only; at most 50 characters;
#output the slug alone with no explanation; never ask questions.
#Task: $1"
#}

# Branch name from the slug (empty when slug generation was skipped).
# Default: YYYYMMDD-<slug>, or YYYYMMDD-HHMMSS without a slug.
#kikori_branch_name() {
#    if [ -n "$1" ]; then printf 'sessions/%s-%s\n' "$(date +%Y%m%d)" "$1"
#    else printf 'sessions/%s\n' "$(date +%Y%m%d-%H%M%S)"; fi
#}

# Project setup after the worktree is created and untracked files are copied.
# Failure warns but keeps the worktree. Example: an iOS project that relinks
# copied tool symlinks, installs git hooks, and creates a per-worktree
# simulator named to match examples/cleaners/xcode-simulators.
#kikori_post_create() {
#    local worktree="$1" branch="$2" base="$3"
#    make -C "${worktree}/ios" worktree-setup
#    xcrun simctl create "wt-$(basename "${worktree}")" "iPhone 16"
#}
