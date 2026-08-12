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
TOOLS_YAML="$ROOT/tools.yaml"
OUT="$ROOT/debian-versions.json"

# Debian's current stable release. Trixie became stable in August 2025
# (bookworm is now oldstable) - update this, and the matching "trixie"
# references in latest-debs.github.io/index.html, whenever Debian's next
# stable release ships.
STABLE_SUITE="trixie"

log() { printf '[debian-versions] %s\n' "$*"; }

command -v jq >/dev/null || { log "ERROR: jq is required"; exit 1; }
[[ -f "$TOOLS_YAML" ]] || { log "ERROR: missing $TOOLS_YAML"; exit 1; }

# Emit "package<TAB>debian_name" lines. debian_name defaults to the
# package name itself unless a tools.yaml entry overrides it (e.g. fd's
# Debian package is "fd-find" - Debian's own "fd" is an unrelated tool).
parse_tools() {
  awk '
    /^[a-zA-Z0-9_.-]+:/ {
      if (pkg != "") print pkg "\t" (dname != "" ? dname : pkg)
      pkg = $0; sub(/:.*/, "", pkg); gsub(/[[:space:]]/, "", pkg)
      dname = ""
      next
    }
    /^  debian_name:/ { dname = $0; sub(/^  debian_name:[[:space:]]*/, "", dname); gsub(/"/, "", dname) }
    END { if (pkg != "") print pkg "\t" (dname != "" ? dname : pkg) }
  ' "$TOOLS_YAML"
}

tmp_json="$(mktemp)"
echo '{}' > "$tmp_json"

while IFS=$'\t' read -r pkg dname; do
  [[ -n "$pkg" ]] || continue
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
done < <(parse_tools)

jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg suite "$STABLE_SUITE" \
   --slurpfile packages "$tmp_json" \
   '{generated_at: $generated_at, suite: $suite, packages: $packages[0]}' > "$OUT"

rm -f "$tmp_json"
log "wrote $OUT:"
cat "$OUT"
