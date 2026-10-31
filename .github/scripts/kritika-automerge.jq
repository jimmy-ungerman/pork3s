# Decides whether a Renovate PR may be merged on Kritika's verdict.
# Input:  {pr: {state, headRefOid, author, labels: [name]},
#          reviews: [{author, state, body, commit_id, submitted_at}],
#          checks: [{name, conclusion, at}], required: [name]}
# Output: {merge: bool, reasons: [string], verdict: the Kritika review for the head, or null}
.pr.headRefOid as $head
| (.reviews
    | map(select(.author == "porkboiai" and .commit_id == $head and (.body | startswith("kritika:"))))
    | sort_by(.submitted_at)
    | last) as $verdict
| (.checks | group_by(.name) | map(sort_by(.at) | last)) as $latest
| [
    (if .pr.state != "OPEN" then "PR is not open" else empty end),
    (if .pr.author != "porky-bot[bot]" then "PR is not from porky-bot" else empty end),
    (.pr.labels[] | select(. == "hold" or . == "type/major") | "excluded label: \(.)"),
    (if $verdict == null then "no Kritika verdict for the current head"
     elif $verdict.state != "APPROVED"
       or ($verdict.body | test("^kritika: confidence 5/5 with low risk at " + $head[0:7] + "\\.?$") | not)
     then "latest Kritika verdict for the current head is not an approved 5/5 low risk"
     else empty end),
    (if (.required | length) == 0 then "no required checks found" else empty end),
    (.required[] as $name
      | ($latest | map(select(.name == $name)) | first) as $check
      | if $check == null then "required check missing: \($name)"
        elif $check.conclusion != "SUCCESS" then "required check not successful: \($name) (\($check.conclusion))"
        else empty end)
  ] as $reasons
| {merge: ($reasons | length == 0), reasons: $reasons, verdict: $verdict}
