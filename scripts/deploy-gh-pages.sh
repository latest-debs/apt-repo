#!/usr/bin/env bash
# deploy-gh-pages.sh - publish the apt repo (pool/, dists/, key, index) to
# the gh-pages branch.
#
# Failure history this script has to survive:
#   - peaceiris era: pushes died mid-RPC with "RPC failed; HTTP 500 curl 22"
#     once the branch payload grew past ~2GB.
#   - v1 of this script: forced HTTP/1.1 globally (throttled the 2GB baseline
#     clone into a 25-minute crawl), and - much worse - ran under an
#     `until deploy_attempt` loop, where bash suppresses set -e: a failed
#     `git push` fell through to a success log and an implicit `return 0`,
#     reporting a GREEN deploy while the push had 500'd. The site silently
#     froze for 17 hours that way.
#
# v3 rules (all learned from the failures above):
#   1. Every fallible command gets an explicit `|| return 1`. Never rely on
#      set -e inside a function used as a loop condition.
#   2. HTTP/1.1 on the push ONLY (the RPC-500 workaround); clones keep
#      HTTP/2 multiplexing.
#   3. `push --no-thin`: thin packs are a known trigger for the server-side
#      500 on large pushes.
#   4. Chunked pushes: dists/+key first, then one pool/<suite> per commit -
#      each pushed pack stays small instead of one multi-GB push.
#   5. The whole clone..push cycle retries 3x with backoff, and a push that
#      the server applied despite reporting an error is detected via the
#      remote SHA (idempotent re-check), not trusted from the exit code.
#
# Env: GITHUB_TOKEN (contents:write), GITHUB_REPOSITORY.
# Run from the workspace holding the built pool/ + dists/.

set -uo pipefail
# NOTE: deliberately NOT set -e: this script's functions are invoked from an
# until-loop condition where set -e is inert anyway; correctness comes from
# explicit rc handling below.

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
EXCLUDES=(
  --exclude .git
  --exclude .github
  --exclude .claude
  --exclude .wrangler
  --exclude .build-state
  --exclude .gitignore
)

remote_sha() {
  git ls-remote "$URL" refs/heads/gh-pages | cut -f1
}

# Push with honest failure reporting. Never trust the exit code alone: the
# server has been observed applying a push while answering HTTP 500, and
# also answering 200 while silently not updating - so verify via ls-remote.
push_ref() {
  local before="$1" label="$2" after
  log "push: $label"
  if ! git -c http.version=HTTP/1.1 push --no-thin "$URL" gh-pages; then
    log "push: $label exited nonzero - checking whether it landed anyway"
  fi
  after="$(remote_sha)"
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    log "push: $label landed (remote now $after)"
    return 0
  fi
  log "push: $label did NOT land (remote still ${before:-none})"
  return 1
}

deploy_attempt() {
  # Start from a stable cwd: a previous attempt's `cd` into $WORK/gh-pages
  # leaves this shell inside a directory the retry's `rm -rf` deletes
  # (observed: rsync then fails with "getcwd(): No such file or directory").
  cd "$REPO_ROOT" || return 1
  local t0=$SECONDS
  rm -rf "$WORK/gh-pages"
  # Fresh shallow clone each attempt so a poisoned previous attempt can't
  # leak into this one.
  if ! git clone --depth 1 --branch gh-pages "$URL" "$WORK/gh-pages" 2>/dev/null; then
    log "gh-pages branch missing or unreachable; creating an orphan checkout"
    git init -q -b gh-pages "$WORK/gh-pages" || return 1
  fi
  log "clone done in $((SECONDS - t0))s"

  rsync -a --delete "${EXCLUDES[@]}" "$REPO_ROOT/" "$WORK/gh-pages/" || return 1
  cd "$WORK/gh-pages" || return 1

  # Small pushes beat one giant push: dists/+index files first, then one
  # suite's pool directory per commit, then stragglers.
  local groups=() g
  groups+=(".")
  for g in "$REPO_ROOT"/pool/*/; do
    groups+=("pool/$(basename "$g")")
  done

  local t1=$SECONDS pushed=0
  for g in "${groups[@]}"; do
    local before
    before="$(remote_sha)"
    if [ "$g" = "." ]; then
      # Everything EXCEPT pool (cwd is the repo root of the checkout).
      git add -A -- . ':(exclude)pool' || return 1
    else
      git add -A -- "$g" || return 1
    fi
    if git diff --cached --quiet; then
      log "no changes in $g; skipping"
      continue
    fi
    git commit -q -m "Rebuild apt repository ($(date -u '+%Y-%m-%dT%H:%M:%SZ')): $g" || return 1
    push_ref "$before" "$g" || return 1
    pushed=$((pushed + 1))
  done
  log "sync+commits+pushes done in $((SECONDS - t1))s ($pushed chunk(s) pushed)"
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
