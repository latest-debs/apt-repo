#!/usr/bin/env bash
# set-trigger-secret.sh - store the apt-repo rebuild trigger token as the
# TRIGGER_TOKEN Actions secret on every registered *-debian repo, so each
# repo's release-published webhook can dispatch an immediate apt-repo rebuild.
#
# Run by a maintainer with a token that can manage repository secrets:
#
#   export GH_TOKEN="<org admin / repo-secrets-capable token>"
#   export TRIGGER_TOKEN="<fine-grained PAT scoped to latest-debs/apt-repo
#                          only, Contents:write>"
#   scripts/set-trigger-secret.sh
#
# Idempotent; safe to re-run after registering a repo or rotating the token.
# Repos whose secret cannot be set (token lacks Secrets permission) are
# reported and still covered by the ~6h scheduled rebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"

[ -n "${GH_TOKEN:-}" ] || { echo "ERROR: GH_TOKEN (secret-management capable) is required" >&2; exit 1; }
[ -n "${TRIGGER_TOKEN:-}" ] || { echo "ERROR: TRIGGER_TOKEN value is required" >&2; exit 1; }

mapfile -t repos < <(parse_tools "$TOOLS_YAML" | cut -f2)
[ ${#repos[@]} -gt 0 ] || { echo "ERROR: no tool repos found in $TOOLS_YAML" >&2; exit 1; }

for repo in "${repos[@]}"; do
  if printf '%s' "$TRIGGER_TOKEN" | gh secret set TRIGGER_TOKEN --repo "$repo" >/dev/null 2>&1; then
    echo "→ set TRIGGER_TOKEN on $repo"
  else
    echo "⚠ failed to set TRIGGER_TOKEN on $repo (token lacks Secrets permission?)" >&2
  fi
done

echo "done."
