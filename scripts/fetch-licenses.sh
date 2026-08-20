#!/usr/bin/env bash
# fetch-licenses.sh - snapshot each tracked tool's declared SPDX license
# from its <tool>-debian package.yaml, and publish as licenses.json
# alongside the repo.
#
# package.yaml (in each <tool>-debian repo) is the single source of truth
# for a package's declared license - it's what vet time and the license-
# recheck gate in each tool's release workflow both read. This script
# re-reads it fresh on every rebuild rather than duplicating the value into
# tools.yaml, so the published "License" column can never drift from what
# the pipeline itself actually checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"
OUT="$ROOT/licenses.json"

log() { printf '[fetch-licenses] %s\n' "$*"; }

command -v jq >/dev/null || { log "ERROR: jq is required"; exit 1; }
[[ -f "$TOOLS_YAML" ]] || { log "ERROR: missing $TOOLS_YAML"; exit 1; }

tmp_json="$(mktemp)"
echo '{}' > "$tmp_json"

while IFS=$'\t' read -r pkg url; do
  [[ -n "$pkg" ]] || continue
  repo="${url##https://github.com/}"
  raw="https://raw.githubusercontent.com/$repo/main/package.yaml"
  log "checking $pkg ($repo)..."

  license="$(curl -fsSL "$raw" 2>/dev/null | awk -F': *' '/^license:/{print $2; exit}')"

  if [[ -n "$license" ]]; then
    log "  -> $license"
    jq --arg pkg "$pkg" --arg lic "$license" '. + {($pkg): $lic}' "$tmp_json" > "${tmp_json}.new"
  else
    log "  -> WARN: no license declared in $raw"
    jq --arg pkg "$pkg" '. + {($pkg): null}' "$tmp_json" > "${tmp_json}.new"
  fi
  mv "${tmp_json}.new" "$tmp_json"
done < <(parse_tools "$TOOLS_YAML" | cut -f1,2)

jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --slurpfile packages "$tmp_json" \
   '{generated_at: $generated_at, packages: $packages[0]}' > "$OUT"

rm -f "$tmp_json"
log "wrote $OUT:"
cat "$OUT"
