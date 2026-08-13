#!/usr/bin/env bash
# extract-request.sh - parse a package-request issue body (GitHub issue form)
# into outputs: name, repo, about, license.
#
# GitHub issue-form bodies look like:
#
#   ### Tool name
#
#   ripgrep
#
#   ### Upstream repository or homepage
#
#   https://github.com/BurntSushi/ripgrep
#   ...

set -euo pipefail

body="${ISSUE_BODY:-}"
[ -n "$body" ] || { echo "::error::ISSUE_BODY is empty"; exit 1; }

field() {
  awk -v h="$1" '
    $0 == "### " h { f=1; next }
    f && /^### / { exit }
    f && NF { print; exit }
  ' <<< "$body"
}

name="$(field "Tool name")"
upstream="$(field "Upstream repository or homepage")"
about="$(field "What does it do?")"
license="$(field "License")"

[ -n "$name" ] || { echo "::error::missing Tool name in issue body"; exit 1; }
[ -n "$upstream" ] || { echo "::error::missing upstream repository in issue body"; exit 1; }

# Normalize upstream to owner/repo (accept a full github.com URL or bare repo).
case "$upstream" in
  *github.com/*) repo="${upstream#*github.com/}";;
  *github.com:*) repo="${upstream#*github.com:}";;
  *) repo="$upstream";;
esac
repo="$(printf '%s' "$repo" | sed 's|/$||; s|\.git$||')"

out() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }
out "name" "$name"
out "repo" "$repo"
out "about" "$about"
out "license" "$license"