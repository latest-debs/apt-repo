#!/usr/bin/env bash
# sync-profile.sh - generate the org profile's Packages table from tools.yaml.
#
# tools.yaml is the single source of truth for the catalog. This script
# renders the same table that lives in latest-debs/.github profile/README.md
# (description fields in tools.yaml feed the "What it is" column), so the
# profile can never silently drift from the registry again - CI runs
# `--check` against the live profile.
#
# Usage:
#   sync-profile.sh            print the generated Packages table to stdout
#   sync-profile.sh --check    compare against the live profile; exit 1 on drift
#   sync-profile.sh --write <profile-README.md>
#                              splice the table into a local profile checkout
#
# Env: GITHUB_TOKEN (only needed to resolve which tools have published
# releases; unlisted tools are omitted from the table, like trivy pre-release).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_YAML="$ROOT/tools.yaml"
API="https://api.github.com"
PROFILE_REPO="latest-debs/.github"
PROFILE_PATH="profile/README.md"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

api_json() { # retrying GET; prints body, returns 1 on persistent failure
  local url="$1" attempt code
  for attempt in 1 2 3; do
    code="$(curl -fsSL -o /tmp/sp.$$ -w '%{http_code}' --connect-timeout 10 --max-time 30 \
      "${AUTH[@]}" "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then cat /tmp/sp.$$; rm -f /tmp/sp.$$; return 0; fi
    rm -f /tmp/sp.$$
    case "$code" in 403|429|5??) sleep $((attempt * 5));; 404) return 1;; *) return 1;; esac
  done
  return 1
}

MODE="${1:-print}"
case "$MODE" in
  print|--check) ;;
  --write) [ -n "${2:-}" ] || { echo "usage: $0 --write <profile-README.md>" >&2; exit 1; } ;;
  *) echo "usage: $0 [--check|--write <file>]" >&2; exit 1 ;;
esac

generate_table() {
  python3 - "$TOOLS_YAML" "$LIVE_MAP" <<'PYEOF'
import sys, json
try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module missing")
data = yaml.safe_load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))  # pkg -> has_published_release
for pkg, meta in data.items():
    if not live.get(pkg):
        continue  # registered but never published: not user-installable yet
    install = meta.get("debian_name") or pkg
    if install == "NONE":
        # debian_name: NONE is a marker for sid-version comparison tooling
        # (e.g. zed, whose Debian "zed" is an unrelated 1980s editor), not
        # the apt install name.
        install = pkg
    display = meta.get("display") or pkg
    home = (meta.get("homepage") or "").rstrip("/")
    desc = meta.get("description") or "—"
    desc = desc.replace("|", "\\|")
    slug = home.removeprefix("https://github.com/") if home else ""
    tool_cell = f"[{display}]({home})" if home else display
    rel = f"https://github.com/latest-debs/{pkg}-debian/releases"
    badge = (f"[![release](https://img.shields.io/github/v/release/latest-debs/{pkg}-debian"
             f"?display_name=tag&label=)]({rel})")
    fresh = (f"![freshness](https://img.shields.io/endpoint?url=https%3A%2F%2Flatest-debs.github.io"
             f"%2Fapt-repo%2Fdists%2Ffreshness.json&query=$.{pkg})")
    print(f"| {tool_cell} | {desc} | {badge} | {fresh} | `sudo apt install {install}` |")
PYEOF
}

# Which tools have a published release? (Missing/404 → not listed.)
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
LIVE_MAP="$TMPD/live.json"
echo '{}' > "$LIVE_MAP"
while IFS=$'\t' read -r pkg repo; do
  [ -n "$pkg" ] || continue
  if api_json "$API/repos/$repo/releases/latest" >/dev/null 2>&1; then
    jq --arg p "$pkg" '.[$p] = true' "$LIVE_MAP" > "$LIVE_MAP.new" && mv "$LIVE_MAP.new" "$LIVE_MAP"
  fi
done < <(python3 - "$TOOLS_YAML" <<'PYEOF'
import sys, yaml
for pkg, meta in yaml.safe_load(open(sys.argv[1])).items():
    print(f"{pkg}\t{meta.get('source','').removeprefix('https://github.com/')}")
PYEOF
)

TABLE="$(generate_table)"
HEADER='| Tool | What it is | Latest .deb | Fresh | Install |
|------|-----------|-------------|-------|---------|'

case "$MODE" in
  print)
    printf '%s\n%s\n' "$HEADER" "$TABLE"
    ;;
  --check)
    live="$(api_json "https://raw.githubusercontent.com/$PROFILE_REPO/main/$PROFILE_PATH" || true)"
    [ -n "$live" ] || { echo "::error::could not fetch live profile $PROFILE_REPO/$PROFILE_PATH"; exit 1; }
    extracted="$(python3 - "$live" <<'PYEOF'
import sys
text = sys.argv[1]
lines = text.splitlines()
try:
    start = next(i for i, l in enumerate(lines) if l.startswith("| Tool |"))
except StopIteration:
    sys.exit("profile table header not found in live profile")
end = start
for i in range(start + 2, len(lines)):
    if not lines[i].startswith("| "):
        break
    end = i
# rows only - the caller compares against the header-less generated table
print("\n".join(lines[start + 2:end + 1]))
PYEOF
)"
    if [ "$TABLE" != "$extracted" ]; then
      echo "::error::org profile Packages table has drifted from tools.yaml"
      diff <(printf '%s\n' "$extracted") <(printf '%s\n' "$TABLE") | head -20 || true
      echo "Fix: run scripts/sync-profile.sh --write against the .github repo and commit"
      exit 1
    fi
    echo "Profile table in sync with tools.yaml"
    ;;
  --write)
    target="$2"
    python3 - "$target" "$HEADER" "$TABLE" <<'PYEOF'
import sys
path, header, table = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(keepends=True)
hdr_first = header.splitlines()[0]
try:
    start = next(i for i, l in enumerate(lines) if l.startswith(hdr_first))
except StopIteration:
    sys.exit(f"table header not found in {path}")
end = start
for i in range(start + 2, len(lines)):
    if not lines[i].startswith("| "):
        break
    end = i
lines[start:end + 1] = (header + "\n" + table + "\n").splitlines(keepends=True)
open(path, "w").write("".join(lines))
PYEOF
    echo "Updated $target"
    ;;
esac
