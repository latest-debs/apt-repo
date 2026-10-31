#!/usr/bin/env bash
# fetch-debian-versions.sh - snapshot each tracked tool's current Debian
# stable package version via Debian's madison service, and publish as
# debian-versions.json alongside the repo.
#
# Debian's madison/sources APIs don't send CORS headers, so this can't be
# fetched live from client-side site JS - it's done here, at rebuild time,
# and served as same-origin JSON instead (same reasoning as why the site
# reads dists/*/Packages rather than hitting anything cross-origin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"
SUITES_JSON="$ROOT/suites.json"
OUT="$ROOT/debian-versions.json"

log() { printf '[debian-versions] %s\n' "$*"; }

command -v jq >/dev/null || { log "ERROR: jq is required"; exit 1; }
[[ -f "$TOOLS_YAML" ]] || { log "ERROR: missing $TOOLS_YAML"; exit 1; }
[[ -f "$SUITES_JSON" ]] || { log "ERROR: missing $SUITES_JSON"; exit 1; }

# Debian's current stable release. Single source of truth is suites.json -
# update it (only it) whenever Debian's next stable release ships; every
# other "trixie" reference in this org (check-suite-parity.sh, the release
# workflow template, latest-debs.github.io/index.html) reads from there too.
STABLE_SUITE="$(jq -r '.stable' "$SUITES_JSON")"

tmp_json="$(mktemp)"
echo '{}' > "$tmp_json"

while IFS=$'\t' read -r pkg dname; do
  [[ -n "$pkg" ]] || continue

  # NONE = tools.yaml has documented that Debian's same-named package is an
  # unrelated tool (e.g. "zed" is a 1980s Unix editor, not zed-industries/zed)
  # - looking it up would show a misleading "Debian has this" version.
  if [[ "$dname" == "NONE" ]]; then
    log "  -> $pkg: Debian's same-named package is unrelated (see tools.yaml); skipping"
    jq --arg pkg "$pkg" '. + {($pkg): null}' "$tmp_json" > "${tmp_json}.new"
    mv "${tmp_json}.new" "$tmp_json"
    continue
  fi

  log "checking $pkg (debian package: $dname)..."

  madison_out=$(curl -fsSL "https://qa.debian.org/madison.php?package=${dname}&text=on" 2>/dev/null || echo "")
  stable_line=$(echo "$madison_out" | awk -F'|' -v suite="$STABLE_SUITE" '$3 ~ "^ *" suite " *$" {print; exit}')

  if [[ -n "$stable_line" ]]; then
    version=$(echo "$stable_line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
    log "  -> $version ($STABLE_SUITE)"
    jq --arg pkg "$pkg" --arg ver "$version" '. + {($pkg): $ver}' "$tmp_json" > "${tmp_json}.new"
  else
    log "  -> not packaged in $STABLE_SUITE"
    jq --arg pkg "$pkg" '. + {($pkg): null}' "$tmp_json" > "${tmp_json}.new"
  fi
  mv "${tmp_json}.new" "$tmp_json"

  sleep 0.5 # be polite to qa.debian.org across ~14 sequential requests
done < <(parse_tools "$TOOLS_YAML" | cut -f1,3)

jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg suite "$STABLE_SUITE" \
   --slurpfile packages "$tmp_json" \
   '{generated_at: $generated_at, suite: $suite, packages: $packages[0]}' > "$OUT"

rm -f "$tmp_json"
log "wrote $OUT:"
cat "$OUT"
