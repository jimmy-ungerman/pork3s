#!/usr/bin/env bash
# Merges a Renovate PR when Kritika approved its current head at 5/5 with low
# risk and every required check has succeeded. Usage: kritika-automerge.sh <pr>
# Needs GH_TOKEN and GH_REPO.
set -euo pipefail

pr_number=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Reads the PR as it is right now: head, labels, reviews and check results
gather() {
  local pr checks reviews required
  pr=$(gh api "repos/${GH_REPO}/pulls/${pr_number}")
  checks=$(gh pr view "$pr_number" --json statusCheckRollup --jq '[.statusCheckRollup[] | {name: (.name // .context), conclusion: (.conclusion // .state), at: (.completedAt // .startedAt // "")}]')
  reviews=$(gh api --paginate "repos/${GH_REPO}/pulls/${pr_number}/reviews" | jq -s 'add // [] | map({author: .user.login, state, body: (.body // ""), commit_id, submitted_at})')
  required=$(gh api "repos/${GH_REPO}/rules/branches/main" | jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]')
  jq -n --argjson pr "$pr" --argjson checks "$checks" --argjson reviews "$reviews" --argjson required "$required" \
    '{pr: {state: ($pr.state | ascii_upcase), headRefOid: $pr.head.sha, author: $pr.user.login, labels: [$pr.labels[].name]}, reviews: $reviews, checks: $checks, required: $required}'
}

decide() {
  jq -f "${here}/kritika-automerge.jq"
}

state=$(gather)
decision=$(decide <<<"$state")
if [[ $(jq -r .merge <<<"$decision") != true ]]; then
  echo "Not merging #${pr_number}:"
  jq -r '.reasons[] | "- " + .' <<<"$decision"
  exit 0
fi

# Labels and head can change while the checks above run: decide again on fresh state
state=$(gather)
decision=$(decide <<<"$state")
if [[ $(jq -r .merge <<<"$decision") != true ]]; then
  echo "Not merging #${pr_number}, state changed:"
  jq -r '.reasons[] | "- " + .' <<<"$decision"
  exit 0
fi

head=$(jq -r .pr.headRefOid <<<"$state")
echo "Merging #${pr_number} at ${head}"
gh pr merge "$pr_number" --squash --match-head-commit "$head"
