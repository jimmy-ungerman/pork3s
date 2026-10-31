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
  reviews=$(gh api --paginate "repos/${GH_REPO}/pulls/${pr_number}/reviews" | jq -s 'add // [] | map({author: .user.login, state, body: (.body // ""), commit_id, submitted_at, html_url})')
  required=$(gh api "repos/${GH_REPO}/rules/branches/main" | jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]')
  jq -n --argjson pr "$pr" --argjson checks "$checks" --argjson reviews "$reviews" --argjson required "$required" \
    '{pr: {state: ($pr.state | ascii_upcase), headRefOid: $pr.head.sha, author: $pr.user.login, labels: [$pr.labels[].name]}, reviews: $reviews, checks: $checks, required: $required}'
}

decide() {
  jq -f "${here}/kritika-automerge.jq"
}

# Appends to the run summary when running in Actions
summary() {
  echo "$1"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    echo "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

declined() {
  summary "### Not merging #${pr_number}$1"
  summary "$(jq -r '.reasons[] | "- " + .' <<<"$decision")"
  exit 0
}

state=$(gather)
decision=$(decide <<<"$state")
if [[ $(jq -r .merge <<<"$decision") != true ]]; then
  declined ""
fi

# Labels and head can change while the checks above run: decide again on fresh state
state=$(gather)
decision=$(decide <<<"$state")
if [[ $(jq -r .merge <<<"$decision") != true ]]; then
  declined " (state changed)"
fi

head=$(jq -r .pr.headRefOid <<<"$state")
review_url=$(jq -r .verdict.html_url <<<"$decision")

summary "### Merging #${pr_number} at \`${head:0:7}\`"
summary "Kritika approved 5/5 with low risk: ${review_url}"
gh pr merge "$pr_number" --squash --match-head-commit "$head" \
  --body "Auto-merged by kritika-automerge: confidence 5/5, low risk (${review_url})"

# Labelled after the merge so a refused merge is never marked, and a label problem cannot undo it
gh api -X POST "repos/${GH_REPO}/issues/${pr_number}/labels" -f 'labels[]=kritika/automerged' --silent || summary "Could not add the kritika/automerged label"

gh pr comment "$pr_number" --body "Auto-merged: Kritika approved \`${head:0:7}\` at 5/5 with low risk (${review_url}), and every required check passed." || true
