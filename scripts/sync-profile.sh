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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
PROFILE_REPO="latest-debs/.github"
PROFILE_PATH="profile/README.md"
START="<!-- packages:start -->"
END="<!-- packages:end -->"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

MODE="${1:-print}"
case "$MODE" in
  print|--check) ;;
  --write) [ -n "${2:-}" ] || { echo "usage: $0 --write <profile-README.md>" >&2; exit 1; } ;;
  *) echo "usage: $0 [--check|--write <file>]" >&2; exit 1 ;;
esac

generate_summary() {
    # Deliberately number-free: a tools count (or sample list) here drifts on
    # every tools.yaml change and forces manual edits to the profile repo.
    # The live catalogue at latest-debs.github.io is the source of truth.
    cat <<'BLOCK'
Every tool is a signed, test-gated `.deb`, rebuilt automatically on every
upstream release.

Browse the full catalogue live — searchable, with the version we ship next to what Debian and Ubuntu ship — at **[latest-debs.github.io](https://latest-debs.github.io/#packages)**.
BLOCK
}

# NOTE: no live-release API lookups anymore - the summary no longer embeds a
# count or sample list, so there is nothing here to query or drift.

SUMMARY="$(generate_summary)"

extract_block() { # stdin: profile text -> the text between the markers
  # NOTE: must NOT use a heredoc here — the heredoc would be python3's
  # stdin, clobbering the pipe input. Pass the script via -c instead.
  python3 -c '
import sys
start_m, end_m = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
if start_m not in text or end_m not in text:
    sys.exit(f"markers {start_m} / {end_m} not found in profile")
print(text.split(start_m, 1)[1].split(end_m, 1)[0].strip())
' "$START" "$END"
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
