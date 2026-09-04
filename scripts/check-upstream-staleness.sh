#!/usr/bin/env bash
# check-upstream-staleness.sh - flag tools whose upstream has moved ahead of
# what the apt channel carries.
#
# Closes the gap the README used to call out: "if an upstream changes its
# release layout ... the corresponding tool silently stops updating until
# someone fixes the packaging. There's no automated staleness monitor yet."
# The auto-watch in each <tool>-debian repo is what should keep us current;
# this script is the watchdog that notices when it hasn't.
#
# Data sources:
#   - tools.yaml: registry of tracked tools (homepage = upstream GitHub repo)
#   - dists/pkg-repo-map.json on gh-pages: the tag each package's apt copy
#     comes from (same file the redirector uses), so "ours" is exactly what
#     apt serves, not what the packaging repo last released
#   - upstream /releases/latest: the version we should be carrying
#
# A tool is STALE when upstream's latest non-draft release is a newer
# version than ours AND that release is older than the grace window
# (STALE_AFTER_HOURS, default 48) - shorter gaps are the normal
# rebuild + draft-promotion lag, not a broken pipeline.
#
# Usage:
#   check-upstream-staleness.sh              print the report to stdout
#   check-upstream-staleness.sh --update-issue
#                                            also create/update the single
#                                            `stale-package`-labelled tracking
#                                            issue (needs GITHUB_TOKEN with
#                                            issues:write); closes it when
#                                            nothing is stale
#   check-upstream-staleness.sh --json <path>
#                                            also write a machine-readable
#                                            report to <path> (for the public
#                                            status dashboard); combine freely
#                                            with --update-issue
#
# Env: GITHUB_TOKEN (contents:read to call the API at a useful rate; the
# unauthenticated 60/h limit starves a full-catalog run).
# STALE_AFTER_HOURS overrides the grace window (default 48).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
. "$SCRIPT_DIR/lib.sh"

TOOLS_YAML="$ROOT/tools.yaml"
STALE_LABEL="stale-package"
GRACE_HOURS="${STALE_AFTER_HOURS:-48}"
MODE="print"
JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update-issue) MODE="update-issue"; shift;;
    --json) JSON_OUT="$2"; shift 2;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }

REPO="${GITHUB_REPOSITORY:-$ORG/apt-repo}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ours: what the apt channel currently carries, per package. STALE_MAP_URL
# exists for testing: point it at a doctored copy of the map to exercise
# detection without waiting for real staleness.
MAP_URL="${STALE_MAP_URL:-https://raw.githubusercontent.com/$REPO/gh-pages/dists/pkg-repo-map.json}"
if ! api_json "$MAP_URL" > "$TMP/map.json"; then
  echo "::error::could not fetch $MAP_URL - cannot determine what the channel carries" >&2
  exit 1
fi

# Version embedded in a release tag: "<pkg>-v1.2.3+1", "v1.2.3+1", "1.2.3+1"
# are all read as 1.2.3 (same normalization freshness.json applies).
tag_version() {
  local tag="$1" pkg="$2"
  tag="${tag#"$pkg"-}"
  tag="${tag#v}"
  printf '%s' "${tag%%+*}"
}

report_header="| Tool | Ours (apt) | Upstream | Upstream release age |
|------|------------|----------|----------------------|"
stale_rows=""
checked=0
skipped=0
STALE_JSONL="$TMP/stale.jsonl"
: > "$STALE_JSONL"

