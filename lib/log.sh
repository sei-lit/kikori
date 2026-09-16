#!/bin/bash
# Shared logging library for kikori subcommands.
#
# Output conventions:
#   - Everything goes to stderr (keeps stdout clean for pipelines).
#   - All lines use 2-space indent; log_detail uses 4-space to show hierarchy.
#   - No headings or horizontal rules; groups are separated by a single blank
#     line managed by the _kl_gap_* helpers.
#
# macOS ships /bin/bash 3.2. A variable reference immediately followed by a
# non-ASCII character can break there, so variables are always written with
# braces.

if [ -n "${_KIKORI_LOG_SH_LOADED:-}" ]; then
    return 0
fi
_KIKORI_LOG_SH_LOADED=1

# --- style tokens ------------------------------------------------------------
# Colors only when stderr is a TTY, NO_COLOR is unset, and TERM is not dumb.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    STYLE_RESET=$'\033[0m'
    STYLE_BOLD=$'\033[1m'
    STYLE_DIM=$'\033[2m'
    STYLE_SUCCESS=$'\033[0;32m'
    STYLE_FAIL=$'\033[0;31m'
    STYLE_WARN=$'\033[0;33m'
    STYLE_INFO=$'\033[0;36m'
else
    STYLE_RESET=''
    STYLE_BOLD=''
    STYLE_DIM=''
    STYLE_SUCCESS=''
    STYLE_FAIL=''
    STYLE_WARN=''
    STYLE_INFO=''
fi

GLYPH_OK='✓'
GLYPH_STEP='▶'
GLYPH_PROMPT='▸'
GLYPH_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Spinner animation only when stderr is a TTY.
if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
    _KL_USE_SPINNER=1
else
    _KL_USE_SPINNER=0
fi

# --- blank-line management between groups -------------------------------------
_KL_GAP_OPEN=1
_kl_gap_begin()   { if [ "${_KL_GAP_OPEN}" != "1" ]; then printf '\n' >&2; fi; _KL_GAP_OPEN=0; }
_kl_gap_content() { _KL_GAP_OPEN=0; }
_kl_gap_end()     { _KL_GAP_OPEN=1; }

# Force a blank line regardless of previous output. Used to separate from
# external output the gap tracker cannot see (e.g. the shell prompt).
log_blank() { printf '\n' >&2; _kl_gap_end; }

# --- standard log functions ----------------------------------------------------
log_info()    { printf '  %b[INFO]%b    %s\n' "${STYLE_INFO}"    "${STYLE_RESET}" "$*" >&2; _kl_gap_content; }
log_success() { printf '  %b[SUCCESS]%b %s\n' "${STYLE_SUCCESS}" "${STYLE_RESET}" "$*" >&2; _kl_gap_content; }
log_warn()    { printf '  %b[WARN]%b    %s\n' "${STYLE_WARN}"    "${STYLE_RESET}" "$*" >&2; _kl_gap_content; }
log_error()   { printf '  %b[ERROR]%b   %s\n' "${STYLE_FAIL}"    "${STYLE_RESET}" "$*" >&2; _kl_gap_content; }

# log_step "<label>" [<prefix>] — group heading; second arg overrides the glyph.
log_step() {
    local label="$1"
    local prefix="${2:-${GLYPH_STEP}}"
    _kl_gap_begin
    printf '  %b%s%b  %s\n' "${STYLE_INFO}${STYLE_BOLD}" "${prefix}" "${STYLE_RESET}" "${label}" >&2
}

log_detail() { printf '    %b%s%b\n' "${STYLE_DIM}" "$*" "${STYLE_RESET}" >&2; _kl_gap_content; }

log_ok() { printf '  %b%s%b  %s\n' "${STYLE_SUCCESS}" "${GLYPH_OK}" "${STYLE_RESET}" "$*" >&2; _kl_gap_content; }

# --- synchronous inline progress -----------------------------------------------
# Renders "<prefix>  <label>... done/skipped/failed" on one line.
log_step_inline() {
    local label="$1"
    local prefix="${2:-${GLYPH_STEP}}"
    _kl_gap_begin
    printf '  %b  %s... ' "${prefix}" "${label}" >&2
}

log_step_done() {
    printf '%b%bdone%b\n' "${STYLE_SUCCESS}" "${STYLE_BOLD}" "${STYLE_RESET}" >&2
    _kl_gap_content
}

