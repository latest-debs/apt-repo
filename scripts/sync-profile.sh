#!/usr/bin/env bash
# sync-profile.sh - generate the org profile's one-line Packages summary
# from tools.yaml.
#
# The profile used to carry the full 51-row catalog table, which was ~24% of
# the page and duplicated - worse - what latest-debs.github.io already
# renders live (searchable, sortable, per-suite, with the real installed
# versions). The profile now carries a count plus a sample and links there.
#
# tools.yaml stays the single source of truth: this still generates that
# line, so the count can never silently drift from the registry - CI runs
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
START="<!-- packages:start -->"
END="<!-- packages:end -->"
SAMPLE_N=12   # names shown inline before "and N more"
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

generate_summary() {
  python3 - "$TOOLS_YAML" "$LIVE_MAP" "$SAMPLE_N" <<'PYEOF'
import sys, json
try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module missing")
data = yaml.safe_load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))  # pkg -> has_published_release
n = int(sys.argv[3])
# Installable tools only - registered-but-unpublished isn't user-facing yet.
pkgs = [p for p in data if live.get(p)]
names = [(data[p].get("display") or p) for p in pkgs[:n]]
rest = len(pkgs) - len(names)
tail = f", and {rest} more" if rest > 0 else ""
print(f"**{len(pkgs)} tools**, each a signed, test-gated `.deb` rebuilt automatically on every "
      f"upstream release — {', '.join(f'`{x}`' for x in names)}{tail}.")
print()
print("Browse the full catalogue live — searchable, with the version we ship next to what Debian "
      "and Ubuntu ship — at **[latest-debs.github.io](https://latest-debs.github.io/#packages)**.")
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

SUMMARY="$(generate_summary)"

extract_block() { # stdin: profile text -> the text between the markers
  python3 - "$START" "$END" <<'PYEOF'
import sys
start_m, end_m = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
if start_m not in text or end_m not in text:
    sys.exit(f"markers {start_m} / {end_m} not found in profile")
print(text.split(start_m, 1)[1].split(end_m, 1)[0].strip())
PYEOF
}

case "$MODE" in
  print)
    printf '%s\n' "$SUMMARY"
    ;;
  --check)
    # Fetch via the Contents API using gh (pre-installed on runners, handles
    # auth). raw.githubusercontent.com is CDN-backed and can serve stale
    # content for minutes after a commit, failing this check with a false
    # positive on a just-merged profile update. The Contents API has strong
    # read-after-write consistency.
    live="$(gh api "repos/$PROFILE_REPO/contents/$PROFILE_PATH" --jq '.content' | base64 -d || true)"
    [ -n "$live" ] || { echo "::error::could not fetch live profile $PROFILE_REPO/$PROFILE_PATH"; exit 1; }
    echo "DEBUG: fetched live profile: ${#live} bytes"
    echo "${live:0:300}"
    echo "DEBUG: packages:start found: $(echo "$live" | grep -c "packages:start")"
    echo "DEBUG: first line: $(echo "$live" | head -1 | cat -A)"
    extracted="$(printf '%s' "$live" | extract_block)" || exit 1
    if [ "$SUMMARY" != "$extracted" ]; then
      echo "::error::org profile Packages summary has drifted from tools.yaml"
      diff <(printf '%s\n' "$extracted") <(printf '%s\n' "$SUMMARY") | head -20 || true
      echo "Fix: run scripts/sync-profile.sh --write against the .github repo and commit"
      exit 1
    fi
    echo "Profile summary in sync with tools.yaml"
    ;;
  --write)
    target="$2"
    python3 - "$target" "$START" "$END" "$SUMMARY" <<'PYEOF'
import sys
path, start_m, end_m, summary = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(path).read()
if start_m not in text or end_m not in text:
    sys.exit(f"markers {start_m} / {end_m} not found in {path}")
head, rest = text.split(start_m, 1)
_, tail = rest.split(end_m, 1)
open(path, "w").write(f"{head}{start_m}\n\n{summary}\n\n{end_m}{tail}")
PYEOF
    echo "Updated $target"
    ;;
esac