while IFS=$'\t' read -r pkg homepage; do
  [ -n "$pkg" ] || continue
  upstream_repo="${homepage#https://github.com/}"
  if [ -z "$upstream_repo" ] || [ "$upstream_repo" = "$homepage" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  ours_tag="$(jq -r --arg pkg "$pkg" '.[$pkg].tag // empty' "$TMP/map.json")"
  if [ -z "$ours_tag" ]; then
    skipped=$((skipped + 1))
    continue  # registered but nothing in the apt pool yet; check-catalog.sh owns that state
  fi
  ours="$(tag_version "$ours_tag" "$pkg")"

  if ! upstream_json="$(api_json "$API/repos/$upstream_repo/releases/latest")"; then
    skipped=$((skipped + 1))
    continue  # no latest release (archived, pre-release-only); not a staleness signal
  fi
  upstream_tag="$(jq -r '.tag_name // empty' <<< "$upstream_json")"
  [ -n "$upstream_tag" ] || { skipped=$((skipped + 1)); continue; }
  upstream_ver="$(tag_version "${upstream_tag##*/}" "$pkg")"

  checked=$((checked + 1))
  [ "$upstream_ver" != "$ours" ] || continue
  newest="$(printf '%s\n%s\n' "$ours" "$upstream_ver" | sort -V | tail -n1)"
  [ "$newest" = "$upstream_ver" ] || continue  # ours is ahead; not stale

  published_at="$(jq -r '.published_at // empty' <<< "$upstream_json")"
  pub_epoch=0
  [ -n "$published_at" ] && pub_epoch="$(date -d "$published_at" +%s 2>/dev/null || echo 0)"
  age_hours=$(( ($(date +%s) - pub_epoch) / 3600 ))
  if [ "$pub_epoch" -gt 0 ] && [ "$age_hours" -lt "$GRACE_HOURS" ]; then
    continue  # inside the rebuild + draft-promotion grace window
  fi
  age_cell="$age_hours h"
  [ "$age_hours" -ge "$GRACE_HOURS" ] && age_cell="$((age_hours / 24)) d"
  stale_rows+="| $pkg | $ours | $upstream_ver | $age_cell |
"
  echo "STALE: $pkg (apt $ours, upstream $upstream_ver, released $age_cell ago)"
  jq -nc --arg pkg "$pkg" --arg ours "$ours" --arg upstream "$upstream_ver" --argjson age_hours "$age_hours" \
    '{package:$pkg, ours:$ours, upstream:$upstream, age_hours:$age_hours}' >> "$STALE_JSONL"
done < <(python3 - "$TOOLS_YAML" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module missing")
for pkg, meta in yaml.safe_load(open(sys.argv[1])).items():
    print(f"{pkg}\t{(meta.get('homepage') or '').strip()}")
PYEOF
)

echo "Checked $checked tool(s), skipped $skipped (no GitHub homepage, nothing in pool, or upstream has no latest release)."

if [ -n "$JSON_OUT" ]; then
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson grace_hours "$GRACE_HOURS" \
    --argjson checked "$checked" --argjson skipped "$skipped" --slurpfile stale "$STALE_JSONL" \
    '{generated_at:$generated_at, grace_hours:$grace_hours, checked:$checked, skipped:$skipped, stale:$stale}' \
    > "$JSON_OUT"
fi

build_body() {
  {
    printf 'Upstream has released newer versions than the apt channel carries. Each row below has already\n'
    printf 'outlived the %s-hour grace window (rebuild + draft-promotion lag), so a persistent row means the\n' "$GRACE_HOURS"
    printf 'auto-watch for that tool is failing or blocked - check the tool'"'"'s `-debian` repo Actions log first.\n\n'
    printf '%s\n\n' "$report_header"
    if [ -n "$stale_rows" ]; then printf '%s' "$stale_rows"; else printf '_None - all tracked tools are current._\n'; fi
    printf '\n_Generated by `scripts/check-upstream-staleness.sh` %s · grace STALE_AFTER_HOURS=%s · same data the [freshness badges](https://latest-debs.github.io/apt-repo/dists/freshness.json) render._\n' \
      "$(date -u +%Y-%m-%dT%H:%MZ)" "$GRACE_HOURS"
  }
}

if [ "$MODE" != "update-issue" ]; then
  [ -z "$stale_rows" ] && echo "No stale tools."
  exit 0
fi

[ -n "${GITHUB_TOKEN:-}" ] || { echo "ERROR: --update-issue needs GITHUB_TOKEN" >&2; exit 1; }

ensure_label() {
  jq -n --arg name "$STALE_LABEL" \
    '{name: $name, color: "d93f0b", description: "Upstream release is newer than what the apt channel carries (watchdog)"}' \
    | curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -X POST -d @- \
      -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/labels" 2>/dev/null \
    || true  # 422 "already exists" and rate limits are both non-fatal here
}

issue_number="$(api_json "$API/repos/$REPO/issues?labels=$STALE_LABEL&state=all&per_page=1&sort=created&direction=desc" \
  | jq -r '.[0].number // empty' || true)"
body_file="$TMP/body.md"
build_body > "$body_file"
title="Upstream staleness: tools ahead of the apt channel"

payload="$(jq -Rs '{body: .}' < "$body_file")"

if [ -n "$stale_rows" ]; then
  ensure_label
  if [ -n "$issue_number" ]; then
    curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -X PATCH -d "$payload" \
      -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/issues/$issue_number" \
      || { echo "::error::failed to update tracking issue #$issue_number" >&2; exit 1; }
    curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -X PATCH -d '{"state": "open"}' \
      -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/issues/$issue_number" \
      || true
    echo "Updated tracking issue #$issue_number ($title)."
  else
    issue_number="$(jq -Rs --arg t "$title" --arg lbl "$STALE_LABEL" \
      '{title: $t, body: ., labels: [$lbl]}' < "$body_file" \
      | curl -fsSL --connect-timeout 10 --max-time 30 -X POST -d @- \
        -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/issues" \
      | jq -r 'if (.number | type) == "number" then .number | tostring else "" end')" \
      || { echo "::error::failed to create tracking issue" >&2; exit 1; }
    [ -n "$issue_number" ] || { echo "::error::issue creation returned no issue number (check token scopes)" >&2; exit 1; }
    echo "Created tracking issue #$issue_number ($title)."
  fi
else
  if [ -n "$issue_number" ]; then
    state="$(api_json "$API/repos/$REPO/issues/$issue_number" | jq -r '.state // "closed"')"
    if [ "$state" = "open" ]; then
      printf 'All clear as of %s - closing (watchdog reopens this automatically if staleness returns).\n' \
        "$(date -u +%Y-%m-%dT%H:%MZ)" \
        | curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -X POST -d @- \
          -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/issues/$issue_number/comments" \
        || true
      curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null -X PATCH -d '{"state": "closed"}' \
        -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/issues/$issue_number" \
        || true
      echo "Closed tracking issue #$issue_number (nothing stale)."
    fi
  else
    echo "Nothing stale; no tracking issue to update."
  fi
fi
