#!/usr/bin/env bash
# sync-readme.sh - regenerate the package table in README.md from tools.yaml.
#
# The "Available packages" section of README.md is generated so it can never
# drift from tools.yaml. This script rewrites the table between the
# <!-- packages:start --> / <!-- packages:end --> markers and fails if the
# markers are missing (so the README edit is explicit, not invented).
#
# Requirements: yq or python3 (either is enough; tools.yaml is simple YAML).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_YAML="$ROOT/tools.yaml"
README="$ROOT/README.md"
START="<!-- packages:start -->"
END="<!-- packages:end -->"

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

# Generate the table block (marker lines inclusive).
{
  printf '%s\n' "$START"
  printf '\n| Package | Install | Upstream |\n'
  printf '|---------|---------|----------|\n'
  local_IFS="$IFS"
  IFS=$'\n'
  for row in $rows; do
    name=""; install=""; upstream=""
    IFS=$'\t' read -r name install upstream <<< "$row"
    if [ -n "$upstream" ]; then
      printf '| `%s` | `apt install %s` | [%s](%s) |\n' "$name" "$install" "${upstream#https://github.com/}" "$upstream"
    else
      printf '| `%s` | `apt install %s` | — |\n' "$name" "$install"
    fi
  done
  IFS="$local_IFS"
  printf '\n%s\n' "$END"
} > "$tmp_readme"

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