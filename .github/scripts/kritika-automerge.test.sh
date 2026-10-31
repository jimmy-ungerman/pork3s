#!/usr/bin/env bash
# Regression cases for kritika-automerge.jq. Usage: kritika-automerge.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failed=0

head=aaaaaaa1111111111111111111111111111111aa
old=bbbbbbb2222222222222222222222222222222bb

# An eligible PR: approved 5/5 low risk for its head, both required checks green
base=$(jq -n --arg head "$head" '{
  pr: {state: "OPEN", headRefOid: $head, author: "porky-bot[bot]", labels: ["type/patch"]},
  reviews: [{author: "porkboiai[bot]", state: "APPROVED", commit_id: $head, submitted_at: "2026-10-30T10:00:00Z",
             body: "kritika: confidence 5/5 with low risk at \($head[0:7])."}],
  checks: [{name: "Kritika / Review", conclusion: "SUCCESS", at: "2026-10-30T10:00:00Z"},
           {name: "Build Success", conclusion: "SUCCESS", at: "2026-10-30T10:01:00Z"}],
  required: ["Kritika / Review", "Build Success"]
}')

# check <name> <expected merge> <jq edit applied to the eligible PR>
check() {
  local name=$1 want=$2 edit=$3 got
  got=$(jq "$edit" <<<"$base" | jq -f "${here}/kritika-automerge.jq" | jq -r .merge)
  if [[ $got == "$want" ]]; then
    echo "ok   - ${name}"
  else
    echo "FAIL - ${name}: merge=${got}, want ${want}"
    failed=1
  fi
}

check "eligible PR merges" true '.'
check "hold applied while required checks are pending" false \
  '.pr.labels += ["hold"] | .checks |= map(if .name == "Build Success" then .conclusion = "PENDING" else . end)'
check "hold applied after checks passed" false '.pr.labels += ["hold"]'
check "type/major label" false '.pr.labels += ["type/major"]'
check "Renovate push after an eligible approval" false \
  ".pr.headRefOid = \"${old}\""
check "lower-confidence review follows an earlier eligible approval" false \
  ".reviews += [{author: \"porkboiai[bot]\", state: \"CHANGES_REQUESTED\", commit_id: \"${old}\", submitted_at: \"2026-10-30T09:00:00Z\", body: \"kritika: confidence 3/5 with high risk at ${old:0:7}.\"}]
   | .pr.headRefOid = \"${old}\" | .reviews[0].commit_id = \"${head}\""
check "lower-confidence review on the same head after an approval" false \
  ".reviews += [{author: \"porkboiai[bot]\", state: \"COMMENTED\", commit_id: \"${head}\", submitted_at: \"2026-10-30T10:05:00Z\", body: \"kritika: confidence 3/5 with high risk at ${head:0:7}.\"}]"
check "approval then push then lower-confidence review on the new head" false \
  ".pr.headRefOid = \"${old}\"
   | .reviews += [{author: \"porkboiai[bot]\", state: \"COMMENTED\", commit_id: \"${old}\", submitted_at: \"2026-10-30T10:10:00Z\", body: \"kritika: confidence 3/5 with high risk at ${old:0:7}.\"}]"
check "required check failed" false '.checks |= map(if .name == "Kritika / Review" then .conclusion = "FAILURE" else . end)'
check "required check missing" false '.checks |= map(select(.name != "Build Success"))'
check "rerun that passed after a failure" true \
  '.checks += [{name: "Build Success", conclusion: "FAILURE", at: "2026-10-30T09:00:00Z"}]'
check "reviewer login without the [bot] suffix" false '.reviews[0].author = "porkboiai"'
check "approval from someone else" false '.reviews[0].author = "someone"'
check "PR not from porky-bot" false '.pr.author = "jimmy-ungerman"'
check "PR closed" false '.pr.state = "CLOSED"'
check "no required checks reported" false '.required = []'

exit "$failed"
