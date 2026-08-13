#!/usr/bin/env bash
# collect-failure-report.sh - assemble a STRUCTURED failure report for a
# failed release.yml run, purely from the GitHub Actions API (run/job/step
# metadata + check annotations) and the builder's own build-summary.json -
# never from scraping log text.
#
# Writes:
#   $FAILURE_REPORT_DIR/failure-report.json   machine-readable
#   $FAILURE_REPORT_DIR/failure-summary.md    human-readable markdown
# and prints the markdown to stdout (feed it to GITHUB_STEP_SUMMARY).
#
# Env: FAILED_RUN_ID, GITHUB_REPOSITORY, GITHUB_TOKEN, FAILURE_REPORT_DIR.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
RUN_ID="${FAILED_RUN_ID:?}"
: "${GITHUB_TOKEN:?}"
OUT="${FAILURE_REPORT_DIR:-.}"
mkdir -p "$OUT"

# Run metadata (structured).
run_meta="$(gh api "repos/$REPO/actions/runs/$RUN_ID" \
  --jq '{id, name, display_title, event, head_branch, created_at, conclusion, run_url: .html_url}')"

# Failed jobs + the steps inside them that failed (structured).
jobs_json="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" \
  --jq '[.jobs[] | {name: .name, conclusion: .conclusion, check_run_url: .check_run_url,
         steps: [.steps[] | select(.conclusion == "failure") | {name: .name}]}
        | select(.conclusion != "success")]')"

# Check annotations - the ::error:: / ::warning:: messages GitHub already
# structures per failed job.
annotations_json="[]"
while IFS= read -r url; do
  [ -n "$url" ] || continue
  ann="$(gh api "$url/annotations" --jq '[.[] | {message, level, path, start_line, end_line}]' 2>/dev/null || echo '[]')"
  annotations_json="$(jq -n --argjson a "$annotations_json" --argjson b "$ann" '$a + $b')"
done < <(jq -r '.[].check_run_url // empty' <<<"$jobs_json")

# Merge the builder's own structured summary when the failed run uploaded one.
builder_json="{}"
if gh run download "$RUN_ID" --repo "$REPO" -n build-summary --dir "$OUT/.builder" >/dev/null 2>&1; then
  local_bs="$(find "$OUT/.builder" -name build-summary.json | head -n1 || true)"
  [ -n "$local_bs" ] && builder_json="$(cat "$local_bs")"
fi
rm -rf "$OUT/.builder"

jq -n \
  --argjson run "$run_meta" \
  --argjson jobs "$jobs_json" \
  --argjson annotations "$annotations_json" \
  --argjson builder "$builder_json" \
  '{run: $run, failed_jobs: $jobs, annotations: $annotations, builder_summary: $builder}' \
  > "$OUT/failure-report.json"

{
  echo "## ❌ Build failed — $REPO"
  jq -r '"**Run:** [\(.run.display_title)](\(.run.run_url)) · event `\(.run.event)` · branch `\(.run.head_branch)` · \(.run.created_at)"' "$OUT/failure-report.json"
  echo
  echo "**Failed jobs / steps**"
  jq -r 'if (.failed_jobs | length) == 0 then "_(none reported)_" else (.failed_jobs[] |
    "  - **\(.name)** — \(.conclusion)" + (if (.steps | length) > 0 then " (failed step: " + ([.steps[].name] | join(", ")) + ")" else "" end)) end' "$OUT/failure-report.json"
  echo
  echo "**Diagnostics (structured annotations)**"
  jq -r 'if (.annotations | length) == 0 then "_(none)_" else (.annotations[] | "  - [`\(.level // "error")`] \(.message)") end' "$OUT/failure-report.json"
  if [ "$builder_json" != "{}" ]; then
    echo
    echo "**Builder summary**"
    jq -r '"  - architectures: \((.builder_summary.architectures // []) | join(", "))" +
            "\n  - distributions: \((.builder_summary.distributions // []) | join(", "))" +
            "\n  - total_packages: \(.builder_summary.total_packages // 0)"' "$OUT/failure-report.json"
  fi
  echo
  echo "<details><summary>raw <code>failure-report.json</code></summary>"
  echo
  echo '```json'
  jq . "$OUT/failure-report.json"
  echo '```'
  echo "</details>"
} > "$OUT/failure-summary.md"

cat "$OUT/failure-summary.md"
