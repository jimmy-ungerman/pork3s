#!/usr/bin/env bash
# Runs kritika-automerge.sh end to end against a mocked gh.
# Usage: kritika-automerge.integration.test.sh
# shellcheck disable=SC2329 # the assertion helpers are called indirectly through expect
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

head=aaaaaaa1111111111111111111111111111111aa
old=bbbbbbb2222222222222222222222222222222bb
selected_url=https://github.com/o/r/pull/7#pullrequestreview-selected
older_url=https://github.com/o/r/pull/7#pullrequestreview-older-same-head
stale_url=https://github.com/o/r/pull/7#pullrequestreview-stale-head

mkdir -p "$work/bin"

# Answers the calls the script makes from fixtures, and logs each call and its arguments
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$MOCK_LOG"
args="$*"
case "$args" in
  "pr view "*)
    expr=
    while (($#)); do
      if [[ $1 == --jq ]]; then expr=$2; fi
      shift
    done
    jq -c "$expr" "$MOCK_DIR/checks.json" ;;
  "pr merge "*)
    if [[ ${MOCK_MERGE_FAIL:-} == 1 ]]; then
      echo "merge refused: head branch was modified" >&2
      exit 1
    fi ;;
  "pr comment "*) ;;
  "api -X POST "*) ;;
  "api --paginate "*/reviews) cat "$MOCK_DIR/reviews.json" ;;
  "api "*/rules/branches/main) cat "$MOCK_DIR/rules.json" ;;
  "api "*/pulls/7) cat "$MOCK_DIR/pr.json" ;;
  *) echo "unexpected gh call: $args" >&2; exit 2 ;;
esac
MOCK
chmod +x "$work/bin/gh"

# Writes fixtures for an eligible PR; an optional jq edit is applied to the PR
fixtures() {
  local pr_edit=${1:-.}
  jq -n --arg head "$head" '{state: "open", head: {sha: $head}, user: {login: "porky-bot[bot]"}, labels: [{name: "type/patch"}]}' \
    | jq "$pr_edit" > "$work/pr.json"
  jq -n --arg head "$head" --arg old "$old" --arg selected "$selected_url" --arg older "$older_url" --arg stale "$stale_url" '[
    {user: {login: "porkboiai"}, state: "APPROVED", commit_id: $old, submitted_at: "2026-10-30T08:00:00Z", html_url: $stale,
     body: "kritika: confidence 5/5 with low risk at \($old[0:7])."},
    {user: {login: "porkboiai"}, state: "COMMENTED", commit_id: $head, submitted_at: "2026-10-30T09:00:00Z", html_url: $older,
     body: "kritika: confidence 4/5 with medium risk at \($head[0:7])."},
    {user: {login: "porkboiai"}, state: "APPROVED", commit_id: $head, submitted_at: "2026-10-30T10:00:00Z", html_url: $selected,
     body: "kritika: confidence 5/5 with low risk at \($head[0:7])."}
  ]' > "$work/reviews.json"
  jq -n '{statusCheckRollup: [
    {name: "Kritika / Review", conclusion: "SUCCESS", completedAt: "2026-10-30T10:00:00Z"},
    {name: "Build Success", conclusion: "SUCCESS", completedAt: "2026-10-30T10:01:00Z"}]}' > "$work/checks.json"
  jq -n '[{type: "required_status_checks", parameters: {required_status_checks: [{context: "Kritika / Review"}, {context: "Build Success"}]}}]' > "$work/rules.json"
}

# run_script: sets status, log and summary for one run of the script
run_script() {
  : > "$work/log"
  : > "$work/summary"
  status=0
  PATH="$work/bin:$PATH" MOCK_DIR="$work" MOCK_LOG="$work/log" GITHUB_STEP_SUMMARY="$work/summary" GH_REPO=o/r \
    "$here/kritika-automerge.sh" 7 > "$work/out" 2>&1 || status=$?
}

failed=0
expect() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}"
    failed=1
  fi
}

log_has() { grep -q -- "$1" "$work/log"; }
log_lacks() { ! grep -q -- "$1" "$work/log"; }
summary_has() { grep -q -- "$1" "$work/summary"; }
# Line number of the first log line matching $1, or empty
line_of() { grep -n -m1 -- "$1" "$work/log" | cut -d: -f1; }
after_merge() {
  local merge other
  merge=$(line_of "^gh pr merge")
  other=$(line_of "$1")
  [[ -n $merge && -n $other && $other -gt $merge ]]
}

echo "# eligible PR"
fixtures
run_script
expect "exits 0" test "$status" -eq 0
expect "merges the current head with --match-head-commit" log_has "^gh pr merge 7 --squash --match-head-commit ${head}"
expect "merge body links the selected review" log_has "^gh pr merge .*--body .*${selected_url}"
expect "merge body does not link another review" log_lacks "${older_url}\|${stale_url}"
expect "labels after the merge" after_merge "^gh api -X POST repos/o/r/issues/7/labels"
expect "comments after the merge" after_merge "^gh pr comment 7"
expect "comment links the selected review" log_has "^gh pr comment 7 .*${selected_url}"
expect "summary records the merge" summary_has "Merging #7"
expect "summary links the selected review" summary_has "$selected_url"

echo "# rejected decision"
fixtures '.labels += [{name: "hold"}]'
run_script
expect "exits 0" test "$status" -eq 0
expect "does not merge" log_lacks "^gh pr merge"
expect "does not label" log_lacks "issues/7/labels"
expect "does not comment" log_lacks "^gh pr comment"
expect "summary says why" summary_has "excluded label: hold"
expect "summary says it did not merge" summary_has "Not merging #7"

echo "# failed merge"
fixtures
MOCK_MERGE_FAIL=1 run_script
expect "exits nonzero" test "$status" -ne 0
expect "attempted the merge" log_has "^gh pr merge"
expect "does not label" log_lacks "issues/7/labels"
expect "does not comment" log_lacks "^gh pr comment"

exit "$failed"
