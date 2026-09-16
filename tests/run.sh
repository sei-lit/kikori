#!/bin/bash
# kikori test suite. Runs against throwaway git repositories with a stubbed gh,
# so no network or GitHub access is needed.
#
# USAGE: tests/run.sh [test-name-filter]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIKORI_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
KIKORI="${KIKORI_ROOT}/bin/kikori"
FILTER="${1:-}"

PASS=0
FAIL=0

# --- harness ---------------------------------------------------------------------

fail() { printf '    FAIL: %s\n' "$*"; CASE_FAILED=1; }

assert_eq() {
    [ "$1" = "$2" ] || fail "expected [$2], got [$1] ${3:+($3)}"
}

assert_contains() {
    case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:+($3)}"$'\n'"--- output ---"$'\n'"$1" ;; esac
}

assert_not_contains() {
    case "$1" in *"$2"*) fail "expected output NOT to contain [$2] ${3:+($3)}" ;; esac
}

run_test() {
    local name="$1" rc
    if [ -n "${FILTER}" ]; then
        case "${name}" in *"${FILTER}"*) ;; *) return 0 ;; esac
    fi
    SANDBOX="$(mktemp -d)"
    printf '%s\n' "${name}"
    # The subshell isolates cwd and environment changes; assertion failures are
    # carried out through the exit code.
    (
        setup_sandbox
        cd "${SANDBOX}/repo" || exit 1
        CASE_FAILED=0
        "${name}"
        exit "${CASE_FAILED}"
    )
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf '    ok\n'
    else
        FAIL=$((FAIL + 1))
    fi
    rm -rf "${SANDBOX}"
}

# Creates a local "remote" and a clone with one commit on main, plus the gh
# stub wiring. Every test starts here.
setup_sandbox() {
    export HOME="${SANDBOX}/home"
    export XDG_STATE_HOME="${SANDBOX}/home/.state"
    export XDG_CONFIG_HOME="${SANDBOX}/home/.config"
    export GH_STUB_DIR="${SANDBOX}/gh-stub"
    export PATH="${TESTS_DIR}/stubs:${PATH}"
    mkdir -p "${HOME}" "${GH_STUB_DIR}/merged"
    printf 'acme/repo\n' > "${GH_STUB_DIR}/repo"
    : > "${GH_STUB_DIR}/remote-commits"

    git init -q --bare "${SANDBOX}/remote.git"
    git clone -q "${SANDBOX}/remote.git" "${SANDBOX}/repo" 2>/dev/null
    (
        cd "${SANDBOX}/repo" || exit 1
        git config user.email test@example.com
        git config user.name test
        git commit -q --allow-empty -m init
        git branch -M main
        git push -q origin main
        git remote set-head origin --auto >/dev/null
    )
}

# Adds a branch with one commit, pushes main so the branch tip is contained in
# origin/main (classification proof 2), and registers a merged PR in the stub.
make_merged_branch() {
    local branch="$1" oid
    git checkout -q -b "${branch}"
    git commit -q --allow-empty -m "work on ${branch}"
    oid="$(git rev-parse HEAD)"
    git checkout -q main
    git merge -q --ff-only "${branch}"
    git push -q origin main
    git fetch -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"
}

cleanup_cmd() {
    "${KIKORI}" cleanup "$@" </dev/null 2>&1
}

# --- start ------------------------------------------------------------------------

test_start_creates_worktree_and_branch() {
    local out
    out="$("${KIKORI}" start --task "" --base origin/main </dev/null 2>&1)"
    assert_contains "${out}" "Worktree ready"
    local wt
    wt="$(git worktree list --porcelain | grep -c '^worktree ')"
    assert_eq "${wt}" "2" "main checkout + new worktree"
    [ -d "${SANDBOX}/repo-worktrees" ] || fail "worktrees dir not created"
}

test_start_dry_run_creates_nothing() {
    local out
    out="$("${KIKORI}" start --dry-run --task "" --base origin/main </dev/null 2>&1)"
    assert_contains "${out}" "dry-run"
    [ -d "${SANDBOX}/repo-worktrees" ] && fail "dry-run created the worktrees dir"
    assert_eq "$(git worktree list --porcelain | grep -c '^worktree ')" "1"
}

