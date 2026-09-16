#!/bin/bash
# Configuration loading for kikori.
#
# Precedence (weakest first):
#   built-in defaults
#   < ${XDG_CONFIG_HOME:-~/.config}/kikori/config.sh   (per-user)
#   < <main checkout>/.kikori/config.sh                (per-repository)
#   < environment variables                          (per-invocation)
#   < command-line flags                             (parsed by each subcommand)
#
# Config files are sourced as bash, so they can define both KIKORI_* variables and
# hook functions (kikori_slug / kikori_post_create / kikori_branch_name). This is the
# same trust model as a Makefile or .envrc: cloning a repository does not run
# its config — only invoking kikori inside it does. See README "Security model".

if [ -n "${_KIKORI_CONFIG_SH_LOADED:-}" ]; then
    return 0
fi
_KIKORI_CONFIG_SH_LOADED=1

# Variables that config files may set and the environment may override.
_KIKORI_CONFIG_VARS="KIKORI_REMOTE KIKORI_MAIN_BRANCH KIKORI_BASE_BRANCH KIKORI_WORKTREES_DIR \
KIKORI_COPY_FILE KIKORI_PROTECTED_BRANCHES KIKORI_CLEANERS"

# kikori_resolve_main_root: prints the main checkout path. Works from inside any
# worktree because it derives the path from the shared .git directory, not from
# the current worktree.
kikori_resolve_main_root() {
    local common_dir
    common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "${common_dir}" ] || return 1
    # The common dir is <main>/.git for a normal checkout. A bare repo has no
    # main checkout to manage, which kikori does not support.
    case "${common_dir}" in
        */.git) printf '%s\n' "${common_dir%/.git}" ;;
        *) return 1 ;;
    esac
}

# kikori_load_config <main_root>
# Sources the user and repository config files, then re-applies values that
# were already present in the environment so that env vars win over config.
kikori_load_config() {
    local main_root="$1"
    local var env_snapshot=""

    # Snapshot env-provided values before config files can overwrite them.
    for var in ${_KIKORI_CONFIG_VARS}; do
        if [ -n "$(eval "printf '%s' \"\${${var}+x}\"")" ]; then
            env_snapshot="${env_snapshot}${var}=$(eval "printf '%q' \"\${${var}}\"")"$'\n'
        fi
    done

    local user_config="${XDG_CONFIG_HOME:-${HOME}/.config}/kikori/config.sh"
    # shellcheck disable=SC1090
    [ -f "${user_config}" ] && . "${user_config}"
    _kikori_source_repo_config "${main_root}"

    local line
    while IFS= read -r line; do
        [ -n "${line}" ] && eval "${line}"
    done <<< "${env_snapshot}"

    # Defaults for anything still unset. The main branch is detected from the
    # remote HEAD so repositories using master/develop work without config.
    # When detection fails the value stays empty and commands that depend on it
    # fail closed via kikori_require_main_branch — guessing wrong here would
    # base new work on, or judge deletions against, the wrong branch.
    KIKORI_REMOTE="${KIKORI_REMOTE:-origin}"
    if [ -z "${KIKORI_MAIN_BRANCH:-}" ]; then
        KIKORI_MAIN_BRANCH="$(git symbolic-ref --short "refs/remotes/${KIKORI_REMOTE}/HEAD" 2>/dev/null | sed "s|^${KIKORI_REMOTE}/||")"
        if [ -z "${KIKORI_MAIN_BRANCH}" ]; then
            local guess
            for guess in main master; do
                if git show-ref --verify -q "refs/remotes/${KIKORI_REMOTE}/${guess}"; then
                    KIKORI_MAIN_BRANCH="${guess}"
                    break
                fi
            done
        fi
    fi
    if [ -n "${KIKORI_MAIN_BRANCH}" ]; then
        KIKORI_BASE_BRANCH="${KIKORI_BASE_BRANCH:-${KIKORI_REMOTE}/${KIKORI_MAIN_BRANCH}}"
    fi
    KIKORI_WORKTREES_DIR="${KIKORI_WORKTREES_DIR:-${main_root}-worktrees}"
    KIKORI_COPY_FILE="${KIKORI_COPY_FILE:-.kikori-copy}"
    KIKORI_PROTECTED_BRANCHES="${KIKORI_PROTECTED_BRANCHES:-}"
    KIKORI_CLEANERS="${KIKORI_CLEANERS:-}"
}

