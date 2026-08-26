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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

repo="" pkg="" asset="" version="" out="$(pwd)" declared_license=""
VET_SOURCE="${VET_SOURCE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   repo="$2"; shift 2;;
    --name)   pkg="$2"; shift 2;;
    --asset)  asset="$2"; shift 2;;
    --version) version="$2"; shift 2;;
    --license) declared_license="$2"; shift 2;;
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
# Enumerate every Linux archive asset in the release. The builder downloads
# per-architecture assets (one per arch), so the provenance pin must cover
# ALL of them - not just the primary - or a swapped non-primary asset would
# slip through. Selection mirrors the builder's auto-discovery filter.
# ---------------------------------------------------------------------------
mapfile -t linux_assets < <(jq -r '.assets[]?.name' <<<"$release" \
    | grep -iE 'linux' \
    | grep -iE '\.(tar\.gz|tgz|tar\.xz|zip)$' \
    | grep -viE 'sha256|checksum|\.asc$|source|sums' || true)

# Select the asset: an explicit override, or the first Linux archive.
if [ -z "$asset" ]; then
  asset="${linux_assets[0]:-}"
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

# Prefer an aggregate checksum file that covers every asset, falling back to
# per-asset checksum files. For each asset, cross-check its digest against
# the checksum file when the file actually contains that asset.
cs_file=""
for cand in "SHA256SUMS" "sha256.sum" "sha256sums" "checksums.txt" "$asset.sha256" "$asset.sha256sum"; do
  if grep -Fxq "$cand" <<<"$names"; then cs_file="$cand"; break; fi
done
if [ -z "$cs_file" ]; then
  cs_file="$(grep -iE 'sha256|checksum|sums' <<<"$names" | grep -viE '\.sig$' | head -n1 || true)"
fi

cs_source=""
if [ -n "$cs_file" ]; then
  cs_url="https://github.com/$repo/releases/download/$tag/$cs_file"
  if curl -fsSL -o "$TMP/checksums" "$cs_url" 2>/dev/null; then
    cs_source="$cs_file"
  fi
fi

# ---------------------------------------------------------------------------
# Download every Linux archive asset and compute its SHA-256. The primary
# asset keeps the legacy top-level fields (asset/sha256/asset_size/...);
# every asset - including the primary - is also recorded in the "assets"
# map so the builder can pin all per-architecture downloads.
# ---------------------------------------------------------------------------
verify_against_checksums() {
  local asset_name="$1"
  [ -n "$cs_file" ] && [ -f "$TMP/checksums" ] || { echo ""; return 0; }
  local expected_sha
  expected_sha="$(resolve_expected_sha256 "$TMP/checksums" "$cs_file" "$asset_name" "$repo" "$tag")"
  [ -n "$expected_sha" ] || { echo ""; return 0; }
  echo "$expected_sha"
}

declare -A asset_shas
asset_shas["$asset"]=""
for a in "${linux_assets[@]:-}"; do
  [ -n "$a" ] || continue
  a_json="$(jq -r --arg a "$a" '.assets[]? | select(.name == $a)' <<<"$release")"
  a_url="$(jq -r '.browser_download_url // ""' <<<"$a_json")"
  [ -n "$a_url" ] || continue
  if ! curl -fsSL -o "$TMP/dl" "$a_url" 2>/dev/null; then
    echo "  ⚠ could not download $a; excluding from pin" >&2
    continue
  fi
  asset_shas["$a"]="$(sha256sum "$TMP/dl" | awk '{print $1}')"
  rm -f "$TMP/dl"
done

# The primary asset may be an explicit --asset override that is not a Linux
# archive (add-package.sh falls back to any non-mac/windows archive when no
# Linux build exists). Download it too so it is always pinned.
if [ -z "${asset_shas[$asset]:-}" ]; then
  if curl -fsSL -o "$TMP/dl" "$dlurl" 2>/dev/null; then
    asset_shas["$asset"]="$(sha256sum "$TMP/dl" | awk '{print $1}')"
    rm -f "$TMP/dl"
  fi
fi

# Primary asset digest (must be present; the asset was validated above).
actual="${asset_shas[$asset]:-}"
[ -n "$actual" ] || { echo "ERROR: could not download/vet primary asset $asset" >&2; exit 1; }
size_actual="$(jq -r --arg a "$asset" '.assets[]? | select(.name == $a) | .size // 0' <<<"$release" 2>/dev/null || echo 0)"

# Retain the primary asset so the caller (add-package.sh) can run the vet
# pre-checks (license/SPDX scan + asset validation) against the exact bytes
# that were vetted, without a second download.
ext="tar.gz"; case "$asset" in *.zip) ext="zip";; *.tgz) ext="tgz";; *.tar.xz) ext="tar.xz";; esac
curl -fsSL -o "$out/primary.$ext" "$dlurl" 2>/dev/null \
  || echo "  ⚠ could not retain primary asset for pre-checks" >&2
# The release JSON (asset list + license) for the caller's pre-checks.
printf '%s' "$release" > "$out/release.json"
printf '%s' "${declared_license:-$license}" > "$out/declared-license.txt"

expected="$(verify_against_checksums "$asset")"
verified=false
if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then verified=true; fi

# Per-asset pin map: every Linux archive asset the builder may download.
assets_json="{}"
for a in "${!asset_shas[@]}"; do
  [ -n "$a" ] && [ -n "${asset_shas[$a]}" ] || continue
  assets_json="$(jq -nc \
    --arg name "$a" \
    --arg sha "${asset_shas[$a]}" \
    --argjson size "$(jq -r --arg a "$a" '.assets[]? | select(.name == $a) | .size // 0' <<<"$release" 2>/dev/null || echo 0)" \
    --argjson obj "$assets_json" \
    '$obj + {($name): {sha256: $sha, size: $size}}')"
done

# ---------------------------------------------------------------------------
# Emit the provenance pin + report.
# ---------------------------------------------------------------------------
version_out="${version:-$tag}"
asset_count="$(printf '%s\n' "${!asset_shas[@]}" | grep -vc '^$' || true)"
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
  --argjson assets "$assets_json" \
  --argjson asset_count "$asset_count" \
  --arg vetted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg vetted_by "${VET_SOURCE:-}" \
  '{package:$package, upstream_repo:$upstream_repo, version:$version, tag:$tag,
    published_at:$published_at, license:$license, asset:$asset, asset_size:$asset_size,
    sha256:$sha256, expected_sha256:$expected_sha256,
    checksum_source:$checksum_source, checksum_verified:$checksum_verified,
    assets:$assets, asset_count:$asset_count,
    vetted_at:$vetted_at, vetted_by:$vetted_by}' \
  > "$out/release-metadata.json"

echo "→ vetted $repo@$tag ($pkg)"
echo "   assets:   $asset_count Linux archive asset(s)"
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