test_start_slug_hook_names_branch() {
    mkdir -p "${XDG_CONFIG_HOME}/kikori"
    printf 'kikori_slug() { echo "My-Fancy-Feature"; }\n' > "${XDG_CONFIG_HOME}/kikori/config.sh"
    local out
    out="$("${KIKORI}" start --task "something" --base origin/main </dev/null 2>&1)"
    git rev-parse --verify -q "refs/heads/$(date +%Y%m%d)-my-fancy-feature" >/dev/null \
        || fail "slug-derived branch not created: ${out}"
}

test_start_rejects_prose_slug() {
    mkdir -p "${XDG_CONFIG_HOME}/kikori"
    printf 'kikori_slug() { echo "Could you clarify what feature you mean?"; }\n' > "${XDG_CONFIG_HOME}/kikori/config.sh"
    local out
    out="$("${KIKORI}" start --task "something" --base origin/main </dev/null 2>&1)"
    assert_contains "${out}" "not slug-shaped"
}

test_start_copies_unmanaged_paths() {
    printf 'local.settings\n' > .kikori-copy
    git add .kikori-copy && git commit -q -m copyfile && git push -q origin main
    printf 'secret\n' > local.settings
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    assert_eq "$(cat "${wt}/local.settings" 2>/dev/null)" "secret" "copied file content"
}

test_start_post_create_hook_runs_in_new_worktree() {
    mkdir -p "${XDG_CONFIG_HOME}/kikori"
    # shellcheck disable=SC2016
    printf 'kikori_post_create() { echo "$1:$2:$3" > "$1/hook-ran"; }\n' > "${XDG_CONFIG_HOME}/kikori/config.sh"
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    [ -f "${wt}/hook-ran" ] || fail "post-create hook did not run"
    assert_contains "$(cat "${wt}/hook-ran")" ":origin/main"
}

# --- config trust -------------------------------------------------------------------

test_repo_config_untrusted_fails_closed() {
    mkdir -p .kikori
    printf 'KIKORI_PROTECTED_BRANCHES="keep-me"\n' > .kikori/config.sh
    local out rc
    out="$("${KIKORI}" start --dry-run --task "" --base origin/main </dev/null 2>&1)"; rc=$?
    assert_eq "${rc}" "2" "exit code"
    assert_contains "${out}" "untrusted"
}

test_trust_then_config_loads() {
    mkdir -p .kikori
    printf 'KIKORI_WORKTREES_DIR="%s/custom-wt"\n' "${SANDBOX}" > .kikori/config.sh
    "${KIKORI}" trust </dev/null 2>&1 >/dev/null || fail "trust failed"
    local out
    out="$("${KIKORI}" start --dry-run --task "" --base origin/main </dev/null 2>&1)"
    assert_contains "${out}" "${SANDBOX}/custom-wt/" "config took effect"
    # Changing the file invalidates the trust.
    printf '\n# changed\n' >> .kikori/config.sh
    out="$("${KIKORI}" start --dry-run --task "" --base origin/main </dev/null 2>&1)"
    assert_contains "${out}" "untrusted" "edit must invalidate trust"
}

# --- cleanup: classification ----------------------------------------------------------

test_cleanup_deletes_merged_branch_and_worktree() {
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt branch
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    branch="$(basename "${wt}")"
    git -C "${wt}" commit -q --allow-empty -m work
    local oid; oid="$(git -C "${wt}" rev-parse HEAD)"
    git checkout -q main && git merge -q --ff-only "${branch}" && git push -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"

    local out
    out="$(cleanup_cmd --yes)"
    assert_contains "${out}" "Done (1 branch(es), 1 worktree(s)"
    git rev-parse --verify -q "refs/heads/${branch}" >/dev/null && fail "branch still exists"
    [ -d "${wt}" ] && fail "worktree still exists"
}

test_cleanup_skips_unmerged_branch() {
    git branch unmerged-work
    local out
    out="$(cleanup_cmd --dry-run)"
    assert_contains "${out}" "Nothing to delete"
}

