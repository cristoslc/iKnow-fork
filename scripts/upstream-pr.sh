#!/usr/bin/env bash
# upstream-pr.sh -- send chosen trunk commits to 8rank/iKnow on upstream/<slug>.
#
# Model: work lands on cristoslc/trunk. `main` mirrors upstream/main and only
# fast-forwards. `add <slug> <commit>...` cuts upstream/<slug> from main and
# cherry-picks the chosen commits, guarded so no fork-only material rides along.
# `push <slug>` sends the branch to origin and opens the PR from
# cristoslc:upstream/<slug>. `sync` fast-forwards main after upstream merges or
# declines, and rebuilds any branch that should stay on the new base.
#
# Kept compatible with bash 3.2, the /bin/bash that ships with macOS: every
# array expansion that may be empty is guarded with ${arr[@]+"${arr[@]}"}.
set -euo pipefail

UPSTREAM_REPO="8rank/iKnow"
FORK_OWNER="cristoslc"
BASE_BRANCH="main"
BRANCH_PREFIX="upstream"

# Files that exist only in the fork: upstream runs with plain python3, has no uv
# project, and needs neither our fork-workflow script nor our agent instructions.
FORK_ONLY_FILES=(pyproject.toml uv.lock AGENTS.md scripts/upstream-pr.sh)
WORDING_PATTERN='uv run|uv sync|uv\.lock|\.venv'

COMMAND=""
SLUG=""
COMMITS=()
COMMITS_RESOLVED=()
REBUILD=()
PR_TITLE=""
PR_BODY=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: scripts/upstream-pr.sh <command> [options]

Upstream-bound work travels on upstream/<slug> branches cut from main, which
mirrors upstream/main. Work lands on cristoslc/trunk first and is cherry-picked,
guarded, onto a PR branch.

