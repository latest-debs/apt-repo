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

# pkg -> {repo, tag} for every tool with a valid latest release, consumed by
# the Cloudflare Workers redirector (redirector/) to turn a pool/ request
# into the exact GitHub Release asset URL without re-fetching from the
# GitHub API per request. Appended to in fetch_repo(), written out after the
# main loop. TSV instead of building JSON incrementally in bash.
PKG_REPO_MANIFEST="$TMP/pkg-repo-map.tsv"
: > "$PKG_REPO_MANIFEST"

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
# Fetch the latest release JSON for a repo and download matching assets into
# pool/<suite>/<package>/.
# ---------------------------------------------------------------------------
fetch_repo() {
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
  local tag
  tag="$(jq -r '.tag_name' <<<"$json")"
  [[ -n "$tag" && "$tag" != "null" ]] || { log "   skip: no latest release for $pkg"; return 0; }
  log "   tag: $tag"
  printf '%s\t%s\t%s\n' "$pkg" "$repo" "$tag" >> "$PKG_REPO_MANIFEST"

  # One download URL per asset (already absolute; survives tag renames).
  local tmp_manifest="$TMP/$pkg.assets"
  jq -r '.assets[] | [.name, .browser_download_url] | @tsv' <<<"$json" > "$tmp_manifest"

  # The upstream .orig.tar.xz is shared by every suite's source package for
  # this tool, so stash it until we know which suites got a .dsc, then fan
  # it out into each of them.
  local orig_name="" orig_url=""
  local src_suites=()

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

    local dest="$POOL/$suite/$pkg"
    mkdir -p "$dest"
    log "   fetch $name -> pool/$suite/$pkg/"
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest/$name" "$dlurl" \
      || log "   WARN: failed to fetch $name"
    [[ "$kind" == "dsc" ]] && src_suites+=("$suite")
  done < "$tmp_manifest"

  # Fan the shared orig out to every suite that carries a source package.
  if [[ -n "$orig_name" ]]; then
    if [[ ${#src_suites[@]} -eq 0 ]]; then
      log "   WARN: $orig_name has no matching .dsc; skipping"
    else
      local s
      for s in "${src_suites[@]}"; do
        local dest="$POOL/$s/$pkg"
        mkdir -p "$dest"
        log "   fetch $orig_name -> pool/$s/$pkg/ (shared orig)"
        curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest/$orig_name" "$orig_url" \
          || log "   WARN: failed to fetch $orig_name"
      done
    fi
  fi
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
  rm -rf "$POOL" "$DISTS"
  mkdir -p "$POOL" "$DISTS"

  # Each tool's fetch is independent (own pool/<suite>/<pkg>/ subtree, own
  # $tmp_manifest, own local vars in its subshell) so they run concurrently,
  # bounded by BUILD_REPO_PARALLEL. This is a fully I/O-bound loop - ~750
  # assets fetched one at a time was the actual wall-clock cost, not CPU or
  # rate limits. $PKG_REPO_MANIFEST is appended to from multiple processes;
  # safe because each append is one short line, atomic under O_APPEND.
  # Per-tool output goes to its own logfile instead of directly to stdout so
  # concurrent runs don't interleave mid-line; printed back in tools.yaml
  # order once every job has finished, so the log reads the same as a
  # sequential run would.
  BUILD_REPO_PARALLEL="${BUILD_REPO_PARALLEL:-8}"
  fetch_logs=()
  while IFS=$'\t' read -r pkg url; do
    [[ -n "$pkg" ]] || continue
    logfile="$TMP/fetch-$pkg.log"
    fetch_logs+=("$logfile")
    fetch_repo "$pkg" "$url" > "$logfile" 2>&1 &
    while (( $(jobs -rp | wc -l) >= BUILD_REPO_PARALLEL )); do
      wait -n
    done
  done < <(parse_tools "$TOOLS_YAML" | cut -f1,2)
  wait

  for logfile in "${fetch_logs[@]}"; do
    cat "$logfile"
  done
fi

log "== generating indexes =="
for suite in "$POOL"/*/; do
  suite="${suite%/}"
  suite="${suite##*/}"
  build_suite "$suite"
done

log "== writing pkg-repo-map.json =="
jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({(.[0]): {repo: .[1], tag: .[2]}})
  | add // {}
' "$PKG_REPO_MANIFEST" > "$DISTS/pkg-repo-map.json"

log "done."
log "NOTE: repository is unsigned. Run scripts/sign-repo.sh on a Debian machine with the signing key when ready."