log_step_skip() {
    local note="${1:-}"
    if [ -n "${note}" ]; then
        printf '%b%bskipped%b %b(%s)%b\n' \
            "${STYLE_WARN}" "${STYLE_BOLD}" "${STYLE_RESET}" \
            "${STYLE_DIM}" "${note}" "${STYLE_RESET}" >&2
    else
        printf '%b%bskipped%b\n' "${STYLE_WARN}" "${STYLE_BOLD}" "${STYLE_RESET}" >&2
    fi
    _kl_gap_content
}

log_step_fail() {
    printf '%b%bfailed%b\n' "${STYLE_FAIL}" "${STYLE_BOLD}" "${STYLE_RESET}" >&2
    _kl_gap_content
}

# --- interactive prompt ---------------------------------------------------------
# Draws "  ▸ " as a readline prompt. ANSI sequences are wrapped in \001/\002 so
# readline computes the cursor position correctly. Falls back to plain read when
# stdin is not a TTY (CI / piped input).
log_prompt() {
    local __lp_var="${1:?log_prompt: pass the target variable name as \$1}"
    local __lp_prefix="${2:-${GLYPH_PROMPT}}"
    local __lp_str

    if [ -t 0 ]; then
        __lp_str=$'\001'"${STYLE_INFO}"$'\002'"  ${__lp_prefix} "$'\001'"${STYLE_RESET}"$'\002'
        # shellcheck disable=SC2229  # dynamic assignment through a variable name is intended
        read -r -e -p "${__lp_str}" "${__lp_var}" || printf -v "${__lp_var}" '%s' ''
        printf '\n' >&2
        _kl_gap_end
    else
        printf '  %b%s%b ' "${STYLE_INFO}" "${__lp_prefix}" "${STYLE_RESET}" >&2
        # shellcheck disable=SC2229
        read -r "${__lp_var}" || printf -v "${__lp_var}" '%s' ''
        # Without a TTY the Enter key is not echoed, so terminate the line here.
        printf '\n\n' >&2
        _kl_gap_end
    fi
}

# --- spinner ---------------------------------------------------------------------
# spin_pid <pid> <label> [prefix]
# Waits for a background PID while drawing a spinner and elapsed seconds.
# Degrades to start/finish lines without a TTY. Returns the process exit code.
spin_pid() {
    local pid="$1"
    local label="$2"
    local prefix="${3:-${GLYPH_STEP}}"
    local frames_count="${#GLYPH_SPIN[@]}"
    local start rc=0 total

    _kl_gap_begin
    start=$(date +%s)

    if [ "${_KL_USE_SPINNER}" != "1" ]; then
        printf '  %b  %s...\n' "${prefix}" "${label}" >&2
        wait "${pid}"
        rc=$?
        total=$(( $(date +%s) - start ))
        if [ "${rc}" -eq 0 ]; then
            printf '  %b  %s... done (%ds)\n' "${prefix}" "${label}" "${total}" >&2
        else
            printf '  %b  %s... failed (%ds)\n' "${prefix}" "${label}" "${total}" >&2
        fi
        _kl_gap_content
        return "${rc}"
    fi

    # Hide the cursor (the caller's trap must restore it with ?25h).
    printf '\033[?25l' >&2

    local i=0 elapsed
    while kill -0 "${pid}" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        printf '\r\033[K  %b  %s... %b%s%b %b%ds%b ' \
            "${prefix}" "${label}" \
            "${STYLE_INFO}" "${GLYPH_SPIN[${i}]}" "${STYLE_RESET}" \
            "${STYLE_DIM}" "${elapsed}" "${STYLE_RESET}" >&2
        i=$(( (i + 1) % frames_count ))
        sleep 0.1
    done

    wait "${pid}"
    rc=$?
    total=$(( $(date +%s) - start ))
    printf '\033[?25h' >&2
    if [ "${rc}" -eq 0 ]; then
        printf '\r\033[K  %b  %s... %bdone%b %b(%ds)%b\n' \
            "${prefix}" "${label}" \
            "${STYLE_SUCCESS}${STYLE_BOLD}" "${STYLE_RESET}" \
            "${STYLE_DIM}" "${total}" "${STYLE_RESET}" >&2
    else
        printf '\r\033[K  %b  %s... %bfailed%b %b(%ds)%b\n' \
            "${prefix}" "${label}" \
            "${STYLE_FAIL}${STYLE_BOLD}" "${STYLE_RESET}" \
            "${STYLE_DIM}" "${total}" "${STYLE_RESET}" >&2
    fi
    _kl_gap_content
    return "${rc}"
}
