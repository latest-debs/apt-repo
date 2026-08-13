#!/usr/bin/env bash
# vet-release.sh - verify an upstream release asset against its published
# checksum and capture release metadata for provenance.
#
# Called at VET time (the package-request vet job via add-package.sh scaffold):
#   * resolves the upstream release (latest, or an explicit tag),
#   * downloads the selected Linux archive asset AND its checksum file,
#   * verifies the asset's SHA-256 against the published checksum file (when
#     one exists), and
#   * writes <out>/release-metadata.json capturing the release identity
#     (tag, published_at, asset, size) plus the computed SHA-256.
#
# The recorded sha256 is a PROVENANCE PIN: the debian-multiarch-builder
# verifies the exact bytes it downloads against this digest when building the
# vetted version, so an upstream release that is altered after vetting is
# detected rather than silently packaged. The pin lives in the scaffolded
# repo (.github/release-metadata.json) under review by an org admin.
#
# Requirements: curl, jq, sha256sum.

set -euo pipefail

API="https://api.github.com"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

repo="" pkg="" asset="" version="" out="$(pwd)"
VET_SOURCE="${VET_SOURCE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   repo="$2"; shift 2;;
    --name)   pkg="$2"; shift 2;;
    --asset)  asset="$2"; shift 2;;
    --version) version="$2"; shift 2;;
    --out)    out="$2"; shift 2;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$repo" ] || { echo "ERROR: --repo (upstream owner/repo) is required" >&2; exit 2; }
[ -n "$pkg" ] || pkg="${repo##*/}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Resolve the release JSON (latest, or an explicit tag).
# ---------------------------------------------------------------------------
if [ -n "$version" ]; then
  release="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
    "$API/repos/$repo/releases/tags/$version")"
else
  release="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
    "$API/repos/$repo/releases/latest")"
fi
tag="$(jq -r '.tag_name' <<<"$release")"
[ -n "$tag" ] && [ "$tag" != "null" ] || { echo "ERROR: no release found for $repo" >&2; exit 1; }
published_at="$(jq -r '.published_at // ""' <<<"$release")"

# Upstream's current SPDX license (also captured at scaffold time into
# package.yaml; license-check.sh rechecks it on every build).
license="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
  "$API/repos/$repo" 2>/dev/null | jq -r '.license.spdx_id // ""' 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Select the asset: an explicit override, or the first Linux archive.
# ---------------------------------------------------------------------------
if [ -z "$asset" ]; then
  asset="$(jq -r '.assets[]?.name' <<<"$release" \
    | grep -iE 'linux' \
    | grep -iE '\.(tar\.gz|tgz|zip)$' \
    | grep -viE 'sha256|checksum|\.asc$|source|sums' \
    | head -n1 || true)"
fi
[ -n "$asset" ] || { echo "ERROR: could not determine a release asset to vet for $repo" >&2; exit 1; }

