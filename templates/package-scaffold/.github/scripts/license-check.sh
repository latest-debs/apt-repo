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

yaml_val() {
  awk -v k="$1" -F': *' '$1==k { v=$2; gsub(/["'\'' ]/, "", v); sub(/#.*/, "", v); print v; exit }' package.yaml
}

GITHUB_REPO="$(yaml_val github_repo)"
PINNED="$(yaml_val license)"
[ -n "$GITHUB_REPO" ] || { echo "::error::github_repo not found in package.yaml"; exit 1; }

out() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }

LIVE=""
repo="$(curl -fsSL "${AUTH[@]}" "$API/repos/$GITHUB_REPO" 2>/dev/null || true)"
LIVE="$(printf '%s' "$repo" | jq -r '.license.spdx_id // ""' 2>/dev/null || true)"

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
