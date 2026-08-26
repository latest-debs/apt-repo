#!/usr/bin/env bash
# check-catalog.sh - fail if a tool registered in tools.yaml has no published
# release in its <tool>-debian repo.
#
# Why: trivy and yq-go sat registered-but-unpublished for a day while every
# scheduled run went green - "registered but never shipped" was invisible.
# This check makes it a red CI job. A persistent GitHub rate limit also
# fails (with an explicit message) rather than masquerading as success.
#
# Env: GITHUB_TOKEN (contents:read on the org is enough).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_YAML="$ROOT/tools.yaml"
API="https://api.github.com"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

missing=""
unknown=0
total=0

while IFS=$'\t' read -r pkg repo; do
  [ -n "$pkg" ] || continue
  total=$((total + 1))
  code="" attempt=""
  for attempt in 1 2 3; do
    code="$(curl -fsSL -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
      "${AUTH[@]}" "$API/repos/$repo/releases/latest" 2>/dev/null || true)"
    case "$code" in
      200|404) break ;;
      403|429|5??)
        echo "::warning::GitHub API $code (attempt $attempt/3) for $repo; backing off" >&2
        sleep $((attempt * 5))
        ;;
      *)
        break  # 404-ish or unexpected: report below
        ;;
    esac
    code=""
  done
  case "$code" in
    200) : ;;
    404)
      echo "MISSING: $pkg ($repo has no published release)"
      missing="$missing $pkg"
      ;;
    "")
      echo "::error::GitHub API persistently rate-limited checking $repo - NOT counting as pass"
      unknown=$((unknown + 1))
      ;;
    *)
      echo "::error::Unexpected GitHub API $code for $repo"
      unknown=$((unknown + 1))
      ;;
  esac
done < <(python3 - "$TOOLS_YAML" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module missing")
for pkg, meta in yaml.safe_load(open(sys.argv[1])).items():
    print(f"{pkg}\t{meta.get('source', '').removeprefix('https://github.com/')}")
PYEOF
)

echo "Checked $total registered tools."
if [ -n "$missing" ]; then
  echo "::error::Registered but never published:$missing - fix the build or remove from tools.yaml"
  exit 1
fi
if [ "$unknown" -gt 0 ]; then
  echo "::error::$unknown tool(s) could not be verified (rate limit / API error); failing so a real gap can't hide behind a flaky check"
  exit 1
fi
echo "All registered tools have published releases."
