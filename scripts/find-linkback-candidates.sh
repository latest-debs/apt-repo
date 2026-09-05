#!/usr/bin/env bash
# find-linkback-candidates.sh - list tracked tools whose upstream README
# does NOT yet mention latest-debs, with the exact Markdown snippet
# SERVICE.md suggests pitching them (see
# SERVICE.md#one-more-ask-link-us-from-your-install-docs).
#
# Read-only reconnaissance for the outreach pass: this script never opens an
# issue or PR on anyone else's repo - that's a maintainer decision made one
# upstream project at a time, not something to automate. It just tells you
# who to ask.
#
# Usage:
#   find-linkback-candidates.sh              print candidates + snippets
#   find-linkback-candidates.sh --repos-only  just "owner/repo", one per line
#                                              (for piping into `gh` by hand)
#
# Env: GITHUB_TOKEN (contents:read; avoids the 60/h unauthenticated limit
# across ~50 tools' README + default-branch lookups).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"

MODE="report"
[ "${1:-}" = "--repos-only" ] && MODE="repos-only"

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$TOOLS_YAML" ] || { echo "ERROR: missing $TOOLS_YAML" >&2; exit 1; }

AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

snippet() {
  local pkg="$1"
  cat <<EOF
### Debian (unofficial, via latest-debs)

Signed, test-gated .deb packages, rebuilt automatically on every release:

    sudo extrepo enable latest-debs
    sudo apt update
    sudo apt install $pkg

See https://github.com/latest-debs/$pkg-debian for details, or
https://latest-debs.github.io for how the packaging pipeline works.
EOF
}

candidates=0
while IFS=$'\t' read -r pkg homepage; do
  [ -n "$pkg" ] || continue
  repo="${homepage#https://github.com/}"
  if [ -z "$repo" ] || [ "$repo" = "$homepage" ]; then
    continue # no GitHub homepage on record; can't check its README
  fi

  # /readme resolves whatever the project actually calls its README -
  # README.md, README.rst (fish-shell), README.adoc, docs/README.md - on the
  # default branch, in one request. Globbing candidate filenames off
  # raw.githubusercontent instead silently skipped every non-.md project.
  readme="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github.raw" \
    "$API/repos/$repo/readme" 2>/dev/null || true)"

  if [ -z "$readme" ]; then
    echo "SKIP $pkg ($repo): no README resolvable via the GitHub API" >&2
    continue
  fi
  if grep -qi "latest-debs" <<< "$readme"; then
    continue # already links back
  fi

  candidates=$((candidates + 1))
  if [ "$MODE" = "repos-only" ]; then
    printf '%s\n' "$repo"
  else
    echo "=== $pkg ($repo) — no latest-debs mention in README.md ==="
    snippet "$pkg"
    echo
  fi
done < <(parse_tools "$TOOLS_YAML" | cut -f1,4)

[ "$MODE" = "repos-only" ] || echo "$candidates candidate(s) — none of these link back yet." >&2
