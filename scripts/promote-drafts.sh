#!/usr/bin/env bash
# promote-drafts.sh - list or publish pending draft releases across all
# <tool>-debian repos from one command.
#
# Every build lands as a draft GitHub release that a maintainer reviews and
# publishes by hand (the draft-before-publish human gate). That gate is
# deliberate - and it means promotion lags whenever a maintainer is away.
# This script shrinks that lag to one command: review the list, then publish
# them in a single pass. Publishing a release fires the notify-apt-repo
# webhook automatically, so the apt index rebuilds within minutes.
#
# Usage:
#   promote-drafts.sh                      # list pending drafts (dry-run)
#   promote-drafts.sh --publish            # promote every listed draft
#   promote-drafts.sh --repo latest-debs/uv-debian [--publish]
#                                          # scope to one repo (repeatable)
#   promote-drafts.sh --publish --yes      # no confirmation prompt (CI)
#
# What it does NOT do: review. Read the draft's release notes and check the
# workflow run that produced it before promoting - that human review is the
# supply-chain gate the whole pipeline leans on.
#
# Requirements: curl + jq, and a token with Contents:write on the *-debian
# repos: GH_TOKEN (a fine-grained org token like ORG_ADMIN_TOKEN works), or
# unauthenticated for read-only listing at the shared 60/h rate limit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"

TOOLS_YAML="$ROOT/tools.yaml"

PUBLISH=false
ASSUME_YES=false
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=true; shift;;
    --yes|-y) ASSUME_YES=true; shift;;
    --repo) TARGETS+=("remote:$2"); shift 2;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")
if $PUBLISH && [ -z "$TOKEN" ]; then
  echo "ERROR: --publish needs GH_TOKEN (Contents:write on the *-debian repos); unauthenticated runs can list only" >&2
  exit 1
fi

api_json() { # retrying GET; prints body, returns 1 on persistent failure
  local url="$1" attempt code
  for attempt in 1 2 3; do
    code="$(curl -fsSL -o "$TMP/api.json" -w '%{http_code}' --connect-timeout 10 \
      --max-time 30 "${AUTH[@]}" "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then cat "$TMP/api.json"; return 0; fi
    case "$code" in
      403|429|5??) sleep $((attempt * 5));;
      *) return 1;;
    esac
  done
  return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Target repos: explicit --repo, otherwise every registered tool's repo.
if [ ${#TARGETS[@]} -eq 0 ]; then
  while IFS=$'\t' read -r _pkg src; do
    [ -n "$src" ] && TARGETS+=("remote:${src#https://github.com/}")
  done < <(parse_tools "$TOOLS_YAML" | cut -f1,2)
fi
[ ${#TARGETS[@]} -gt 0 ] || { echo "no target repos (tools.yaml empty?)" >&2; exit 1; }

# Phase 1 - scan. One line per pending draft, TSV: repo \t tag \t id \t
# created \t assets. Counters survive because the loop reads a herestring,
# not a pipe.
DRAFTS=""
TOTAL=0
for target in "${TARGETS[@]}"; do
  repo="${target#remote:}"
  repo_drafts="$(api_json "$API/repos/$repo/releases?per_page=100" 2>/dev/null \
    | jq -r '.[] | select(.draft) | [.tag_name, .id, .created_at, (.assets | length)] | @tsv' || true)"
  [ -n "$repo_drafts" ] || continue
  while IFS=$'\t' read -r tag id created assets; do
    [ -n "$tag" ] || continue
    assets="${assets:-0}"
    DRAFTS+="$repo"$'\t'"$tag"$'\t'"$id"$'\t'"$created"$'\t'"$assets"$'\n'
    TOTAL=$((TOTAL + 1))
  done <<< "$repo_drafts"
done

if [ "$TOTAL" -eq 0 ]; then
  echo "No pending drafts across ${#TARGETS[@]} repo(s)."
  exit 0
fi

printf '%-42s %-22s %-11s %s\n' "REPO" "DRAFT TAG" "CREATED" "ASSETS"
printf '%-42s %-22s %-11s %s\n' "----" "---------" "-------" "------"
while IFS=$'\t' read -r repo tag _id created assets; do
  printf '%-42s %-22s %-11s %s\n' "$repo" "$tag" "${created%%T*}" "$assets"
done <<< "$DRAFTS"

# Phase 2 - promote. Without --publish this is where the dry-run ends;
# interactively, offer the one-keystroke promotion of the listed drafts.
PROMOTED=0
FAILED=0
SKIPPED=0

if ! $PUBLISH; then
  if [ -t 0 ] && [ -z "${CI:-}" ] && ! $ASSUME_YES; then
    read -r -p "Promote all $TOTAL draft(s) now? [y/N] " reply
    case "$reply" in
      y|Y) PUBLISH=true;;
      *) echo "Dry run only. Re-run with --publish --yes to promote non-interactively.";;
    esac
  else
    echo "Dry run: $TOTAL draft(s) pending. Re-run with --publish to promote (--yes for CI)."
  fi
fi

if $PUBLISH; then
  while IFS=$'\t' read -r repo tag id _created assets; do
    if [ "$assets" -eq 0 ]; then
      echo "SKIP: $repo $tag - no release assets; publishing an empty release would fire a pointless rebuild"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if curl -fsSL -o /dev/null -X PATCH -d '{"draft": false}' \
         -H "Authorization: token $TOKEN" "$API/repos/$repo/releases/$id" 2>/dev/null; then
      echo "PROMOTED: $repo $tag (notify-apt-repo webhook will trigger the apt rebuild)"
      PROMOTED=$((PROMOTED + 1))
    else
      echo "FAILED: could not publish $repo $tag" >&2
      FAILED=$((FAILED + 1))
    fi
  done <<< "$DRAFTS"
  echo "Done: $PROMOTED promoted, $SKIPPED skipped (empty), $FAILED failed."
  [ "$FAILED" -eq 0 ] || exit 1
fi