kikori_require_main_branch() {
    [ -n "${KIKORI_MAIN_BRANCH:-}" ] && return 0
    log_error "could not determine the main branch of remote '${KIKORI_REMOTE}'"
    log_detail "fix it with: git remote set-head ${KIKORI_REMOTE} --auto"
    log_detail "or set KIKORI_MAIN_BRANCH in .kikori/config.sh"
    return 1
}

# --- repository config trust ----------------------------------------------------
# ~/.config/kikori/config.sh is in the user's own trust domain and is always
# sourced. <repo>/.kikori/config.sh arrives with the repository, so sourcing it
# would run repository-supplied code: it is only sourced after the user trusts
# that exact content (`kikori trust`, or the interactive prompt). Recording the
# content hash, not just the path, means a later edit — e.g. from a pulled
# commit — requires re-trusting.

kikori_trust_file() {
    printf '%s/kikori/trusted\n' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

kikori_config_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

kikori_is_trusted() {
    local path="$1" hash="$2" trust_file
    trust_file="$(kikori_trust_file)"
    [ -f "${trust_file}" ] || return 1
    grep -Fxq "${hash}  ${path}" "${trust_file}"
}

kikori_record_trust() {
    local path="$1" hash="$2" trust_file tmp
    trust_file="$(kikori_trust_file)"
    mkdir -p "$(dirname "${trust_file}")"
    tmp="${trust_file}.tmp.$$"
    { [ -f "${trust_file}" ] && grep -vF "  ${path}" "${trust_file}"; true; } > "${tmp}"
    printf '%s  %s\n' "${hash}" "${path}" >> "${tmp}"
    mv "${tmp}" "${trust_file}"
}

_kikori_source_repo_config() {
    local main_root="$1" config hash
    config="${main_root}/.kikori/config.sh"
    [ -f "${config}" ] || return 0
    config="$(cd "$(dirname "${config}")" && pwd)/$(basename "${config}")"
    hash="$(kikori_config_hash "${config}")"
    if kikori_is_trusted "${config}" "${hash}"; then
        # shellcheck disable=SC1090
        . "${config}"
        return 0
    fi
    log_warn "${config} is not trusted (new or changed since it was last trusted)"
    if [ -t 0 ] && [ -t 2 ]; then
        log_step "Review the file, then trust and load it? (y/N)" "🔐"
        local answer
        log_prompt answer
        if [[ "${answer}" =~ ^[Yy]$ ]]; then
            kikori_record_trust "${config}" "${hash}"
            # shellcheck disable=SC1090
            . "${config}"
            return 0
        fi
    fi
    log_error "refusing to run with an untrusted repository config"
    log_detail "review it, then run: kikori trust"
    exit 2
}

# kikori_has_hook <name>: true when a config file defined the hook function.
kikori_has_hook() {
    declare -F "$1" >/dev/null 2>&1
}

# Default branch naming: YYYYMMDD-<slug>, or YYYYMMDD-HHMMSS without a slug.
# Overridable by defining kikori_branch_name in a config file.
kikori_default_branch_name() {
    local slug="$1"
    if [ -n "${slug}" ]; then
        printf '%s-%s\n' "$(date +%Y%m%d)" "${slug}"
    else
        date +%Y%m%d-%H%M%S
    fi
}

# kikori_list_cleaners <main_root>
# Prints "name<TAB>path" per cleaner: executables in <main_root>/.kikori/cleaners/
# plus entries from KIKORI_CLEANERS (whitespace-separated paths, resolved against
# the main root when relative). Later duplicates by name are ignored so a
# KIKORI_CLEANERS entry cannot silently shadow a repo cleaner.
kikori_list_cleaners() {
    local main_root="$1"
    local seen=" " f name

    for f in "${main_root}/.kikori/cleaners"/*; do
        [ -f "${f}" ] && [ -x "${f}" ] || continue
        name="$(basename "${f}")"
        case "${seen}" in *" ${name} "*) continue ;; esac
        seen="${seen}${name} "
        printf '%s\t%s\n' "${name}" "${f}"
    done

    for f in ${KIKORI_CLEANERS}; do
        case "${f}" in /*) ;; *) f="${main_root}/${f}" ;; esac
        [ -f "${f}" ] && [ -x "${f}" ] || { log_warn "cleaner is not executable, skipping: ${f}"; continue; }
        name="$(basename "${f}")"
        case "${seen}" in *" ${name} "*) continue ;; esac
        seen="${seen}${name} "
        printf '%s\t%s\n' "${name}" "${f}"
    done
}
