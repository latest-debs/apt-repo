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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

missing=""
unknown=0
total=0

while IFS=$'\t' read -r pkg repo; do
  [ -n "$pkg" ] || continue
  total=$((total + 1))
  # Only the status code matters here, so this is gh_get rather than
  # api_json; the 403/429/5xx backoff it used to spell out lives there now.
  code="$(gh_get "$API/repos/$repo/releases/latest" /dev/null)"
  case "$code" in
    200) : ;;
    404)
      echo "MISSING: $pkg ($repo has no published release)"
      missing="$missing $pkg"
      ;;
    403|429|5??)
      echo "::error::GitHub API persistently rate-limited ($code) checking $repo - NOT counting as pass"
      unknown=$((unknown + 1))
      ;;
    000|"")
      echo "::error::Could not reach the GitHub API for $repo - NOT counting as pass"
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
