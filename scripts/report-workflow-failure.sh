#!/usr/bin/env bash
# report-workflow-failure.sh - open/comment on a single `pipeline-failure`
# tracking issue when a critical scheduled workflow itself breaks (distinct
# from "packages are stale" - this is "the machinery that detects and fixes
# that is broken"). Meant to run as an `if: failure()` step at the end of
# rebuild.yml and staleness.yml: those two are the only automated alerting a
# single maintainer has, so a broken run has to be loud, not a red tile in
# Actions that nobody happens to be looking at.
#
# `--recovered` is the all-clear path, run as an `if: success()` step in the
# same two workflows. This used to be a deliberate no-op - the reasoning was
# that a workflow failure has no computed "all clear" state, so a maintainer
# should close the issue by hand. In practice that cost more trust than it
# bought: issue #20 stayed open for ~11h after the rebuild recovered, and an
# alarm that is stale as often as it is real stops being read at all. The
# all-clear IS computable, just not from one run: one issue tracks both
# critical workflows, so this run passing is only half the answer and the
# other workflow's latest completed run has to be green too.
#
# Usage: report-workflow-failure.sh "<human-readable workflow name>"
#        report-workflow-failure.sh --recovered "<human-readable name>"
# Env: GH_TOKEN (issues:write), GITHUB_REPOSITORY, GITHUB_RUN_ID - all set
# automatically inside GitHub Actions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"

MODE="report"
if [ "${1:-}" = "--recovered" ]; then
  MODE="recovered"
  shift
fi

WORKFLOW_NAME="${1:?usage: report-workflow-failure.sh [--recovered] <workflow-name>}"

# The two workflows that share this issue - see the --recovered note above.
CRITICAL_WORKFLOWS="rebuild.yml staleness.yml"
LABEL="pipeline-failure"
REPO="${GITHUB_REPOSITORY:-$ORG/apt-repo}"
RUN_URL="https://github.com/$REPO/actions/runs/${GITHUB_RUN_ID:-}"

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }
: "${GH_TOKEN:?GH_TOKEN required}"

if [ "$MODE" = "recovered" ]; then
  issue_number="$(gh issue list --repo "$REPO" --label "$LABEL" --state open \
    --limit 1 --json number --jq '.[0].number // empty')"
  [ -n "$issue_number" ] || { echo "No open $LABEL issue; nothing to close."; exit 0; }

  # This workflow's own run is still in progress, so `--status completed`
  # would match the *previous* run of it - which is very likely the failure
  # that opened the issue, and would block the close forever. Skip self; the
  # `if: success()` gate is what vouches for this run.
  ref="${GITHUB_WORKFLOW_REF:-}"
  self="$(basename "${ref%%@*}")"

  for wf in $CRITICAL_WORKFLOWS; do
    if [ "$wf" = "$self" ]; then continue; fi
    conclusion="$(gh run list --repo "$REPO" --workflow "$wf" --branch main \
      --status completed --limit 1 --json conclusion --jq '.[0].conclusion // empty')"
    if [ -n "$conclusion" ] && [ "$conclusion" != "success" ]; then
      echo "$wf last completed run is '$conclusion'; leaving #$issue_number open."
      exit 0
    fi
  done

  gh issue close "$issue_number" --repo "$REPO" --comment "**$WORKFLOW_NAME** recovered: $RUN_URL

The latest completed run of both critical workflows (scheduled rebuild + upstream staleness watchdog) is green, so the pipeline's safety net is back up. This reopens automatically if either one fails again."
  echo "Closed pipeline-failure issue #$issue_number."
  exit 0
fi

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
