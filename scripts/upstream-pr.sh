#!/usr/bin/env bash
# upstream-pr.sh -- rebuild local commits on upstream's main into a branch that is
# safe to send to 8rank/iKnow, and print (or run) the commands that send it.
#
# The fork carries uv tooling that upstream does not have. This script refuses to
# copy a commit that would drag any of it across the boundary.
set -euo pipefail

UPSTREAM_REPO="8rank/iKnow"
FORK_OWNER="cristoslc"
BASE_BRANCH="main"
TRUNK="cristoslc/trunk"

# Files that exist only in the fork: upstream runs with plain python3.
FORK_ONLY_FILES=(pyproject.toml uv.lock)
# Files that exist in both, where fork-only uv wording can leak into a diff.
WORDING_FILES=(README.md MANUAL_FOR_YOUR_AGENT.md .gitignore)
WORDING_PATTERN='uv run|uv sync|uv\.lock|\.venv'

BRANCH=""
PUSH=0
PR_TITLE=""
PR_BODY=""
COMMITS=()
RESOLVED=()

usage() {
    cat <<'EOF'
Usage: scripts/upstream-pr.sh --branch <name> [--push] <commit>...

Rebuild one or more local commits on top of origin/main, dropping the fork's uv
tooling along the way, then print the commands that open the upstream PR.

Options:
  --branch <name>   Branch to create (required). Must not exist locally or on origin.
  --push            Run the push and gh pr create instead of printing them.
                    Needs --title and --body so nothing prompts.
  --title <text>    PR title, used with --push and shown in the printed command.
  --body <text>     PR body, used with --push and shown in the printed command.
  -h, --help        Show this text.

Upstream has no documented PR process and has never merged a PR. Its README names
issues as the only channel, so file the issue before the PR.

Nothing is created until every commit has been checked: a dirty tree, a bad SHA, an
existing branch, or one fork-only file anywhere aborts the whole run.
EOF
}

die() {
    printf 'upstream-pr: %s\n' "$*" >&2
    exit 1
}

recover() {
    printf 'upstream-pr: %s\n' "$1" >&2
    printf '\nRecovery:\n' >&2
    printf '  git cherry-pick --abort   # only if a cherry-pick stopped mid-way\n' >&2
    printf '  git switch %s && git branch -D %s\n' "$TRUNK" "$BRANCH" >&2
    exit 1
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --branch)
                [ "$#" -ge 2 ] || die "--branch needs a value"
                BRANCH="$2"
                shift 2
                ;;
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
            --push)
                PUSH=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    COMMITS+=("$1")
                    shift
                done
                ;;
            -*)
                usage >&2
                die "unknown option: $1"
                ;;
            *)
                COMMITS+=("$1")
                shift
                ;;
        esac
    done
}

check_arguments() {
    [ -n "$BRANCH" ] || die "missing --branch <name>; see --help"
    git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
        || die "not a valid branch name: $BRANCH"
    [ "${#COMMITS[@]}" -gt 0 ] || die "no commits given; pass one or more commit SHAs"
    if [ "$PUSH" -eq 1 ]; then
        [ -n "$PR_TITLE" ] || die "--push needs --title; nothing may prompt"
        [ -n "$PR_BODY" ] || die "--push needs --body; nothing may prompt"
    fi
}

check_clean_tree() {
    local status
    status="$(git status --porcelain)"
    if [ -n "$status" ]; then
        printf 'upstream-pr: working tree is dirty, so the run would mix your edits in:\n%s\n' "$status" >&2
        exit 1
    fi
}

check_commits_resolve() {
    local requested sha
    for requested in "${COMMITS[@]}"; do
        sha="$(git rev-parse --verify --quiet "${requested}^{commit}" || true)"
        [ -n "$sha" ] || die "commit does not resolve: $requested"
        RESOLVED+=("$sha")
    done
}

check_branch_absent_locally() {
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        die "branch already exists locally: $BRANCH"
    fi
}

check_branch_absent_on_origin() {
    if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
        die "branch already exists on origin: $BRANCH"
    fi
}

commit_label() {
    git log -1 --format='%h %s' "$1"
}