test_cleanup_pr_merged_to_other_base_is_not_auto() {
    # Same-name PR merged into a release branch: proof 1 must not fire.
    git checkout -q -b feature
    git commit -q --allow-empty -m work
    local oid; oid="$(git rev-parse HEAD)"
    git checkout -q main
    printf 'acme/repo release/1.0 %s\n' "${oid}" > "${GH_STUB_DIR}/merged/feature"
    local out
    out="$(cleanup_cmd --dry-run)"
    assert_not_contains "${out}" "To be deleted"
}

test_cleanup_unprovable_branch_needs_review() {
    git checkout -q -b maybe-merged
    git commit -q --allow-empty -m "local only"
    local oid; oid="$(git rev-parse HEAD)"
    git checkout -q main
    # A merged PR exists, but the tip differs and is not contained in main.
    printf 'acme/repo main %s\n' "0000000000000000000000000000000000000000" > "${GH_STUB_DIR}/merged/maybe-merged"
    local out
    out="$(cleanup_cmd --dry-run)"
    assert_contains "${out}" "Needs review"
    assert_contains "${out}" "maybe-merged"
    git rev-parse --verify -q refs/heads/maybe-merged >/dev/null || fail "branch was deleted"
}

test_cleanup_dirty_worktree_needs_review_then_force_deletes() {
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt branch
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    branch="$(basename "${wt}")"
    git -C "${wt}" commit -q --allow-empty -m work
    local oid; oid="$(git -C "${wt}" rev-parse HEAD)"
    git checkout -q main && git merge -q --ff-only "${branch}" && git push -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"
    printf 'wip\n' > "${wt}/uncommitted.txt"

    local out
    out="$(cleanup_cmd --yes)"
    assert_contains "${out}" "uncommitted changes"
    [ -d "${wt}" ] || fail "dirty worktree was deleted without --force"

    out="$(cleanup_cmd --yes --force)"
    [ -d "${wt}" ] && fail "dirty worktree survived --force"
    git rev-parse --verify -q "refs/heads/${branch}" >/dev/null && fail "branch survived --force"
}

# --- cleanup: --only ---------------------------------------------------------------

test_cleanup_only_branches_blocks_worktree_backed_branch() {
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt branch
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    branch="$(basename "${wt}")"
    git -C "${wt}" commit -q --allow-empty -m work
    local oid; oid="$(git -C "${wt}" rev-parse HEAD)"
    git checkout -q main && git merge -q --ff-only "${branch}" && git push -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"

    local out
    out="$(cleanup_cmd --only branches --yes)"
    assert_contains "${out}" "include the 'worktrees' target"
    [ -d "${wt}" ] || fail "worktree deleted despite --only branches"
    git rev-parse --verify -q "refs/heads/${branch}" >/dev/null || fail "branch deleted despite being blocked"
    # And --force must not bypass the block either.
    out="$(cleanup_cmd --only branches --yes --force)"
    git rev-parse --verify -q "refs/heads/${branch}" >/dev/null || fail "branch deleted by --force despite existing worktree"
}

test_cleanup_only_worktrees_keeps_branch() {
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt branch
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    branch="$(basename "${wt}")"
    git -C "${wt}" commit -q --allow-empty -m work
    local oid; oid="$(git -C "${wt}" rev-parse HEAD)"
    git checkout -q main && git merge -q --ff-only "${branch}" && git push -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"

    local out
    out="$(cleanup_cmd --only worktrees --yes)"
    [ -d "${wt}" ] && fail "worktree still exists"
    git rev-parse --verify -q "refs/heads/${branch}" >/dev/null || fail "branch was deleted despite --only worktrees"
}

test_cleanup_only_unknown_target_errors() {
    local out rc
    out="$(cleanup_cmd --only nonsense)"; rc=$?
    assert_eq "${rc}" "2"
    assert_contains "${out}" "unknown cleanup target"
}

# --- cleanup: cleaner plugins -----------------------------------------------------------

# A cleaner that records its invocations and deletes ids from a state dir.
install_fake_cleaner() {
    mkdir -p .kikori/cleaners "${SANDBOX}/cleaner-state"
    cat > .kikori/cleaners/fake <<EOF
#!/bin/bash
STATE="${SANDBOX}/cleaner-state"
mode="\$1"; shift
echo "\${mode} \$*" >> "\${STATE}/calls"
case "\${mode}" in
    plan)
        printf 'auto\tid-a\titem A\n'
        printf 'review\tid-b\titem B\tstill running\n'
        ;;
    delete)
        while IFS= read -r id; do
            [ -z "\${id}" ] && continue
            printf 'deleted\t%s\n' "\${id}"
            echo "\${id}" >> "\${STATE}/deleted"
        done
        ;;