asset_json="$(jq -r --arg a "$asset" '.assets[]? | select(.name == $a)' <<<"$release")"
dlurl="$(jq -r '.browser_download_url // ""' <<<"$asset_json")"
[ -n "$dlurl" ] || { echo "ERROR: asset '$asset' has no browser_download_url" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Find and parse a checksum asset for the selected file. Mirrors the parser
# in the builder (src/lib/validation.sh): hash-first lines, the "filename
# first" multi-algorithm layout (GoReleaser, via a <file>_hashes_order
# sibling), and single-line checksum files.
# ---------------------------------------------------------------------------
resolve_expected_sha256() {
  local file="$1" cs_file="$2" asset="$3" repo="$4" tag="$5"
  local line
  line="$(grep -F "$asset" "$file" | head -n1 || true)"
  if [ -z "$line" ]; then
    if [ "$(wc -l < "$file")" -eq 1 ]; then
      local sha; sha="$(awk '{print $1}' "$file")"
      if [[ "$sha" =~ ^[a-f0-9]{64}$ ]]; then echo "$sha"; fi
    fi
    return 0
  fi
  local first; first="$(awk '{print $1}' <<<"$line")"
  local sha=""
  if [ "$first" = "$asset" ]; then
    # Filename-first layout: one column per algorithm, SHA-256's column is
    # given by the N-th line of the sibling "_hashes_order" file.
    local order="${file}_hashes_order"
    if curl -fsSL -o "$order" \
        "https://github.com/$repo/releases/download/$tag/${cs_file}_hashes_order" 2>/dev/null; then
      local n
      n="$(grep -n -m1 -ix 'SHA-256' "$order" | cut -d: -f1 || true)"
      [ -n "$n" ] && sha="$(awk -v f="$((n + 1))" '{print $f}' <<<"$line")"
      rm -f "$order"
    fi
  else
    sha="$first"
  fi
  if [[ "$sha" =~ ^[a-f0-9]{64}$ ]]; then echo "$sha"; fi
}

names="$(jq -r '.assets[]?.name' <<<"$release")"
cs_file=""
for cand in "$asset.sha256" "$asset.sha256sum" "SHA256SUMS" "checksums.txt"; do
  if grep -Fxq "$cand" <<<"$names"; then cs_file="$cand"; break; fi
done
if [ -z "$cs_file" ]; then
  cs_file="$(grep -iE 'sha256|checksum|sums' <<<"$names" | grep -viE '\.sig$' | head -n1 || true)"
fi

expected=""
cs_source=""
if [ -n "$cs_file" ]; then
  cs_url="https://github.com/$repo/releases/download/$tag/$cs_file"
  if curl -fsSL -o "$TMP/checksums" "$cs_url" 2>/dev/null; then
    cs_source="$cs_file"
    expected="$(resolve_expected_sha256 "$TMP/checksums" "$cs_file" "$asset" "$repo" "$tag")"
  fi
fi

# ---------------------------------------------------------------------------
# Download the asset and compute its digest.
# ---------------------------------------------------------------------------
curl -fsSL -o "$TMP/asset" "$dlurl"
actual="$(sha256sum "$TMP/asset" | awk '{print $1}')"
size_actual="$(stat -c%s "$TMP/asset" 2>/dev/null || echo 0)"

verified=false
if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then verified=true; fi

# ---------------------------------------------------------------------------
# Emit the provenance pin + report.
# ---------------------------------------------------------------------------
version_out="${version:-$tag}"
jq -n \
  --arg package "$pkg" \
  --arg upstream_repo "$repo" \
  --arg version "$version_out" \
  --arg tag "$tag" \
  --arg published_at "$published_at" \
  --arg license "$license" \
  --arg asset "$asset" \
  --argjson asset_size "$size_actual" \
  --arg sha256 "$actual" \
  --arg expected_sha256 "${expected:-}" \
  --arg checksum_source "${cs_source:-}" \
  --argjson checksum_verified "$verified" \
  --arg vetted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg vetted_by "${VET_SOURCE:-}" \
  '{package:$package, upstream_repo:$upstream_repo, version:$version, tag:$tag,
    published_at:$published_at, license:$license, asset:$asset, asset_size:$asset_size,
    sha256:$sha256, expected_sha256:$expected_sha256,
    checksum_source:$checksum_source, checksum_verified:$checksum_verified,
    vetted_at:$vetted_at, vetted_by:$vetted_by}' \
  > "$out/release-metadata.json"

echo "→ vetted $repo@$tag ($pkg)"
echo "   asset:    $asset ($((size_actual / 1024 / 1024)) MB)"
echo "   license:  ${license:-unknown}"
echo "   sha256:   $actual"
if [ "$verified" = "true" ]; then
  echo "   checksum: verified against $cs_source"
elif [ -n "$expected" ]; then
  echo "   ⚠ CHECKSUM MISMATCH: asset digest differs from $cs_source"
  echo "     expected: $expected"
  echo "     computed: $actual"
else
  echo "   ⚠ no upstream checksum file found; digest pinned without cross-check"
fi
echo "   pin:      $out/release-metadata.json"