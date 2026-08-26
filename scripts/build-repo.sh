#!/usr/bin/env bash
# build-repo.sh - regenerate the latest-debs aggregate apt repository.
#
# Reads tools.yaml, downloads the latest GitHub release from every tracked
# tool repo, and assembles a Debian repository layout:
#
#   pool/<suite>/<package>/...   binary + source package files
#   dists/<suite>/main/...       Packages/Sources/Release indexes per suite
#
# Signing is intentionally a separate, explicit step (sign-repo.sh) so the
# index generation can run anywhere (including CI) without key material.
#
# Requirements: curl, jq, dpkg-deb, apt-ftparchive (Debian/Ubuntu).
# On a non-Debian host, run via scripts/run-in-debian.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
TOOLS_YAML="$ROOT/tools.yaml"
POOL="$ROOT/pool"
DISTS="$ROOT/dists"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Persisted across CI runs via actions/cache (see rebuild.yml), alongside
# pool/ itself. PREV_MANIFEST is last run's dists/pkg-repo-map.json - the
# record of what tag each tool's on-disk pool/ files actually are, so a
# tool whose latest tag hasn't changed can skip re-downloading entirely
# instead of every run re-fetching the whole catalog regardless of whether
# anything changed. A cold cache (no BUILD_STATE_DIR yet) just means every
# tool looks "changed" and gets fetched fresh - identical to today's
# always-fetch-everything behavior, so this can't regress a cache miss.
BUILD_STATE_DIR="$ROOT/.build-state"
PREV_MANIFEST="$BUILD_STATE_DIR/pkg-repo-map.json"

# apt-ftparchive's own per-(suite,arch) binary cache DBs, also persisted via
# actions/cache under .build-state/. Verified directly (local test, not
# assumed): apt-ftparchive skips re-scanning a .deb entirely when it's
# already in this DB unchanged - 18.7s -> 0.014s on an unchanged pool in
# testing - and correctly re-scans just the files that actually differ
# otherwise. This is what actually dominates a fully-cached run's time now
# that resolve_repo() already skips re-downloading: Packages/Contents
# generation was re-scanning every .deb's contents from scratch every run
# regardless of whether pool/ changed at all.
APT_CACHE_DIR="$BUILD_STATE_DIR/apt-cache"

# pkg -> {repo, tag, published_at} for every tool with a valid latest
# release, consumed by the Cloudflare Workers redirector (redirector/) to
# turn a pool/ request into the exact GitHub Release asset URL without
# re-fetching from the GitHub API per request. Appended to in
# resolve_repo(), written out after the main loop. TSV instead of building
# JSON incrementally in bash.
PKG_REPO_MANIFEST="$TMP/pkg-repo-map.tsv"
: > "$PKG_REPO_MANIFEST"

# Flattened (dest_path<TAB>url) download queue, filled by resolve_repo() for
# every tool before any asset is actually fetched. Draining this as one
# global pool of ~750 independent downloads - rather than parallelizing
# per-tool and leaving each tool's own assets sequential within it - means a
# large tool (e.g. uv, ~34 assets) can't dominate a concurrency batch the
# way it could when parallelism was scoped to "one job per tool".
DOWNLOAD_QUEUE="$TMP/download-queue.tsv"
: > "$DOWNLOAD_QUEUE"

log() { printf '[build-repo] %s\n' "$*"; }
die() { printf '[build-repo] ERROR: %s\n' "$*" >&2; exit 1; }

for c in curl jq dpkg-deb apt-ftparchive; do
  command -v "$c" >/dev/null || die "$c is required"
done