esac
EOF
    chmod +x .kikori/cleaners/fake
    "${KIKORI}" trust >/dev/null 2>&1 || true
}

test_cleaner_plan_and_delete() {
    install_fake_cleaner
    local out
    out="$(cleanup_cmd --yes)"
    assert_contains "${out}" "item A"
    assert_contains "${out}" "still running" "review item shown"
    assert_eq "$(cat "${SANDBOX}/cleaner-state/deleted" 2>/dev/null)" "id-a" "only the auto item deleted"
    assert_contains "${out}" "1 fake"
}

test_cleaner_force_includes_review_items() {
    install_fake_cleaner
    cleanup_cmd --yes --force >/dev/null
    assert_eq "$(sort "${SANDBOX}/cleaner-state/deleted" 2>/dev/null | tr '\n' ' ')" "id-a id-b " "both items deleted"
    grep -q "delete --force" "${SANDBOX}/cleaner-state/calls" || fail "--force not passed to cleaner delete"
}

test_cleaner_only_selection() {
    install_fake_cleaner
    git branch some-branch
    local out
    out="$(cleanup_cmd --only fake --yes)"
    assert_contains "${out}" "item A"
    grep -q "^plan" "${SANDBOX}/cleaner-state/calls" || fail "cleaner not invoked"
    git rev-parse --verify -q refs/heads/some-branch >/dev/null || fail "branch touched despite --only fake"
}

test_cleaner_assume_removed_receives_doomed_worktrees() {
    install_fake_cleaner
    "${KIKORI}" start --task "" --base origin/main </dev/null 2>&1 >/dev/null
    local wt branch
    wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
    branch="$(basename "${wt}")"
    git -C "${wt}" commit -q --allow-empty -m work
    local oid; oid="$(git -C "${wt}" rev-parse HEAD)"
    git checkout -q main && git merge -q --ff-only "${branch}" && git push -q origin main
    printf 'acme/repo main %s\n' "${oid}" > "${GH_STUB_DIR}/merged/${branch}"

    cleanup_cmd --yes >/dev/null
    grep -q -- "--assume-removed ${wt}" "${SANDBOX}/cleaner-state/calls" \
        || fail "plan did not receive --assume-removed for the doomed worktree"
}

test_cleaner_failure_sets_exit_code() {
    mkdir -p .kikori/cleaners
    cat > .kikori/cleaners/broken <<'EOF'
#!/bin/bash
case "$1" in
    plan) printf 'auto\tx\titem X\n' ;;
    delete) printf 'failed\tx\tdisk on fire\n'; exit 1 ;;
esac
EOF
    chmod +x .kikori/cleaners/broken
    local out rc
    out="$(cleanup_cmd --yes)"; rc=$?
    assert_eq "${rc}" "1"
    assert_contains "${out}" "disk on fire"
}

# --- run --------------------------------------------------------------------------

for t in \
    test_start_creates_worktree_and_branch \
    test_start_dry_run_creates_nothing \
    test_start_slug_hook_names_branch \
    test_start_rejects_prose_slug \
    test_start_copies_unmanaged_paths \
    test_start_post_create_hook_runs_in_new_worktree \
    test_repo_config_untrusted_fails_closed \
    test_trust_then_config_loads \
    test_cleanup_deletes_merged_branch_and_worktree \
    test_cleanup_skips_unmerged_branch \
    test_cleanup_pr_merged_to_other_base_is_not_auto \
    test_cleanup_unprovable_branch_needs_review \
    test_cleanup_dirty_worktree_needs_review_then_force_deletes \
    test_cleanup_only_branches_blocks_worktree_backed_branch \
    test_cleanup_only_worktrees_keeps_branch \
    test_cleanup_only_unknown_target_errors \
    test_cleaner_plan_and_delete \
    test_cleaner_force_includes_review_items \
    test_cleaner_only_selection \
    test_cleaner_assume_removed_receives_doomed_worktrees \
    test_cleaner_failure_sets_exit_code \
; do
    run_test "${t}"
done

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
