#!/usr/bin/env bash
# license-check.sh - recheck the upstream repo's license against the SPDX id
# pinned in package.yaml, at build time.
#
# Upstreams change licenses; this queries the LIVE license on every run so a
# license change can't silently slip new builds through the auto-watch. It is
# warn-only by design: it never blocks a build, it surfaces drift for a
# maintainer (see the README's auditable, test-gated positioning).
#
# Outputs (GITHUB_OUTPUT):
#   license   the upstream's live SPDX identifier ("" if unavailable)
#   pinned    the license pinned in package.yaml ("" if none)

set -euo pipefail

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GITHUB_TOKEN:?}")

# Retry on 403/429/5xx (3 attempts, 5s/15s backoff). Warn-only script: a
# persistent rate limit degrades to a warning, never a silent "" that would
# look like "upstream has no license".
gh_json() {
  local url="$1" attempt code
  for attempt in 1 2 3; do
    code="$(curl -fsSL -o /tmp/lic_json.$$ -w '%{http_code}' "${AUTH[@]}" "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      cat /tmp/lic_json.$$
      rm -f /tmp/lic_json.$$
      return 0
    fi
    rm -f /tmp/lic_json.$$
    case "$code" in
      403|429|5??)
        echo "::warning::GitHub API $code (attempt $attempt/3) in license-check; backing off" >&2
        sleep $((attempt * 5))
        ;;
      404) return 1 ;;
      *)   return 1 ;;
    esac
  done
  echo "::warning::GitHub API persistently rate-limited in license-check; skipping live license comparison" >&2
  return 1
}

yaml_val() {
  awk -v k="$1" -F': *' '$1==k { v=$2; gsub(/["'\'' ]/, "", v); sub(/#.*/, "", v); print v; exit }' package.yaml
}

GITHUB_REPO="$(yaml_val github_repo)"
PINNED="$(yaml_val license)"
[ -n "$GITHUB_REPO" ] || { echo "::error::github_repo not found in package.yaml"; exit 1; }

out() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }

LIVE=""
if repo="$(gh_json "$API/repos/$GITHUB_REPO")"; then
  LIVE="$(printf '%s' "$repo" | jq -r '.license.spdx_id // ""' 2>/dev/null || true)"
fi

out license "$LIVE"
out pinned "$PINNED"

if [ -z "$PINNED" ]; then
  echo "::warning::No license pinned in package.yaml; upstream $GITHUB_REPO reports ${LIVE:-no license metadata}. Consider adding 'license: ${LIVE:-unknown}' to package.yaml."
elif [ -z "$LIVE" ] || [ "$LIVE" = "NOASSERTION" ] || [ "$LIVE" = "Other" ]; then
  echo "::warning::Upstream $GITHUB_REPO reports no recognizable license (pinned: $PINNED). Recheck whether the license changed."
elif [ "$LIVE" != "$PINNED" ]; then
  echo "::warning::Upstream $GITHUB_REPO license appears to have changed: pinned '$PINNED' vs live '$LIVE'. Recheck before the next release."
else
  echo "License recheck OK: $GITHUB_REPO is '$LIVE' (pinned '$PINNED')"
fi