# ---------------------------------------------------------------------------
# Classify one release asset name. Emits: kind<TAB>suite<TAB>arch<TAB>package
# kind = deb | dsc | debian | orig | skip
# suite = "-" for the shared upstream .orig tarball (no suite of its own)
# ---------------------------------------------------------------------------
classify_asset() {
  local name="$1"
  local kind="skip" suite="" arch="" pkg=""

  case "$name" in
    *.deb)                 kind="deb"    ;;
    *.dsc)                 kind="dsc"    ;;
    *.debian.tar.xz|*.debian.tar.gz) kind="debian" ;;
    *.orig.tar.xz|*.orig.tar.gz) kind="orig" ;;
    *) echo "skip<TAB>-<TAB>-<TAB>-"; return 0 ;;
  esac

  # Ubuntu builds are marked with a trailing _ubu suffix; we are Debian-only.
  case "$name" in
    *_ubu.deb|*_ubu_) echo "skip<TAB>-<TAB>-<TAB>-"; return 0 ;;
  esac

  # base = stem with the full multi-part suffix removed, e.g.
  #   uv_0.12.3-1+bookworm_amd64.deb       -> uv_0.12.3-1+bookworm_amd64
  #   uv_0.12.3-1+bookworm.debian.tar.xz   -> uv_0.12.3-1+bookworm
  #   uv_0.12.3.orig.tar.xz                -> uv_0.12.3
  local base="${name%.*}"
  case "$base" in
    *.tar.xz|*.tar.gz|*.tar) base="${base%.*}" ;;
  esac
  case "$base" in
    *.debian|*.orig) base="${base%.*}" ;;
  esac

  # Split on '_':  <pkg>_<version>[.<suite>][_<arch>]
  local pkg_part="${base%%_*}"
  local rest="${base#*_}"
  local ver_part="${rest%%_*}"
  local arch_part=""
  [[ "$rest" == *_* ]] && arch_part="${rest#*_}"

  pkg="$pkg_part"
  [[ "$kind" == "deb" ]] && arch="$arch_part"
  [[ -z "$arch" ]] && arch="amd64"

  # The upstream orig tarball is shared across every suite (no suite token).
  if [[ "$kind" == "orig" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$kind" "-" "$arch" "$pkg"
    return 0
  fi

  # Suite is the trailing dot/plus-separated token of the version, e.g.
  #   "0.12.3-1.bookworm"  -> bookworm
  #   "0.9.3-1+bookworm"   -> bookworm
  local suite_cand="${ver_part##*.}"
  suite="$suite_cand"
  # handle "+" separator style: 0.9.3-1+bookworm has no dot before suite
  if [[ "$ver_part" == *+* ]]; then
    suite="${ver_part##*+}"
  fi
  # suites may contain no dot; if version was plain (no suite), default sid
  [[ "$suite" == "$ver_part" ]] && suite="sid"

  printf '%s\t%s\t%s\t%s\n' "$kind" "$suite" "$arch" "$pkg"
}

# ---------------------------------------------------------------------------
# Resolve one tool's latest release: fetch the release JSON, record its
# pkg/repo/tag, and enqueue a (dest_path, url) download task for every
# matching asset into $DOWNLOAD_QUEUE. Does not download anything itself -
# cheap enough (one API call plus string work) to run sequentially for every
# tool before the actual, much more expensive download pass starts.
# ---------------------------------------------------------------------------
resolve_repo() {
  local pkg="$1" url="$2"
  local repo="${url##https://github.com/}"
  local api="https://api.github.com/repos/$repo/releases/latest"
  log "== $pkg  ($repo) =="

  # Authenticate when a token is available - anonymous calls share a
  # 60/hour rate limit across every workflow on the runner's IP, which
  # this org's build volume (14+ tool repos, each rebuilding on its own
  # schedule) exhausts easily, silently degrading every fetch to "skip:
  # no latest release yet" and shipping an apt repo with zero packages.
  local json
  json="$(curl -fsSL --connect-timeout 10 --max-time 60 \
      -H "Accept: application/vnd.github+json" \
      ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
      "$api" 2>/dev/null)" || {
    log "   skip: no latest release yet (repo may be empty)"
    return 0
  }
  local tag published
  tag="$(jq -r '.tag_name' <<<"$json")"
  [[ -n "$tag" && "$tag" != "null" ]] || { log "   skip: no latest release for $pkg"; return 0; }
  # When GitHub served this release to the public - the timestamp the
  # freshness badges measure age against, not our build time.
  published="$(jq -r '.published_at // ""' <<<"$json")"
  log "   tag: $tag"
  printf '%s\t%s\t%s\t%s\n' "$pkg" "$repo" "$tag" "$published" >> "$PKG_REPO_MANIFEST"

  # Same tag as last run's cached pool/? Then the on-disk files should
  # already be correct - each one gets a cheap existence+nonzero-size check
  # below rather than trusted blindly, so a corrupted or partially-restored
  # cache self-heals by re-fetching just the missing pieces. Different tag
  # (or no previous record, e.g. a cold cache): the old files are for a
  # stale version and must be cleared first, so an old and new version of
  # the same package can never both end up in the index at once.
  local prev_tag="" reuse="no"
  if [[ -f "$PREV_MANIFEST" ]]; then
    prev_tag="$(jq -r --arg p "$pkg" '.[$p].tag // ""' "$PREV_MANIFEST")"
  fi
  if [[ -n "$prev_tag" && "$prev_tag" == "$tag" ]]; then
    reuse="yes"
  else
    local d
    for d in "$POOL"/*/"$pkg"; do
      [[ -d "$d" ]] || continue
      rm -rf "$d"
    done
  fi

  # One download URL per asset (already absolute; survives tag renames).
  local tmp_manifest="$TMP/$pkg.assets"
  jq -r '.assets[] | [.name, .browser_download_url] | @tsv' <<<"$json" > "$tmp_manifest"

  # The upstream .orig.tar.xz is shared by every suite's source package for
  # this tool, so stash it until we know which suites got a .dsc, then
  # enqueue one download task per destination suite.
  local orig_name="" orig_url=""
  local src_suites=()
  local queued=0 cached=0

  while IFS=$'\t' read -r name dlurl; do
    [[ -n "$name" ]] || continue
    read -r kind suite arch apkg <<< "$(classify_asset "$name")"
    [[ "$kind" == "skip" ]] && { log "   skip $name (ubuntu/non-matching)"; continue; }
    [[ "$apkg" == "$pkg" ]] || { log "   skip $name (package mismatch)"; continue; }

    # Remember the shared orig for fan-out after the loop.
    if [[ "$kind" == "orig" ]]; then
      orig_name="$name"
      orig_url="$dlurl"
      log "   note $name (shared orig, fanned out to .dsc suites)"
      continue
    fi

    local dest="$POOL/$suite/$pkg/$name"
    if [[ "$reuse" == "yes" && -s "$dest" ]]; then
      cached=$((cached + 1))
    else
      printf '%s\t%s\n' "$dest" "$dlurl" >> "$DOWNLOAD_QUEUE"
      queued=$((queued + 1))
    fi
    [[ "$kind" == "dsc" ]] && src_suites+=("$suite")
  done < "$tmp_manifest"

  # Fan the shared orig out to every suite that carries a source package.
  if [[ -n "$orig_name" ]]; then
    if [[ ${#src_suites[@]} -eq 0 ]]; then
      log "   WARN: $orig_name has no matching .dsc; skipping"
    else
      local s
      for s in "${src_suites[@]}"; do
        local dest="$POOL/$s/$pkg/$orig_name"
        if [[ "$reuse" == "yes" && -s "$dest" ]]; then
          cached=$((cached + 1))
        else
          printf '%s\t%s\n' "$dest" "$orig_url" >> "$DOWNLOAD_QUEUE"
          queued=$((queued + 1))
        fi
      done
    fi
  fi

  if [[ "$reuse" == "yes" ]]; then
    log "   unchanged ($tag) - $cached cached, $queued to fetch"
  fi
  # Explicit, unconditional: without this, the function's own return status
  # is whatever the branch above evaluated to (false/1 when reuse != yes,
  # the common case) - and since resolve_repo is called as a bare statement
  # in the main loop, that nonzero return would trip set -e and silently
  # kill the whole script after the very first non-reused tool. Caught by
  # testing, not by inspection - verify this class of bug with -x tracing
  # if this function's tail ever changes again.
  return 0
}

# ---------------------------------------------------------------------------
# Drain $DOWNLOAD_QUEUE: fetch every queued (dest_path, url) pair, bounded by
# BUILD_REPO_PARALLEL concurrent downloads at a time, regardless of which
# tool each one came from.
# ---------------------------------------------------------------------------
drain_download_queue() {
  local dest url
  while IFS=$'\t' read -r dest url; do
    [[ -n "$dest" ]] || continue
    (
      mkdir -p "$(dirname "$dest")"
      log "   fetch $(basename "$dest") -> ${dest#"$POOL"/}"
      # curl -o writes directly to $dest, not atomically via a temp file, so
      # a killed or timed-out transfer leaves a truncated file in place -
      # apt-ftparchive then fails the whole suite's index generation on it
      # ("Invalid archive member header") rather than just skipping one
      # missing package. Remove it on any failure so a partial download is
      # indistinguishable from no download.
      curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest" "$url" \
        || { rm -f "$dest"; log "   WARN: failed to fetch $(basename "$dest")"; }
    ) &
    while (( $(jobs -rp | wc -l) >= BUILD_REPO_PARALLEL )); do
      wait -n
    done
  done < "$DOWNLOAD_QUEUE"
  wait
}

# ---------------------------------------------------------------------------
# Generate per-suite apt-ftparchive config and indexes.
# ---------------------------------------------------------------------------
build_suite() {
  local suite="$1"
  local sdir="$DISTS/$suite/main"
  log "   dists/$suite"

  # Architectures actually present in this suite's pool.
  local arches=() a
  for f in "$POOL/$suite"/*/*.deb; do
    [[ -f "$f" ]] || continue
    a="$(dpkg-deb -f "$f" Architecture)"
    [[ " ${arches[*]:-} " == *" $a "* ]] || arches+=("$a")
  done
  [[ ${#arches[@]} -gt 0 ]] || { log "      no binary packages, skipping"; return 0; }

  local has_src="no"
  ls "$POOL/$suite"/*/*.dsc >/dev/null 2>&1 && has_src="yes"

  # Every suite with a source package must also carry the shared orig tarball
  # its .dsc checksums reference; flag it rather than build a broken index.
  if [[ "$has_src" == "yes" ]]; then
    for d in "$POOL/$suite"/*/*.dsc; do
      [[ -f "$d" ]] || continue
      local ref orig_ok
      ref="$(awk '/^Checksums-Sha256:/{f=1;next} f&&/\.orig\.tar/{print $3;exit}' "$d")"
      orig_ok="no"
      [[ -f "$(dirname "$d")/$ref" ]] && orig_ok="yes"
      if [[ "$orig_ok" != "yes" ]]; then
        log "      WARN: $(basename "$d") references $ref but orig missing from $(dirname "$d")"
      fi
    done
  fi

  # Output directories must exist before apt-ftparchive writes into them.
  mkdir -p "$sdir"
  local a
  for a in "${arches[@]}"; do mkdir -p "$sdir/binary-$a"; done
  [[ "$has_src" == "yes" ]] && mkdir -p "$sdir/source"

  # Build the apt-ftparchive config for this suite.
  local conf="$TMP/apt-ftparchive-$suite.conf"
  {
    echo "Dir::ArchiveDir \"$ROOT\";"
    echo "Dir::CacheDir \"$TMP\";"
    echo "TreeDefault {"
    echo "  Sections \"main\";"
    echo "  Architectures \"${arches[*]}\";"
    echo "};"
    echo "Tree \"dists/$suite\" {"
    echo "  Sections \"main\";"
    echo "  Architectures \"${arches[*]}\";"
    echo "  Directory \"pool/$suite\";"
    echo "  Packages \"dists/$suite/main/binary-\$(ARCH)/Packages\";"
    echo "  BinCacheDB \"$APT_CACHE_DIR/$suite-\$(ARCH).db\";"
    echo "};"
  } > "$conf"

  ( cd "$ROOT" && apt-ftparchive generate "$conf" )

  # per-arch Packages.gz
  for a in "${arches[@]}"; do
    local pf="$sdir/binary-$a/Packages"
    [[ -f "$pf" ]] && gzip -9 -c "$pf" > "$pf.gz"
  done

  # Sources index: the generate tree above only emits Packages, so build the
  # source index directly from the pool with the dedicated subcommand. Run
  # from $ROOT so the Directory: field is pool/<suite>/<pkg>, which is where
  # apt resolves source file URIs relative to the archive root.
  if [[ "$has_src" == "yes" ]]; then
    ( cd "$ROOT" && apt-ftparchive sources "pool/$suite" > "$sdir/source/Sources" )
    gzip -9 -c "$sdir/source/Sources" > "$sdir/source/Sources.gz"
  fi

  # Release file (unsigned; sign-repo.sh adds signatures later).
  apt-ftparchive -o APT::FTPArchive::Release::Origin="latest-debs" \
                 -o APT::FTPArchive::Release::Label="latest-debs" \
                 -o APT::FTPArchive::Release::Suite="$suite" \
                 -o APT::FTPArchive::Release::Codename="$suite" \
                 -o APT::FTPArchive::Release::Architectures="${arches[*]}" \
                 -o APT::FTPArchive::Release::Components="main" \
                 release "$DISTS/$suite" > "$DISTS/$suite/Release"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[[ -f "$TOOLS_YAML" ]] || die "missing $TOOLS_YAML"

LOCAL_POOL=""
[[ "${1:-}" == "--local" ]] && LOCAL_POOL="${2:-$POOL}"

if [[ -n "$LOCAL_POOL" ]]; then
  # Test mode: reuse an existing pool/ instead of fetching from GitHub.
  rm -rf "$DISTS"
  mkdir -p "$DISTS"
  cp -a "$LOCAL_POOL"/. "$POOL"
else
  # pool/ is intentionally NOT wiped here - it may have been restored from
  # last run's cache (see rebuild.yml), and resolve_repo() below decides
  # per-tool whether its cached files are still valid (same tag) or stale
  # (different tag, cleared and re-fetched fresh). dists/ is always fully
  # regenerated; that's cheap regardless of how much of pool/ was reused.
  rm -rf "$DISTS"
  mkdir -p "$POOL" "$DISTS" "$BUILD_STATE_DIR"

  BUILD_REPO_PARALLEL="${BUILD_REPO_PARALLEL:-16}"

  # Phase 1: resolve every tool's latest release and enqueue its downloads.
  # Cheap (one API call + string work per tool), so this runs sequentially -
  # keeps log output in tools.yaml order for free, and 41 small API calls
  # in series cost seconds, not minutes.
  log "== resolving releases =="
  while IFS=$'\t' read -r pkg url; do
    [[ -n "$pkg" ]] || continue
    resolve_repo "$pkg" "$url"
  done < <(parse_tools "$TOOLS_YAML" | cut -f1,2)

  # Now that pool/ persists across runs instead of being wiped every time,
  # a tool dropped from tools.yaml would otherwise linger in the index
  # forever - prune any pool/<suite>/<pkg> whose <pkg> isn't tracked.
  log "== pruning removed tools =="
  current_pkgs=" $(parse_tools "$TOOLS_YAML" | cut -f1 | tr '\n' ' ') "
  for d in "$POOL"/*/*/; do
    [[ -d "$d" ]] || continue
    dpkg_name="$(basename "$d")"
    if [[ "$current_pkgs" != *" $dpkg_name "* ]]; then
      log "   removing pool/*/$dpkg_name (no longer tracked)"
      rm -rf "$d"
    fi
  done

  # Phase 2: drain the flattened queue with global concurrency. This is
  # the actual cost (~750 assets), and flattening it - instead of bounding
  # concurrency per-tool with each tool's own assets fetched serially within
  # it - means no single large tool (e.g. uv, ~34 assets) can dominate a
  # concurrency batch. Downloads interleave in the log; each line is a
  # complete, self-contained "fetch X -> Y" statement, so unlike phase 1's
  # multi-line per-tool blocks, that's fine to read as-is.
  log "== downloading $(wc -l < "$DOWNLOAD_QUEUE") assets =="
  drain_download_queue
fi

mkdir -p "$APT_CACHE_DIR"

# Ubuntu suites without a dedicated build are served as an alias of a Debian
# suite whose glibc is older-or-equal, so its binaries also run there: copy
# pool/<src> -> pool/<alias> and rewrite the suite token in filenames (no
# extra docker build). Source of truth for the mapping is suites.json's
# "aliases" map.
while IFS=$'\t' read -r alias_suite alias_src; do
  [[ -n "$alias_suite" ]] || continue
  if [[ -d "$POOL/$alias_src" && ! -e "$POOL/$alias_suite" ]]; then
    log "== alias $alias_suite -> $alias_src (pool copy, no separate build) =="
    cp -a "$POOL/$alias_src" "$POOL/$alias_suite"
    # Rewrite +<alias_src> -> +<alias_suite> in filenames so grep +<alias_suite> matches
    for f in "$POOL/$alias_suite"/*/*; do
      [[ -f "$f" ]] || continue
      nf="${f/+${alias_src}/+${alias_suite}}"
      [[ "$f" != "$nf" ]] && mv "$f" "$nf"
    done
  fi
done < <(jq -r '.aliases | to_entries[] | [.key, .value] | @tsv' "$ROOT/suites.json")

log "== generating indexes =="
for suite in "$POOL"/*/; do
  suite="${suite%/}"
  suite="${suite##*/}"
  build_suite "$suite"
done

log "== writing pkg-repo-map.json =="
jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({(.[0]): {repo: .[1], tag: .[2], published_at: .[3]}})
  | add // {}
' "$PKG_REPO_MANIFEST" > "$DISTS/pkg-repo-map.json"

# freshness.json - one shields.io endpoint-badge object per package, plus a
# "_meta" org-level badge, served from gh-pages and rendered via
# https://img.shields.io/endpoint?url=<site>/dists/freshness.json&query=$.<pkg>.
# Age = now minus the release's published_at (when GitHub served the .deb
# release), so the badge shows how current the apt version is regardless of
# when this rebuild ran. Color escalates with age: brightgreen < 7d,
# green < 31d, yellowgreen < 92d, yellow beyond.
log "== writing freshness.json =="
NOW_EPOCH="$(date +%s)"
jq -R -s -c --argjson now "$NOW_EPOCH" '
  def hum(s):
    if   s < 5400    then "\((s / 60   | floor))m"
    elif s < 172800  then "\((s / 3600 | floor))h"
    elif s < 5270400 then "\((s / 86400 | floor))d"
    else                  "\((s / 2592000 | floor))mo"
    end;
  def col(s):
    if   s < 604800  then "brightgreen"
    elif s < 2678400 then "green"
    elif s < 7948800 then "yellowgreen"
    else "yellow"
    end;
  split("\n") | map(select(length > 0) | split("\t"))
  | map(. as $r
      | (try ($r[3] | fromdateiso8601) catch null) as $pub
      | if $pub == null then
          # No usable timestamp: fall back to a neutral badge rather than
          # dropping the package from the catalog view.
          { key: $r[0], age: null,
            badge: { schemaVersion: 1, label: "apt", message: $r[2], color: "lightgrey" } }
        else
          ($now - $pub) as $s
          | { key: $r[0], age: $s,
              badge:
                { schemaVersion: 1, label: "apt",
                  message: (($r[2]
                             | ltrimstr($r[0] + "-")
                             | ltrimstr("v")
                             | sub("\\+[0-9]+$"; "")) + " · " + hum($s)),
                  color: col($s) } }
        end)
  | . as $rows
  | ($rows | map({(.key): .badge}) | add // {}) as $badges
  | ($rows | map(.age) | map(select(. != null)) | sort) as $ages
  | ($ages | length) as $n
  | $badges + {
      _meta:
        (if $n == 0 then
           { schemaVersion: 1, label: "latest-debs", message: "no releases yet", color: "lightgrey" }
         else
           { schemaVersion: 1, label: "latest-debs",
             message: "\($n) tools · median \(hum($ages[($n / 2 | floor)]))",
             color: col($ages[($n / 2 | floor)]) }
         end) }
' "$PKG_REPO_MANIFEST" > "$DISTS/freshness.json"

# Becomes next run's $PREV_MANIFEST once .build-state/ round-trips through
# the cache save/restore in rebuild.yml - this is what lets resolve_repo()
# recognize "unchanged since last time" on the run after this one.
if [[ -z "$LOCAL_POOL" ]]; then
  mkdir -p "$BUILD_STATE_DIR"
  cp "$DISTS/pkg-repo-map.json" "$PREV_MANIFEST"
fi

log "done."
log "NOTE: repository is unsigned. Run scripts/sign-repo.sh on a Debian machine with the signing key when ready."