Commands:
  add <slug> <commit>...        Cut upstream/<slug> from main (or reuse it) and
                                cherry-pick the commits, guarded against
                                fork-only files and fork-only uv wording.
  check [<slug>]                Guard upstream/<slug> against main; with no slug,
                                check that main is a clean mirror and guard every
                                upstream/* branch. Exit 0 clean, 1 dirty.
  status                        What main holds against upstream/main, and what
                                each upstream/* branch holds against main.
  push <slug> [--title T] [--body B] [--dry-run]
                                Push upstream/<slug> to origin, then open the PR
                                from cristoslc:upstream/<slug> to 8rank/iKnow:main.
  sync [--rebuild <slug>...] [--dry-run]
                                Fast-forward main to upstream/main after upstream
                                merges or declines, and report stale branches.
                                --rebuild re-applies a branch's still-pending
                                commits on the new base and force-pushes it.

Options:
  --rebuild <slug>  Branch to rebuild during sync; repeat for each one.
  --title <text>    PR title; needs --body.
  --body <text>     PR body; needs --title.
  --dry-run         Print what would happen; change nothing.
  -h, --help        Show this text.

Upstream has no documented PR process and has never merged a PR. Its README names
issues as the only channel, so file the issue before the PR.

Nothing is pushed, and the branch you are on is restored, unless every check has
passed.
EOF
}

die() {
    printf 'upstream-pr: %s\n' "$*" >&2
    exit 1
}

# Restore the caller's branch and stop. Used once git state has started to move;
# everything cheap is checked before this can happen.
recover() {
    local message="$1" branch="$2"
    printf 'upstream-pr: %s\n' "$message" >&2
    printf '\nRecovery:\n' >&2
    printf '  git cherry-pick --abort   # only if a cherry-pick stopped mid-way\n' >&2
    printf '  git switch %s && git reset --hard origin/%s   # drop what was added to %s\n' \
        "$BASE_BRANCH" "$BASE_BRANCH" "$BASE_BRANCH" >&2
    printf '  git switch %s\n' "$branch" >&2
    printf '\nRestoring %s now; the PR branch is left as it failed.\n' "$branch" >&2
    git cherry-pick --abort >/dev/null 2>&1 || true
    git switch "$branch" >/dev/null 2>&1 || true
    exit 1
}

commit_label() {
    git log -1 --format='%h %s' "$1"
}

branch_for_slug() {
    printf '%s/%s\n' "$BRANCH_PREFIX" "$1"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_add() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    COMMITS+=("$1")
                    shift
                done
                ;;
            -*)
                usage >&2
                die "add: unknown option: $1"
                ;;
            *)
                if [ -z "$SLUG" ]; then
                    SLUG="$1"
                else
                    COMMITS+=("$1")
                fi
                shift
                ;;
        esac
    done
    [ -n "$SLUG" ] || die "add needs a slug: add <slug> <commit>...; see --help"
    [ "${#COMMITS[@]}" -gt 0 ] || die "add needs one or more commits: add <slug> <commit>..."
}

parse_check() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -*)
                usage >&2
                die "check: unknown option: $1"
                ;;
            *)
                [ -z "$SLUG" ] || {
                    usage >&2
                    die "check: one branch at most"
                }
                SLUG="$1"
                shift
                ;;
        esac
    done
}

parse_status() {
    [ "$#" -eq 0 ] || {
        usage >&2
        die "status: takes no arguments"
    }
}

parse_push() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --title)
                [ "$#" -ge 2 ] || die "--title needs a value"
                PR_TITLE="$2"
                shift 2
                ;;
            --body)
                [ "$#" -ge 2 ] || die "--body needs a value"
                PR_BODY="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -*)
                usage >&2
                die "push: unknown option: $1"
                ;;
            *)
                [ -z "$SLUG" ] || {
                    usage >&2
                    die "push: one slug at most"
                }
                SLUG="$1"
                shift
                ;;
        esac
    done
    [ -n "$SLUG" ] || die "push needs a slug: push <slug> [--title T] [--body B] [--dry-run]"
}

parse_sync() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --rebuild)
                [ "$#" -ge 2 ] || die "--rebuild needs a value"
                REBUILD+=("$2")
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -*)
                usage >&2
                die "sync: unknown option: $1"
                ;;
            *)
                usage >&2
                die "sync: unexpected argument: $1"
                ;;
        esac
    done
}

parse_args() {
    [ "$#" -gt 0 ] || {
        usage >&2
        die "missing command; see --help"
    }
    case "$1" in
        -h|--help) usage; exit 0 ;;
    esac
    COMMAND="$1"
    shift
    case "$COMMAND" in
        add) parse_add "$@" ;;
        check) parse_check "$@" ;;
        status) parse_status "$@" ;;
        push) parse_push "$@" ;;
        sync) parse_sync "$@" ;;
        *)
            usage >&2
            die "unknown command: $COMMAND"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

require_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not inside a git repository"
    git remote get-url upstream >/dev/null 2>&1 \
        || die "missing the upstream remote; add it first: git remote add upstream https://github.com/$UPSTREAM_REPO.git"
}

fetch_remotes() {
    require_repo
    git fetch origin --prune >/dev/null || die "git fetch origin failed"
    git fetch upstream --prune >/dev/null || die "git fetch upstream failed"
    git rev-parse --verify --quiet upstream/main >/dev/null \
        || die "upstream/main is missing after the fetch"
    git rev-parse --verify --quiet "refs/heads/$BASE_BRANCH" >/dev/null \
        || die "no local $BASE_BRANCH branch; create it from upstream/main first"
}

check_clean_tree() {
    local status
    status="$(git status --porcelain)"
    if [ -n "$status" ]; then
        printf 'upstream-pr: working tree is dirty, so the run would mix your edits in:\n%s\n' "$status" >&2
        exit 1
    fi
}

validate_slug() {
    local slug="$1" branch
    branch="$(branch_for_slug "$slug")"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || die "not a usable slug: $slug (it becomes the branch $branch)"
}

check_commits_resolve() {
    local requested sha
    for requested in ${COMMITS[@]+"${COMMITS[@]}"}; do
        sha="$(git rev-parse --verify --quiet "${requested}^{commit}" || true)"
        [ -n "$sha" ] || die "commit does not resolve: $requested"
        COMMITS_RESOLVED+=("$sha")
    done
}

check_main_not_behind_origin() {
    local behind
    behind="$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH")"
    if [ "$behind" -gt 0 ]; then
        die "local $BASE_BRANCH is $behind commit(s) behind origin/$BASE_BRANCH; run 'git switch $BASE_BRANCH && git pull --ff-only' first"
    fi
}

# main must add nothing to upstream/main; the mirror is the base for PR branches.
check_main_mirror() {
    local extra
    extra="$(git log --oneline "upstream/main..$BASE_BRANCH")"
    if [ -n "$extra" ]; then
        printf 'upstream-pr: %s carries commits of its own, so it is no longer a mirror of upstream/main:\n%s\n' \
            "$BASE_BRANCH" "$extra" >&2
        printf 'Move them onto an %s/<slug> branch, then reset it:\n  git switch %s && git reset --hard upstream/main\n' \
            "$BRANCH_PREFIX" "$BASE_BRANCH" >&2
        exit 1
    fi
}

branch_exists_local() {
    git show-ref --verify --quiet "refs/heads/$1"
}

branch_exists_origin() {
    git show-ref --verify --quiet "refs/remotes/origin/$1"
}

local_branches_under_prefix() {
    git for-each-ref --format='%(refname:short)' "refs/heads/$BRANCH_PREFIX/"
}

is_fork_only() {
    local path="$1" candidate
    for candidate in "${FORK_ONLY_FILES[@]}"; do
        if [ "$path" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

# Report uv wording added by a diff. Returns 0 when it found a hit.
report_wording_hits() {
    local label="$1" path="$2" added="$3"
    if [ -n "$added" ] && printf '%s\n' "$added" | grep -Eq "$WORDING_PATTERN"; then
        printf 'upstream-pr: %s adds fork-only uv wording to %s\n' "$label" "$path" >&2
        printf '%s\n' "$added" | grep -E "$WORDING_PATTERN" >&2
        return 0
    fi
    return 1
}

# Per-commit guard: only this commit's own diff.
guard_commit() {
    local sha="$1" label path added failed=0
    label="$(commit_label "$sha")"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_fork_only "$path"; then
            printf 'upstream-pr: %s touches fork-only file %s, absent upstream\n' \
                "$label" "$path" >&2
            failed=1
            continue
        fi
        added="$(git show --format= --unified=0 "$sha" -- "$path" \
            | grep '^+' | grep -v '^+++' || true)"
        if report_wording_hits "$label" "$path" "$added"; then
            failed=1
        fi
    done < <(git show --format= --name-only "$sha")
    return "$failed"
}

# Cumulative guard: the PR's own diff, base...branch (three dots).
guard_range() {
    local range="$1" label="$2" path added failed=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_fork_only "$path"; then
            printf 'upstream-pr: %s carries fork-only file %s, absent upstream\n' \
                "$label" "$path" >&2
            failed=1
            continue
        fi
        added="$(git diff --unified=0 "$range" -- "$path" \
            | grep '^+' | grep -v '^+++' || true)"
        if report_wording_hits "$label" "$path" "$added"; then
            failed=1
        fi
    done < <(git diff --name-only "$range")
    return "$failed"
}

current_branch() {
    local branch
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [ -n "$branch" ] || die "HEAD is detached; switch to a branch first"
    printf '%s\n' "$branch"
}

# Commits on a branch that upstream does not already have, oldest first.
# `git cherry` drops commits upstream took by cherry-pick under another sha.
kept_commits() {
    git cherry "$BASE_BRANCH" "$1" \
        | awk '$1 == "+" { print $2 }' \
        | awk '{ line[NR] = $0 } END { for (i = NR; i >= 1; i--) print line[i] }'
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

print_pr_command() {
    local branch="$1" title="${PR_TITLE:-...}" body="${PR_BODY:-...}"
    printf 'gh pr create --repo %s --base %s --head %s:%s --title "%s" --body "%s"\n' \
        "$UPSTREAM_REPO" "main" "$FORK_OWNER" "$branch" "$title" "$body"
}

print_branch_status() {
    local branch="$1" log_out cherry_out ahead behind

    printf '%s vs %s (%s):\n' "$branch" "$BASE_BRANCH" "$(git rev-parse --short "$BASE_BRANCH")"
    log_out="$(git log --oneline "$BASE_BRANCH..$branch")"
    if [ -n "$log_out" ]; then
        printf '%s\n' "$log_out"
    else
        printf '  (nothing; the branch matches %s)\n' "$BASE_BRANCH"
    fi

    printf '\nPending (+) and already-upstream (-) commits:\n'
    cherry_out="$(git cherry -v "$BASE_BRANCH" "$branch")"
    if [ -n "$cherry_out" ]; then
        printf '%s\n' "$cherry_out"
    else
        printf '  (none)\n'
    fi

    printf '\norigin/%s: ' "$branch"
    if branch_exists_origin "$branch"; then
        if [ "$(git rev-parse "$branch")" = "$(git rev-parse "origin/$branch")" ]; then
            printf 'equal to the local branch\n'
        else
            ahead="$(git rev-list --count "origin/$branch..$branch")"
            behind="$(git rev-list --count "$branch..origin/$branch")"
            printf '%s commit(s) behind, %s commit(s) ahead\n' "$ahead" "$behind"
        fi
    else
        printf 'missing; push creates it\n'
    fi
}

print_status() {
    local branch first=1

    printf '%s (%s) vs upstream/main (%s): ' \
        "$BASE_BRANCH" "$(git rev-parse --short "$BASE_BRANCH")" \
        "$(git rev-parse --short upstream/main)"
    if [ "$(git rev-parse "$BASE_BRANCH")" = "$(git rev-parse upstream/main)" ]; then
        printf 'equal\n'
    else
        printf '%s commit(s) pending upstream, %s commit(s) of its own\n' \
            "$(git rev-list --count "$BASE_BRANCH..upstream/main")" \
            "$(git rev-list --count "upstream/main..$BASE_BRANCH")"
    fi
    if [ "$(git rev-parse "$BASE_BRANCH")" = "$(git rev-parse "origin/$BASE_BRANCH")" ]; then
        printf 'origin/%s: equal to local\n' "$BASE_BRANCH"
    else
        printf 'origin/%s: differs from local\n' "$BASE_BRANCH"
    fi

    printf '\nPR branches under %s/:\n' "$BRANCH_PREFIX"
    while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        first=0
        printf '\n'
        print_branch_status "$branch"
    done < <(local_branches_under_prefix)
    if [ "$first" -eq 1 ]; then
        printf '  (none)\n'
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_add() {
    fetch_remotes
    check_clean_tree
    check_main_mirror
    check_main_not_behind_origin
    check_commits_resolve

    local sha
    for sha in ${COMMITS_RESOLVED[@]+"${COMMITS_RESOLVED[@]}"}; do
        if ! guard_commit "$sha"; then
            die "refusing $(commit_label "$sha"): it carries fork-only material"
        fi
    done

    local branch origin_branch behind
    branch="$(branch_for_slug "$SLUG")"

    if branch_exists_local "$branch" && branch_exists_origin "$branch"; then
        behind="$(git rev-list --count "$branch..origin/$branch")"
        if [ "$behind" -gt 0 ]; then
            die "local $branch is $behind commit(s) behind origin/$branch; pull it first"
        fi
    fi

    origin_branch="$(current_branch)"

    if branch_exists_local "$branch"; then
        git switch "$branch" >/dev/null || die "could not switch to $branch"
    elif branch_exists_origin "$branch"; then
        git switch -c "$branch" --track "origin/$branch" >/dev/null \
            || die "could not create $branch from origin/$branch"
    else
        git switch -c "$branch" "$BASE_BRANCH" >/dev/null \
            || die "could not create $branch from $BASE_BRANCH"
    fi

    for sha in ${COMMITS_RESOLVED[@]+"${COMMITS_RESOLVED[@]}"}; do
        if ! git cherry-pick -x "$sha" >/dev/null; then
            recover "cherry-pick failed for $(commit_label "$sha")" "$origin_branch"
        fi
    done

    if ! guard_range "$BASE_BRANCH...$branch" "$branch vs $BASE_BRANCH"; then
        recover "the cherry-picks together carry fork-only material" "$origin_branch"
    fi

    git switch "$origin_branch" >/dev/null \
        || die "could not switch back to $origin_branch"

    print_branch_status "$branch"
}

cmd_check() {
    fetch_remotes

    local failed=0 branch
    if [ -n "$SLUG" ]; then
        validate_slug "$SLUG"
        branch="$(branch_for_slug "$SLUG")"
        branch_exists_local "$branch" || die "no local branch $branch; run add first"
        if ! guard_range "$BASE_BRANCH...$branch" "$branch vs $BASE_BRANCH"; then
            failed=1
        fi
    else
        check_main_mirror
        while IFS= read -r branch; do
            [ -n "$branch" ] || continue
            if ! guard_range "$BASE_BRANCH...$branch" "$branch vs $BASE_BRANCH"; then
                failed=1
            fi
        done < <(local_branches_under_prefix)
    fi

    if [ "$failed" -ne 0 ]; then
        die "a branch carries material that must not go upstream (see the paths above)"
    fi
    if [ -n "$SLUG" ]; then
        printf 'clean: %s carries no fork-only material\n' "$(branch_for_slug "$SLUG")"
    else
        printf 'clean: %s is a clean mirror and every %s/* branch passes the guard\n' \
            "$BASE_BRANCH" "$BRANCH_PREFIX"
    fi
}

cmd_status() {
    fetch_remotes
    print_status
}

cmd_push() {
    if [ -n "$PR_TITLE" ] && [ -z "$PR_BODY" ]; then
        die "--title also needs --body"
    fi
    if [ -n "$PR_BODY" ] && [ -z "$PR_TITLE" ]; then
        die "--body also needs --title"
    fi

    fetch_remotes
    validate_slug "$SLUG"

    local branch ahead behind
    branch="$(branch_for_slug "$SLUG")"
    branch_exists_local "$branch" || die "no local branch $branch; run add first"

    if ! guard_range "$BASE_BRANCH...$branch" "$branch vs $BASE_BRANCH"; then
        die "refusing: $branch carries fork-only material (see the paths above)"
    fi

    if branch_exists_origin "$branch"; then
        ahead="$(git rev-list --count "origin/$branch..$branch")"
        behind="$(git rev-list --count "$branch..origin/$branch")"
        if [ "$behind" -gt 0 ]; then
            die "local $branch is $behind commit(s) behind origin/$branch; pull it first"
        fi
    else
        ahead="$(git rev-list --count "$BASE_BRANCH..$branch")"
    fi
    if [ "$ahead" -eq 0 ]; then
        die "$branch is not ahead of its origin, so there is nothing to push"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'Dry run; nothing pushed.\n\n'
        printf 'git push origin %s:%s\n' "$branch" "$branch"
        print_pr_command "$branch"
        return 0
    fi

    if ! git push origin "$branch:$branch"; then
        die "git push origin $branch:$branch failed; fix the state and retry"
    fi

    if [ -n "$PR_TITLE" ]; then
        if ! gh pr create --repo "$UPSTREAM_REPO" --base main \
            --head "$FORK_OWNER:$branch" --title "$PR_TITLE" --body "$PR_BODY"; then
            die "git push finished but gh pr create failed; open the PR by hand"
        fi
    else
        printf '\nPushed. Open the PR:\n  '
        print_pr_command "$branch"
    fi
}

report_branches_after_sync() {
    local branch left found=0
    while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        found=1
        if [ "$(git rev-list --count "$BASE_BRANCH..$branch")" -eq 0 ]; then
            printf '  %s: merged upstream; safe to delete\n' "$branch"
        elif git merge-base --is-ancestor "$BASE_BRANCH" "$branch" 2>/dev/null; then
            printf '  %s: current\n' "$branch"
        else
            left="$(git rev-list --count "$BASE_BRANCH..$branch")"
            printf '  %s: stale, %s commit(s) still pending; run sync --rebuild %s\n' \
                "$branch" "$left" "${branch#"$BRANCH_PREFIX"/}"
        fi
    done < <(local_branches_under_prefix)
    if [ "$found" -eq 0 ]; then
        printf '  (no PR branches)\n'
    fi
}

cmd_sync() {
    fetch_remotes
    check_clean_tree
    check_main_mirror

    local origin_branch slug branch sha
    origin_branch="$(current_branch)"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'Dry run; nothing changes.\n\n'
        printf 'git switch %s\n' "$BASE_BRANCH"
        printf 'git merge --ff-only upstream/main   # %s\n' \
            "$(git rev-parse --short upstream/main)"
        for slug in ${REBUILD[@]+"${REBUILD[@]}"}; do
            validate_slug "$slug"
            branch="$(branch_for_slug "$slug")"
            branch_exists_local "$branch" || die "no local branch $branch"
            printf 'git switch %s\n' "$branch"
            printf 'git reset --hard %s\n' "$BASE_BRANCH"
            while IFS= read -r sha; do
                [ -n "$sha" ] || continue
                printf 'git cherry-pick -x %s   # %s\n' "$sha" "$(commit_label "$sha")"
            done < <(kept_commits "$branch")
            printf 'scripts/upstream-pr.sh check %s\n' "$slug"
            printf 'git push --force-with-lease origin %s:%s\n' "$branch" "$branch"
        done
        printf '\nBranches as they stand now:\n'
        report_branches_after_sync
        return 0
    fi

    git switch "$BASE_BRANCH" >/dev/null || die "could not switch to $BASE_BRANCH"
    if ! git merge --ff-only upstream/main >/dev/null; then
        recover "$BASE_BRANCH cannot fast-forward to upstream/main; upstream rewrote history" "$origin_branch"
    fi
    printf '%s is now at upstream/main (%s).\n' \
        "$BASE_BRANCH" "$(git rev-parse --short "$BASE_BRANCH")"

    for slug in ${REBUILD[@]+"${REBUILD[@]}"}; do
        validate_slug "$slug"
        branch="$(branch_for_slug "$slug")"
        branch_exists_local "$branch" || die "no local branch $branch"

        local kept=()
        while IFS= read -r sha; do
            if [ -n "$sha" ]; then
                kept+=("$sha")
            fi
        done < <(kept_commits "$branch")

        if [ "${#kept[@]}" -eq 0 ]; then
            printf '\n%s has nothing left beyond %s; its PR is merged or dropped.\n' \
                "$branch" "$BASE_BRANCH"
            printf '  git branch -D %s && git push origin --delete %s\n' "$branch" "$branch"
            continue
        fi

        git switch "$branch" >/dev/null || die "could not switch to $branch"
        git reset --hard "$BASE_BRANCH" >/dev/null
        for sha in ${kept[@]+"${kept[@]}"}; do
            if ! git cherry-pick -x "$sha" >/dev/null; then
                recover "cherry-pick failed for $(commit_label "$sha")" "$origin_branch"
            fi
        done
        if ! guard_range "$BASE_BRANCH...$branch" "$branch vs $BASE_BRANCH"; then
            recover "the rebuilt commits carry fork-only material" "$origin_branch"
        fi
        if ! git push --force-with-lease origin "$branch:$branch"; then
            recover "force push failed for $branch; origin moved since the fetch" "$origin_branch"
        fi
    done

    git switch "$origin_branch" >/dev/null \
        || die "could not switch back to $origin_branch"

    printf '\nPR branches after the sync:\n'
    report_branches_after_sync
}

main() {
    parse_args "$@"
    case "$COMMAND" in
        add) cmd_add ;;
        check) cmd_check ;;
        status) cmd_status ;;
        push) cmd_push ;;
        sync) cmd_sync ;;
    esac
}

main "$@"
