#!/usr/bin/env bash
# vet-source.sh - vet a SOURCE-ONLY upstream (e.g. quickshell on Forgejo):
# download the tag archive, pin its SHA-256, and write release-metadata.json
# in the same shape vet-release.sh produces for binary assets, so
# generate-provenance.sh / generate-sbom.sh and the builder consume it the
# same way.
#
# The binary vet (vet-release.sh) requires a release *asset* to verify; source
# upstreams have none, so this is the parallel entry point. `asset` is left
# empty and `sha256` is the source tarball digest.
#
# Usage:
#   vet-source.sh --upstream-url <forgejo-repo-url> --tag <tag> \
#                 --name <pkg> --github-repo <owner/repo> --license <spdx> \
#                 --out <dir>
#
# Requirements: curl, jq, sha256sum.

set -euo pipefail

upstream_url="" tag="" name="" github_repo="" license="unknown" out="."
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream-url) upstream_url="$2"; shift 2;;
    --tag) tag="$2"; shift 2;;
    --name) name="$2"; shift 2;;
    --github-repo) github_repo="$2"; shift 2;;
    --license) license="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$upstream_url" ] && [ -n "$tag" ] && [ -n "$name" ] || {
  echo "ERROR: --upstream-url, --tag and --name are required" >&2; exit 2; }

# Normalize to the Forgejo base (strip any trailing /, .git, or path suffix)
base="${upstream_url%.git}"; base="${base%/}"
archive="${base}/archive/${tag}.tar.gz"
# https://git.outfoxxed.me/quickshell/quickshell -> quickshell/quickshell
forgejo_repo="$(printf '%s' "$base" | sed -E 's|https?://[^/]+/||')"

mkdir -p "$out"
tmp_archive="$(mktemp)"
trap 'rm -f "$tmp_archive"' EXIT
echo "→ Fetching source archive: $archive"
curl -fsSL --connect-timeout 10 --max-time 120 "$archive" -o "$tmp_archive"
sha="$(sha256sum "$tmp_archive" | awk '{print $1}')"
echo "→ sha256($name $tag) = $sha"

jq -n \
  --arg upstream_repo "${github_repo:-$forgejo_repo}" \
  --arg forgejo_repo "$forgejo_repo" \
  --arg tag "$tag" \
  --arg license "$license" \
  --arg asset "" \
  --arg sha256 "$sha" \
  --arg source_tarball "$archive" \
  --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{upstream_repo:$upstream_repo, forgejo_repo:$forgejo_repo, tag:$tag,
    published_at:$published_at, license:$license, asset:$asset,
    sha256:$sha256, source_tarball:$source_tarball, checksum_verified:false,
    mode:"source"}' \
  > "$out/release-metadata.json"

echo "→ wrote $out/release-metadata.json"
