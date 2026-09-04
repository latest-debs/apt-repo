#!/usr/bin/env bash
# report-workflow-failure.sh - open/comment on a single `pipeline-failure`
# tracking issue when a critical scheduled workflow itself breaks (distinct
# from "packages are stale" - this is "the machinery that detects and fixes
# that is broken"). Meant to run as an `if: failure()` step at the end of
# rebuild.yml and staleness.yml: those two are the only automated alerting a
# single maintainer has, so a broken run has to be loud, not a red tile in
# Actions that nobody happens to be looking at.
#
# Never auto-closes (unlike the stale-package issue, there's no computed
# "all clear" state for a workflow failure) - a maintainer closes it by hand
# once the underlying break is fixed, same human-gate pattern as everything
# else in this pipeline.
#
# Usage: report-workflow-failure.sh "<human-readable workflow name>"
# Env: GH_TOKEN (issues:write), GITHUB_REPOSITORY, GITHUB_RUN_ID - all set
# automatically inside GitHub Actions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"

WORKFLOW_NAME="${1:?usage: report-workflow-failure.sh <workflow-name>}"
LABEL="pipeline-failure"
REPO="${GITHUB_REPOSITORY:-$ORG/apt-repo}"
RUN_URL="https://github.com/$REPO/actions/runs/${GITHUB_RUN_ID:-}"

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }
: "${GH_TOKEN:?GH_TOKEN required}"

gh label create "$LABEL" --repo "$REPO" \
  --color d93f0b \
  --description "A critical scheduled workflow failed - the pipeline's own safety net may be down" \
  >/dev/null 2>&1 || true  # already exists / rate limit - non-fatal

issue_number="$(gh issue list --repo "$REPO" --label "$LABEL" --state all --limit 1 \
  --json number --jq '.[0].number // empty')"

body="**$WORKFLOW_NAME** failed: $RUN_URL

This is one of the two workflows a single maintainer relies on to catch a broken pipeline automatically (scheduled rebuild + upstream staleness watchdog). Treat this as higher priority than a normal \`stale-package\` flag - if it keeps failing, packages can go stale with no other warning."

if [ -n "$issue_number" ]; then
  gh issue comment "$issue_number" --repo "$REPO" --body "$body"
  gh issue reopen "$issue_number" --repo "$REPO" >/dev/null 2>&1 || true
  echo "Commented on existing pipeline-failure issue #$issue_number."
else
  gh issue create --repo "$REPO" \
    --title "Pipeline failure: a critical scheduled workflow is erroring" \
    --label "$LABEL" --body "$body"
fi
