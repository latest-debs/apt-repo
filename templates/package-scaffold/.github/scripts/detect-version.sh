#!/usr/bin/env bash
# detect-version.sh - determine which upstream version to build.
#
# AUTO mode (schedule trigger or auto=true): compares the latest upstream
# release tag against the newest tag already built in THIS repo, and emits
# should_build=false when nothing new is available so scheduled runs are
# cheap no-ops. Manual mode (workflow_dispatch with auto=false) uses the
# user-provided version verbatim.
#
# Retry-dedup guard: when a scheduled build of a given upstream tag fails,
# the workflow records a failure marker (repo Actions variable
# SMOKE_FAIL_TAG = "<tag>@<epoch>"). Later SCHEDULED runs of the same tag
# within 48h are skipped, so a systemic failure (glibc cliff, asset-shape
# change) doesn't burn a fresh run + failure notification every 3 hours
# (nushell burned 15 identical failures in 2 days before this existed).
# Manual workflow_dispatch runs always retry and ignore the marker, so
# pushing a fix is never blocked: re-run by hand, or just wait 48h.
#
# Rate limits: GitHub API 403/429 responses are retried with backoff and a
# persistent rate limit FAILS the step loudly. Silently translating a 403
# into "no upstream releases found" left trivy unpublished for a full day
# while every scheduled run reported a green no-op.
#
# Outputs (GITHUB_OUTPUT): version, build_version, should_build

set -euo pipefail

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GITHUB_TOKEN:?}")

# curl with 403/429/5xx retry: 3 attempts, 5s/15s backoff. Prints the body
# on success; on persistent rate limit emits a ::error and exits 1 (never
# a silent empty string - callers must not confuse that with "no releases").
gh_json() {
  local url="$1" attempt code
  for attempt in 1 2 3; do
    code="$(curl -fsSL -o /tmp/gh_json.$$ -w '%{http_code}' "${AUTH[@]}" "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      cat /tmp/gh_json.$$
      rm -f /tmp/gh_json.$$
      return 0
    fi
    rm -f /tmp/gh_json.$$
    case "$code" in
      403|429|5??)
        echo "::warning::GitHub API $code (attempt $attempt/3) for $url; backing off"
        sleep $((attempt * 5))
        ;;
      404)
        # Genuinely absent resource - let the caller decide (empty output).
        return 1
        ;;
      "")
        echo "::warning::GitHub API unreachable (attempt $attempt/3) for $url"
        sleep $((attempt * 5))
        ;;
      *)
        echo "::error::Unexpected GitHub API $code for $url"
        exit 1
        ;;
    esac
  done
  echo "::error::GitHub API persistently rate-limited/unavailable (403/429) for $url - NOT treating this as 'no releases'. See https://docs.github.com/rest/rate-limit"
  exit 1
}

yaml_val() {
  awk -v k="$1" -F': *' '$1==k { v=$2; gsub(/["'\'' ]/, "", v); sub(/#.*/, "", v); print v; exit }' package.yaml
}

GITHUB_REPO="$(yaml_val github_repo)"
PACKAGE_NAME="$(yaml_val package_name)"

[ -n "$GITHUB_REPO" ] || { echo "::error::github_repo not found in package.yaml"; exit 1; }
[ -n "$PACKAGE_NAME" ] || { echo "::error::package_name not found in package.yaml"; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "::error::GITHUB_REPOSITORY not set"; exit 1; }

# Normalize a tag for comparison: drop a leading v, drop the "+<build>" suffix
# used by this org's release tags (e.g. v0.2.9+1 -> 0.2.9).
normalize() { printf '%s' "$1" | sed -E 's/^[vV]//; s/\+[0-9]+$//'; }

out() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }

BUILD_VERSION="${BUILD_VERSION:-1}"
AUTO="${AUTO:-false}"
IS_SCHEDULE="${IS_SCHEDULE:-false}"

if [ "$AUTO" != "true" ]; then
  [ -n "${MANUAL_VERSION:-}" ] || { echo "::error::version input is required when auto is off"; exit 1; }
  out version "$MANUAL_VERSION"
  out build_version "$BUILD_VERSION"
  out should_build true
  exit 0
fi

# Latest upstream release (skips drafts and prereleases by default).
UPSTREAM_TAG=""
if resp="$(gh_json "$API/repos/$GITHUB_REPO/releases/latest")"; then
  UPSTREAM_TAG="$(printf '%s' "$resp" | jq -r '.tag_name // empty' 2>/dev/null || true)"
fi
if [ -z "$UPSTREAM_TAG" ]; then
  # Fallback: upstream publishes everything as prerelease, or no release metadata.
  if resp="$(gh_json "$API/repos/$GITHUB_REPO/releases?per_page=1")"; then
    UPSTREAM_TAG="$(printf '%s' "$resp" | jq -r '.[0].tag_name // empty' 2>/dev/null || true)"
  fi
fi
if [ -z "$UPSTREAM_TAG" ]; then
  echo "::notice::No upstream releases found for $GITHUB_REPO; nothing to build"
  out should_build false
  exit 0
fi

# Retry-dedup guard: skip a SCHEDULED rebuild of a tag that failed recently.
# Marker value format: "<upstream-tag>@<unix-epoch-of-failure>".
if [ "$IS_SCHEDULE" = "true" ]; then
  marker="$(gh api "repos/$GITHUB_REPOSITORY/actions/variables/SMOKE_FAIL_TAG" \
              --jq '.value' 2>/dev/null || true)"
  if [ -n "$marker" ]; then
    fail_tag="${marker%@*}"
    fail_at="${marker#*@}"
    now="$(date +%s)"
    if [[ "$fail_at" =~ ^[0-9]+$ ]]; then
      age=$(( now - fail_at ))
      if [ "$fail_tag" = "$UPSTREAM_TAG" ] && [ "$age" -lt 172800 ]; then
        echo "::notice::Upstream $UPSTREAM_TAG failed a scheduled build $((age / 3600))h ago; skipping retry (dedup guard, expires in $(( (172800 - age) / 3600 ))h). Trigger a manual workflow_dispatch to force a retry."
        out should_build false
        exit 0
      fi
    fi
  fi
fi

# Newest tag already built in this repo.
OWN_TAG=""
if resp="$(gh_json "$API/repos/$GITHUB_REPOSITORY/releases/latest")"; then
  OWN_TAG="$(printf '%s' "$resp" | jq -r '.tag_name // empty' 2>/dev/null || true)"
fi
if [ -z "$OWN_TAG" ]; then
  if resp="$(gh_json "$API/repos/$GITHUB_REPOSITORY/tags?per_page=1")"; then
    OWN_TAG="$(printf '%s' "$resp" | jq -r '.[0].name // empty' 2>/dev/null || true)"
  fi
fi

up="$(normalize "$UPSTREAM_TAG")"
own="$(normalize "$OWN_TAG")"

# Already current if the max of (up, own) is own.
if [ -n "$own" ] && [ "$(printf '%s\n%s' "$up" "$own" | sort -V | tail -n1)" = "$own" ]; then
  echo "::notice::Upstream $UPSTREAM_TAG already built as $OWN_TAG; skipping"
  out should_build false
  exit 0
fi

echo "::notice::New upstream release detected: $UPSTREAM_TAG (last built: ${OWN_TAG:-none})"
out version "$UPSTREAM_TAG"
out build_version "$BUILD_VERSION"
out should_build true
