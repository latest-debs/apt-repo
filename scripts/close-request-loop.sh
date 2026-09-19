#!/usr/bin/env bash
# close-request-loop.sh - close the loop on package requests.
#
# When a requested tool publishes its first .deb release, the originating
# package-request issue (labeled package-request, tool name in the
# "### Tool name" field) gets a comment pointing at the install command and
# is closed. Requesters become advocates; the request queue stays honest.
#
# Input: dists/changed-pkgs.tsv (written by build-repo.sh - packages whose
# tag changed this run). Requires GH_TOKEN with issues:write.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGED="$ROOT/dists/changed-pkgs.tsv"

[ -f "$CHANGED" ] || exit 0
[ -s "$CHANGED" ] || exit 0
[ -n "${GITHUB_REPOSITORY:-}" ] || exit 0
[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || exit 0

GH="${GH_TOKEN:-$GITHUB_TOKEN}"
API="https://api.github.com"

echo "[request-loop] changed packages this run:"
cat "$CHANGED"

# tool_name <issue-body on stdin> - the value of the request template's
# "### Tool name" field (first non-empty line after the header).
tool_name() {
  awk '/### Tool name/{f=1;next} f && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

while IFS=$'\t' read -r pkg tag; do
  [ -n "$pkg" ] || continue
  issues="$(curl -fsSL --connect-timeout 10 --max-time 60 \
    -H "Authorization: token $GH" \
    "$API/repos/$GITHUB_REPOSITORY/issues?labels=package-request&state=open&per_page=100" 2>/dev/null || true)"
  [ -n "$issues" ] || continue

  echo "$issues" | jq -c '.[]' | while read -r issue; do
    num="$(jq -r '.number' <<<"$issue")"
    title="$(jq -r '.title // ""' <<<"$issue")"
    body="$(jq -r '.body // ""' <<<"$issue")"
    name="$(tool_name <<<"$body")"
    [ -z "$name" ] && name="$title"
    # word-exact, case-insensitive match on the requested tool name
    if ! printf '%s' "$name" | grep -qxiF "$pkg"; then
      continue
    fi
    install_name="$pkg"
    comment="📦 Shipped! [\`$pkg\`]($(
      printf '%s' "$issue" | jq -r '.html_url // ""' | sed 's|/issues/|/releases/|'
    )) is live in the apt repo as of \`$tag\`.

\`\`\`
sudo apt update
sudo apt install $install_name
\`\`\`

Thanks for the request — closing this as completed. If anything's off with the packaging, reopen or file a new issue."
    curl -fsSL -X POST \
      -H "Authorization: token $GH" -H "Accept: application/vnd.github+json" \
      -d "$(jq -n --arg b "$comment" '{body: $b}')" \
      "$API/repos/$GITHUB_REPOSITORY/issues/$num/comments" >/dev/null 2>&1 \
      && echo "[request-loop] commented on #$num ($pkg)" \
      || echo "[request-loop] WARN: comment failed on #$num"
    curl -fsSL -X PATCH \
      -H "Authorization: token $GH" -H "Accept: application/vnd.github+json" \
      -d '{"state": "closed", "state_reason": "completed"}' \
      "$API/repos/$GITHUB_REPOSITORY/issues/$num" >/dev/null 2>&1 \
      && echo "[request-loop] closed #$num" \
      || echo "[request-loop] WARN: close failed on #$num"
  done
done < "$CHANGED"
