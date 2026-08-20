#!/usr/bin/env bash
# comment-on-failure.sh - post the "vet/scaffold failed" comment on a
# package-request issue, used by both the vet job and the approve job in
# package-request.yml (their failure-comment step was previously duplicated
# verbatim between the two).
#
# A Debian-parity failure gets the specific policy explanation (pointing at
# the suite(s) already carrying the tool); any other failure gets a generic
# "check the run logs" comment.
#
# Env: GH_TOKEN, NUMBER, REPO, RUNNER_TEMP (all already set identically by
# both call sites' `env:` blocks - see package-request.yml).
# Args: extra label(s) to remove alongside "processing" (e.g. the approve
# job's issue also carries "awaiting-approval").

set -euo pipefail

remove_args=(--remove-label "processing")
for label in "$@"; do
  remove_args+=(--remove-label "$label")
done
gh issue edit "$NUMBER" --repo "$REPO" "${remove_args[@]}"

parity_report="$RUNNER_TEMP/debian-parity-report.json"
if [ -f "$parity_report" ] && [ "$(jq -r '.gate' "$parity_report" 2>/dev/null)" = "fail" ]; then
  pkg="$(jq -r '.package' "$parity_report")"
  up="$(jq -r '.upstream_version' "$parity_report")"
  suites="$(jq -r '.parity_suites | join(", ")' "$parity_report")"
  first_suite="$(jq -r '.parity_suites[0]' "$parity_report")"
  body_file="$RUNNER_TEMP/parity-comment.md"
  cat > "$body_file" <<EOF
❌ Not packaging **${pkg}** — Debian already carries it at the latest upstream version (\`${up}\`) in: **${suites}**.

Per policy ([Debian parity](https://github.com/latest-debs/apt-repo/blob/main/README.md#debian-parity-when-we-step-aside)), we don't duplicate a suite that's already current — it'd just be a second, lower-trust copy of what Debian ships there.

If you already run ${first_suite}, plain \`apt install ${pkg}\` already gets you that version. Otherwise, pin just this one package to ${first_suite} instead of enabling it wholesale — see the policy doc for the safe install snippet.
EOF
  gh issue comment "$NUMBER" --repo "$REPO" --body-file "$body_file"
else
  gh issue comment "$NUMBER" --repo "$REPO" --body "❌ Could not auto-package this request. Check the [run logs]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID) for details, or ask a maintainer to look at it manually."
fi