check_one_commit() {
    local sha="$1" path added candidate failed=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue

        for candidate in "${FORK_ONLY_FILES[@]}"; do
            if [ "$path" = "$candidate" ]; then
                printf 'upstream-pr: %s touches fork-only file %s; upstream has no uv project\n' \
                    "$(commit_label "$sha")" "$path" >&2
                failed=1
            fi
        done

        for candidate in "${WORDING_FILES[@]}"; do
            if [ "$path" = "$candidate" ]; then
                added="$(git show --format= --unified=0 "$sha" -- "$path" \
                    | grep '^+' | grep -v '^+++' || true)"
                if printf '%s\n' "$added" | grep -Eq "$WORDING_PATTERN"; then
                    printf 'upstream-pr: %s adds fork-only uv wording to %s\n' \
                        "$(commit_label "$sha")" "$path" >&2
                    printf '%s\n' "$added" | grep -E "$WORDING_PATTERN" >&2
                    failed=1
                fi
            fi
        done
    done < <(git show --format= --name-only "$sha")
    return "$failed"
}

check_commits_are_upstream_safe() {
    local sha failed=0
    for sha in "${RESOLVED[@]}"; do
        check_one_commit "$sha" || failed=1
    done
    if [ "$failed" -ne 0 ]; then
        die "refusing to build $BRANCH: at least one commit carries fork-only material"
    fi
}

fetch_remotes() {
    git fetch origin --prune >/dev/null
    if git remote get-url upstream >/dev/null 2>&1; then
        git fetch upstream --prune >/dev/null
    fi
}

create_branch() {
    git switch -c "$BRANCH" "origin/$BASE_BRANCH" >/dev/null \
        || die "could not create $BRANCH from origin/$BASE_BRANCH"
}

cherry_pick_commits() {
    local sha
    for sha in "${RESOLVED[@]}"; do
        if ! git cherry-pick -x "$sha"; then
            recover "cherry-pick failed for $(commit_label "$sha"); the branch is half-built"
        fi
    done
}

print_pr_command() {
    local title="$PR_TITLE" body="$PR_BODY"
    [ -n "$title" ] || title="..."
    [ -n "$body" ] || body="..."
    printf 'gh pr create --repo %s --base %s --head %s:%s --title "%s" --body "%s"\n' \
        "$UPSTREAM_REPO" "$BASE_BRANCH" "$FORK_OWNER" "$BRANCH" "$title" "$body"
}

print_next_steps() {
    printf '\n%s now holds the rebuilt commits. Next:\n\n' "$BRANCH"
    printf '  1. Proposed first step: file an issue, the only channel the upstream\n'
    printf '     README names (upstream has no documented PR process):\n'
    printf '     gh issue create --repo %s --title "..." --body "..."\n' "$UPSTREAM_REPO"
    printf '\n  2. Push the branch to the fork (never to upstream):\n'
    printf '     git push -u origin %s\n' "$BRANCH"
    printf '\n  3. Offer the branch in a PR that names the issue:\n'
    printf '     '
    print_pr_command
    printf '\n  4. When finished:\n'
    printf '     git switch %s\n' "$TRUNK"
}

run_push_and_pr() {
    if ! git push -u origin "$BRANCH"; then
        recover "push to origin failed"
    fi
    printf '\nNote: upstream documents issues as its only channel and has never merged a PR;\n' >&2
    printf 'file the issue first if you have not: gh issue create --repo %s\n\n' "$UPSTREAM_REPO" >&2
    if ! gh pr create --repo "$UPSTREAM_REPO" --base "$BASE_BRANCH" \
        --head "$FORK_OWNER:$BRANCH" --title "$PR_TITLE" --body "$PR_BODY"; then
        recover "gh pr create failed; the branch is pushed, so fix the PR by hand"
    fi
}

main() {
    parse_args "$@"
    check_arguments
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
    check_clean_tree
    check_commits_resolve
    check_branch_absent_locally
    fetch_remotes
    check_branch_absent_on_origin
    check_commits_are_upstream_safe
    create_branch
    cherry_pick_commits
    if [ "$PUSH" -eq 1 ]; then
        run_push_and_pr
        printf '\nWhen finished: git switch %s\n' "$TRUNK"
    else
        print_next_steps
    fi
}

main "$@"
