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
TOOLS_YAML="$ROOT/tools.yaml"
POOL="$ROOT/pool"
DISTS="$ROOT/dists"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '[build-repo] %s\n' "$*"; }
die() { printf '[build-repo] ERROR: %s\n' "$*" >&2; exit 1; }

for c in curl jq dpkg-deb apt-ftparchive; do
  command -v "$c" >/dev/null || die "$c is required"
done

# ---------------------------------------------------------------------------
# Parse tools.yaml: emit "package<TAB>source-url" lines.
# ---------------------------------------------------------------------------
parse_tools() {
  awk '
    /^[a-zA-Z0-9_.-]+:/ {
      pkg = $0; sub(/:.*/, "", pkg); gsub(/[[:space:]]/, "", pkg)
      src = ""
      next
    }
    /^  source:/ { src = $0; sub(/^  source:[[:space:]]*/, "", src); gsub(/"/, "", src) }
    src != "" { print pkg "\t" src; src = "" }
  ' "$TOOLS_YAML"
}

# ---------------------------------------------------------------------------
# Classify one release asset name. Emits: kind<TAB>suite<TAB>arch<TAB>package
# kind = deb | dsc | debian | orig | skip
# ---------------------------------------------------------------------------
classify_asset() {
  local name="$1"
  local kind="skip" suite="" arch="" pkg=""

  case "$name" in
    *.deb)                 kind="deb"    ;;
    *.dsc)                 kind="dsc"    ;;
    *.debian.tar.xz)       kind="debian" ;;
    *.debian.tar.gz)       kind="debian" ;;
    *.orig.tar.xz|*.orig.tar.gz) kind="orig" ;;
    *) echo "skip<TAB>-<TAB>-<TAB>-"; return 0 ;;
  esac

  # Ubuntu builds are marked with a trailing _ubu suffix; we are Debian-only.
  case "$name" in
    *_ubu.deb|*_ubu_) echo "skip<TAB>-<TAB>-<TAB>-"; return 0 ;;
  esac

  # base = stem without final extension (also strip .tar.xz/.tar.gz)
  local base="${name%.*}"
  case "$base" in
    *.tar.xz|*.tar.gz) base="${base%.*}" ;;
  esac

  # Split on '_':  <pkg>_<version>[.<suite>][_<arch>]
  local pkg_part="${base%%_*}"
  local rest="${base#*_}"
  local ver_part="${rest%%_*}"
  local arch_part=""
  [[ "$rest" == *_* ]] && arch_part="${rest#*_}"

  pkg="$pkg_part"
  [[ "$kind" == "deb" ]] && arch="${arch_part%.deb}"
  [[ -z "$arch" ]] && arch="amd64"

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
  json="$(curl -fsSL -H "Accept: application/vnd.github+json" \
      ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
      "$api" 2>/dev/null)" || {
    log "   skip: no latest release yet (repo may be empty)"
    return 0
  }
  local tag
  tag="$(jq -r '.tag_name' <<<"$json")"
  [[ -n "$tag" && "$tag" != "null" ]] || { log "   skip: no latest release for $pkg"; return 0; }
  log "   tag: $tag"

  # One download URL per asset (already absolute; survives tag renames).
  local tmp_manifest="$TMP/$pkg.assets"
  jq -r '.assets[] | [.name, .browser_download_url] | @tsv' <<<"$json" > "$tmp_manifest"

  while IFS=$'\t' read -r name dlurl; do
    [[ -n "$name" ]] || continue
    read -r kind suite arch apkg <<< "$(classify_asset "$name")"
    [[ "$kind" == "skip" ]] && { log "   skip $name (ubuntu/non-matching)"; continue; }
    [[ "$apkg" == "$pkg" ]] || { log "   skip $name (package mismatch)"; continue; }

    local dest="$POOL/$suite/$pkg"
    mkdir -p "$dest"
    log "   fetch $name -> pool/$suite/$pkg/"
    curl -fsSL -o "$dest/$name" "$dlurl" || log "   WARN: failed to fetch $name"
  done < "$tmp_manifest"
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
    [[ "$has_src" == "yes" ]] && echo "  Sources \"dists/$suite/main/source/Sources\";"
    echo "};"
  } > "$conf"

  ( cd "$ROOT" && apt-ftparchive generate "$conf" )

  # per-arch Packages.gz
  for a in "${arches[@]}"; do
    local pf="$sdir/binary-$a/Packages"
    [[ -f "$pf" ]] && gzip -9 -c "$pf" > "$pf.gz"
  done
  [[ "$has_src" == "yes" ]] && [[ -f "$sdir/source/Sources" ]] && gzip -9 -c "$sdir/source/Sources" > "$sdir/source/Sources.gz"

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

  while IFS=$'\t' read -r pkg url; do
    [[ -n "$pkg" ]] || continue
    fetch_repo "$pkg" "$url"
  done < <(parse_tools)
fi

log "== generating indexes =="
for suite in "$POOL"/*/; do
  suite="${suite%/}"
  suite="${suite##*/}"
  build_suite "$suite"
done

log "done."
log "NOTE: repository is unsigned. Run scripts/sign-repo.sh on a Debian machine with the signing key when ready."
