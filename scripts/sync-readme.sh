#!/usr/bin/env bash
# sync-readme.sh - regenerate the package table in README.md from tools.yaml.
#
# The "Packages" section of README.md is generated so it can never drift
# from tools.yaml. This script rewrites the table between the
# <!-- packages:start --> / <!-- packages:end --> markers and fails if the
# markers are missing (so the README edit is explicit, not invented).
#
# Usage:
#   sync-readme.sh           rewrite the README table in place
#   sync-readme.sh --check   compare against the current README; exit 1 on
#                            drift (CI: tools.yaml PRs must carry the
#                            regenerated table, not wait for the next rebuild)
#
# Requirements: yq or python3 (either is enough; tools.yaml is simple YAML).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_YAML="$ROOT/tools.yaml"
LICENSES_JSON="$ROOT/licenses.json"
README="$ROOT/README.md"
START="<!-- packages:start -->"
END="<!-- packages:end -->"

CHECK=false
[ "${1:-}" = "--check" ] && CHECK=true

die() { printf '[sync-readme] ERROR: %s\n' "$*" >&2; exit 1; }

tmp_readme="$(mktemp)"
trap 'rm -f "$tmp_readme"' EXIT

grep -qF "$START" "$README" || die "README.md is missing the $START marker"
grep -qF "$END" "$README"   || die "README.md is missing the $END marker"

# Parse tools.yaml into TAB-separated "name\tinstall\tupstream" lines.
# install uses debian_name when present (e.g. fd is packaged as fd-find).
rows=""
if command -v yq >/dev/null 2>&1; then
  rows="$(yq -r 'to_entries[] | [.key, (.value.debian_name // .key), (.value.homepage // "")] | @tsv' "$TOOLS_YAML")"
elif command -v python3 >/dev/null 2>&1; then
  rows="$(python3 - "$TOOLS_YAML" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module missing (install python3-yaml or yq)")
rows = []
for pkg, meta in yaml.safe_load(open(sys.argv[1])).items():
    install = meta.get("debian_name") or pkg
    upstream = meta.get("homepage") or ""
    rows.append(f"{pkg}\t{install}\t{upstream}")
print("\n".join(rows))
PYEOF
)"
else
  die "need yq or python3 with yaml support to parse tools.yaml"
fi

[ -n "$rows" ] || die "no packages found in $TOOLS_YAML"

# License lookup, sourced from licenses.json (written by fetch-licenses.sh,
# which reads it fresh from each tool's package.yaml). Missing file or
# missing entry both degrade to "—" rather than failing the sync - a local
# run without the license snapshot step should still produce a valid table.
license_for() {
  local pkg="$1"
  [ -f "$LICENSES_JSON" ] && command -v jq >/dev/null 2>&1 || { echo "—"; return; }
  jq -r --arg pkg "$pkg" '.packages[$pkg] // "—"' "$LICENSES_JSON"
}

# Generate the table block (marker lines inclusive).
{
  printf '%s\n' "$START"
  printf '\n| Package | License | Install | Upstream |\n'
  printf '|---------|---------|---------|----------|\n'
  local_IFS="$IFS"
  IFS=$'\n'
  for row in $rows; do
    name=""; install=""; upstream=""
    IFS=$'\t' read -r name install upstream <<< "$row"
    if [ "$install" = "NONE" ]; then
      # debian_name: NONE is a marker for sid-version comparison tooling
      # (e.g. zed, whose Debian "zed" is an unrelated 1980s editor), not
      # the apt install name - same rule sync-profile.sh applies.
      install="$name"
    fi
    license="$(license_for "$name")"
    if [ -n "$upstream" ]; then
      printf '| `%s` | %s | `apt install %s` | [%s](%s) |\n' "$name" "$license" "$install" "${upstream#https://github.com/}" "$upstream"
    else
      printf '| `%s` | %s | `apt install %s` | — |\n' "$name" "$license" "$install"
    fi
  done
  IFS="$local_IFS"
  printf '\n%s\n' "$END"
} > "$tmp_readme"

if $CHECK; then
  # Compare the generated block against what's between the markers now.
  current="$(python3 - "$README" "$START" "$END" <<'PYEOF'
import sys
readme, start, end = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()
lines = open(readme).read().splitlines(keepends=True)
out, mode = [], "skip"
for ln in lines:
    if ln.strip() == start:
        out.append(ln)
        mode = "keep"
        continue
    if ln.strip() == end:
        out.append(ln)
        mode = "done"
        continue
    if mode == "keep":
        out.append(ln)
open("/dev/stdout", "w").write("".join(out))
PYEOF
)"
  if [ "$current" != "$(cat "$tmp_readme")" ]; then
    diff <(printf '%s\n' "$current") "$tmp_readme" | head -20 || true
    die "README package table has drifted from tools.yaml - run scripts/sync-readme.sh and commit the result"
  fi
  echo "[sync-readme] README package table in sync with $TOOLS_YAML"
  exit 0
fi

# Splice the new block into README.md.
python3 - "$README" "$tmp_readme" "$START" "$END" <<'PYEOF'
import sys
readme, block_path, start, end = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
block = open(block_path).read()
lines = open(readme).read().splitlines(keepends=True)
out, mode = [], "copy"
for ln in lines:
    if ln.strip() == start:
        out.append(block)
        mode = "skip"
        continue
    if ln.strip() == end:
        mode = "copy"
        continue
    if mode == "copy":
        out.append(ln)
open(readme, "w").write("".join(out))
PYEOF

echo "[sync-readme] updated $README from $TOOLS_YAML"