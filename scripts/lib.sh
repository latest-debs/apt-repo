# lib.sh - shared constants and helpers for apt-repo automation scripts.
#
# Source with:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib.sh"
#
# Not executable on its own; has no shebang and sets no -e/-u (the sourcing
# script's set -euo pipefail already applies).
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # every constant here is used by the scripts that source this file, not within it

# GitHub org every *-debian package repo (and this apt-repo) lives under.
ORG="latest-debs"

# GitHub REST API base URL.
API="https://api.github.com"

# Identity used for automation commits (scaffold, register-tools, rollout),
# matching GitHub Actions' own default bot identity.
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

# parse_tools <tools.yaml> - emit one "pkg<TAB>source<TAB>debian_name<TAB>
# homepage" line per package. debian_name defaults to pkg when tools.yaml
# doesn't override it; source/homepage are raw (empty when absent).
#
# The single parser for tools.yaml's flat "name:\n  field: value\n" format -
# every script that needs a subset of these fields should call this and
# select columns with cut (e.g. `parse_tools "$TOOLS_YAML" | cut -f1,2`)
# rather than re-implementing the awk state machine.
parse_tools() {
  awk '
    /^[a-zA-Z0-9_.-]+:/ {
      if (pkg != "") print pkg "\t" src "\t" (dname != "" ? dname : pkg) "\t" homepage
      pkg = $0; sub(/:.*/, "", pkg); gsub(/[[:space:]]/, "", pkg)
      src = ""; dname = ""; homepage = ""
      next
    }
    /^  source:/      { src = $0; sub(/^  source:[[:space:]]*/, "", src); gsub(/"/, "", src) }
    /^  debian_name:/ { dname = $0; sub(/^  debian_name:[[:space:]]*/, "", dname); gsub(/"/, "", dname) }
    /^  homepage:/    { homepage = $0; sub(/^  homepage:[[:space:]]*/, "", homepage) }
    END { if (pkg != "") print pkg "\t" src "\t" (dname != "" ? dname : pkg) "\t" homepage }
  ' "$1"
}

# ---------------------------------------------------------------------------
# gh_get <url> <out_file> - GitHub REST GET with an on-disk ETag cache.
#
# The single API entry point for build-repo.sh: both resolve_repo() (own-repo
# latest release) and upstream_time() (upstream release by tag) route through
# it, so the cache covers every REST call the rebuild makes. Caching is opt-in
# via $ETAG_DIR - with it unset this is a plain authenticated GET, so any other
# script here can adopt it without inheriting a cache it has nowhere to persist.
#
# A 304 response does not count against GitHub's primary rate limit. On 304
# the previously cached body is restored into <out_file> and "200" is echoed,
# so callers keep their existing `if [ "$code" = "200" ]` branch unchanged and
# cannot tell a revalidation from a fresh fetch. A cold or evicted cache just
# behaves exactly like the uncached fetch did, so this can never regress a run.
#
# Note this buys headroom against the *primary* (request-count-per-hour) limit
# only - a 304 is still a request, so it does nothing for the secondary/abuse
# limiter that the stagger in upstream_time() exists to avoid. Cutting the
# actual request count needs GraphQL batching; see the note there.
# ---------------------------------------------------------------------------
gh_get() {
  local url="$1" out="$2"
  local key body etag hdr code
  key="$(printf '%s' "$url" | sha256sum | cut -c1-32)"
  body="${ETAG_DIR:-}/$key.body"
  etag="${ETAG_DIR:-}/$key.etag"
  hdr="$(mktemp)"

  local -a hdrs=(-H "Accept: application/vnd.github+json")
  # GH_TOKEN first, matching the gh CLI's own precedence: promote-drafts.sh
  # needs a fine-grained org token with Contents:write on the *-debian repos,
  # which the repo-scoped GITHUB_TOKEN is not. Reading only GITHUB_TOKEN here
  # would silently downgrade its auth.
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$token" ] && hdrs+=(-H "Authorization: token $token")
  # Only send If-None-Match when BOTH halves survived; a body evicted out from
  # under its etag would otherwise turn every 304 into an empty result.
  if [ -n "${ETAG_DIR:-}" ] && [ -s "$etag" ] && [ -s "$body" ]; then
    hdrs+=(-H "If-None-Match: $(cat "$etag")")
  fi

  # Retry lives here, once, because every caller wanted it and each wrote its
  # own copy. 403/429/5xx is GitHub's rate limiter (primary or secondary) and
  # is worth waiting out; 200/404/anything else is a real answer, returned
  # immediately. The final code is returned either way, so callers keep
  # branching on it exactly as they did around their own loops.
  local attempt
  for attempt in 1 2 3; do
    code="$(curl -fsSL --connect-timeout 10 --max-time 60 -o "$out" -D "$hdr" -w '%{http_code}' \
        "${hdrs[@]}" "$url" 2>/dev/null || true)"
    case "$code" in
      403|429|5??) [ "$attempt" -lt 3 ] && sleep $((attempt * 5)) ;;
      *) break ;;
    esac
  done

  if [ "$code" = "304" ]; then
    cp "$body" "$out"
    code=200
  elif [ "$code" = "200" ] && [ -n "${ETAG_DIR:-}" ]; then
    mkdir -p "$ETAG_DIR"
    cp "$out" "$body"
    # Header names are case-insensitive and GitHub sends a weak tag
    # (`ETag: W/"..."`), which must be replayed verbatim.
    awk 'tolower($1) == "etag:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' \
      "$hdr" > "$etag"
  fi
  rm -f "$hdr"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# api_json <url> - GET a GitHub API URL and print the response body.
#
# Returns 0 and prints the body on 200; returns 1 and prints nothing on
# anything else (including a persistent rate limit, which gh_get has already
# backed off and retried). The convenience shape four scripts each rolled by
# hand; gh_get remains the one for callers that need the status code.
api_json() {
  local out rc
  out="$(mktemp)"
  if [ "$(gh_get "$1" "$out")" = "200" ]; then
    cat "$out"; rc=0
  else
    rc=1
  fi
  rm -f "$out"
  return "$rc"
}
