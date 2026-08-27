#!/usr/bin/env bash
# deploy-gh-pages.sh - publish the apt repo's indexes, site and signing key
# to the gh-pages branch as a single orphan commit.
#
# Failure history this script has to survive:
#   - peaceiris era: pushes died mid-RPC with "RPC failed; HTTP 500 curl 22"
#     once the branch payload grew past ~2GB.
#   - v1: forced HTTP/1.1 globally (throttled the 2GB baseline clone into a
#     25-minute crawl), and ran under an `until deploy_attempt` loop where
#     bash suppresses set -e: a failed push reported GREEN while the push
#     had 500'd. The site silently froze for 17 hours that way.
#   - v3: chunked pool/<suite> pushes with per-package sub-chunking - and
#     deploys still failed, because the problem was never the push: it was
#     the branch CONTENT. gh-pages carried the full 17.46GB pool/ against
#     GitHub Pages' 1GB published-site limit; every build sat in
#     deployment_in_progress for ~20 minutes and died. The site froze on
#     2026-08-26 20:22 UTC and stayed frozen for a day while the rebuild
#     pipeline stayed green above it.
#
# v4: pool/ is no longer published at all. apt clients fetch pool files
# through the redirector (Cloudflare Worker), which 302s /pool/* to each
# tool's own GitHub Release assets using dists/pkg-repo-map.json; gh-pages
# carries only dists/ + site + signing key (~11.5MB). Each deploy is ONE
# fresh orphan commit force-pushed over the branch - history cannot
# accumulate, so the size bug can never return, and the clone / chunking /
# dedupe machinery that existed for the 17GB world is gone.
#
# Env: GITHUB_TOKEN (contents:write), GITHUB_REPOSITORY.
# Run from the workspace holding the built dists/ (+ pool/, ignored).

set -uo pipefail
# NOTE: deliberately NOT set -e: deploy_attempt runs as an until-loop
# condition where set -e is inert anyway; correctness comes from explicit
# rc handling below.

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"

REPO_ROOT="$(pwd)"
WORK="$(mktemp -d)"
trap 'cd "$REPO_ROOT"; rm -rf "$WORK"' EXIT
URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

git config --global http.postBuffer 1048576000
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Paths that live in the build workspace but must never be published.
# pool/ above all: 17.45GB against Pages' 1GB limit - it is served via the
# redirector from each tool's GitHub Release assets instead.
EXCLUDES=(
  --exclude .git
  --exclude .github
  --exclude .claude
  --exclude .wrangler
  --exclude .build-state
  --exclude .gitignore
  --exclude pool
)

remote_sha() {
  git ls-remote "$URL" refs/heads/gh-pages | cut -f1
}

# Push with honest failure reporting. Never trust the exit code alone: the
# server has been observed applying a push while answering HTTP 500, and
# also answering 200 while silently not updating - so verify via ls-remote
# against the commit we actually built.
push_orphan() {
  local before="$1" after
  log "push: force-pushing orphan commit (remote was ${before:-none})"
  if ! git -c http.version=HTTP/1.1 push --no-thin --force "$URL" gh-pages; then
    log "push: exited nonzero - checking whether it landed anyway"
  fi
  after="$(remote_sha)"
  if [ -n "$after" ] && [ "$after" = "$(git rev-parse HEAD)" ]; then
    log "push: landed (remote now ${after:0:8})"
    return 0
  fi
  log "push: did NOT land (remote ${after:-none})"
  return 1
}

deploy_attempt() {
  cd "$REPO_ROOT" || return 1
  local t0=$SECONDS
  rm -rf "$WORK/gh-pages"
  # Fresh orphan repo each attempt: no clone, no inherited history, nothing
  # a poisoned previous attempt could leak in.
  git init -q -b gh-pages "$WORK/gh-pages" || return 1
  rsync -a "${EXCLUDES[@]}" "$REPO_ROOT/" "$WORK/gh-pages/" || return 1
  cd "$WORK/gh-pages" || return 1
  git add -A || return 1
  git commit -q -m "Rebuild apt repository ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))" || return 1
  log "staged $(git ls-files | wc -l) file(s) in $((SECONDS - t0))s"
  push_orphan "$(remote_sha)" || return 1
  log "deploy complete in $((SECONDS - t0))s"
  return 0
}

attempt=1
max=3
until deploy_attempt; do
  if [ "$attempt" -ge "$max" ]; then
    die "deploy failed after $max attempts - gh-pages may be stale; DO NOT trust this run"
  fi
  backoff=$(( attempt * 30 ))
  log "deploy attempt $attempt/$max failed; retrying in ${backoff}s"
  sleep "$backoff"
  attempt=$(( attempt + 1 ))
done
log "deploy complete"
