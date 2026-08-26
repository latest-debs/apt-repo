#!/usr/bin/env bash
# deploy-gh-pages.sh - publish the apt repo (pool/, dists/, key, index) to
# the gh-pages branch, replacing the peaceiris action.
#
# Why not the action: two scheduled rebuilds in a row died mid-push with
# "RPC failed; HTTP 500 curl 22" - the payload is 1.5-2GB and GitHub's
# HTTP/2 endpoint chokes on large pushes. Fixes, in order:
#   1. http.version = HTTP/1.1 (the canonical workaround for RPC 500s on
#      big pushes)
#   2. retry the whole fetch+commit+push cycle up to 3 times with backoff
#   3. incremental history: commit on TOP of existing gh-pages (force_orphan
#      false already fixed this) so unchanged pool/ blobs dedupe server-side
#
# Env: GITHUB_TOKEN (contents:write), GITHUB_REPOSITORY. Run from the repo
# working directory that holds the built pool/ + dists/.

set -euo pipefail

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"

REPO_ROOT="$(pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Large-push reliability: HTTP/1.1 for every git transfer in this deploy.
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Paths that live in the build workspace but must never be published.
EXCLUDES=(
  --exclude .git
  --exclude .github
  --exclude .claude
  --exclude .wrangler
  --exclude .build-state
  --exclude .gitignore
)

deploy_attempt() {
  local url="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  rm -rf "$WORK/gh-pages"
  # Fresh shallow clone of gh-pages each attempt so a partially-pushed
  # previous attempt can't poison this one's commit.
  if ! git clone --depth 1 --branch gh-pages "$url" "$WORK/gh-pages" 2>/dev/null; then
    log "gh-pages branch missing or unreachable; creating an orphan checkout"
    git init -q -b gh-pages "$WORK/gh-pages"
  fi
  rsync -a --delete "${EXCLUDES[@]}" "$REPO_ROOT/" "$WORK/gh-pages/"
  cd "$WORK/gh-pages"
  git add -A
  if git diff --cached --quiet; then
    log "nothing changed; skipping push"
    return 0
  fi
  git commit -q -m "Rebuild apt repository ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
  git push origin gh-pages
}

attempt=1
max=3
until deploy_attempt; do
  rc=$?
  # deploy_attempt returning nonzero means clone/rsync/commit/push failed.
  if [ "$attempt" -ge "$max" ]; then
    die "deploy failed after $max attempts (last rc=$rc)"
  fi
  backoff=$(( attempt * 30 ))
  log "deploy attempt $attempt/$max failed (rc=$rc); retrying in ${backoff}s"
  sleep "$backoff"
  attempt=$(( attempt + 1 ))
done
log "deploy complete"
