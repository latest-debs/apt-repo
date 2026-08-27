#!/usr/bin/env bash
# generate-provenance.sh - emit provenance.json for a build, published
# alongside the .deb/.dsc release assets.
#
# The vet-time pin (.github/release-metadata.json) already proves WHICH
# upstream bytes were verified. This proves WHAT BUILT THEM: the exact
# builder action ref, the workflow run, the commit, and a SHA-256 of every
# artifact actually shipped - so a user (or their security team) can trace a
# .deb back to a specific, inspectable CI run instead of trusting the file
# on faith. Nix-style build-provenance idea, adapted to this pipeline rather
# than requiring a from-source rebuild.
#
# Run from the release job's checkout, after the built artifacts have been
# downloaded into the working directory.
#
# Requirements: jq, sha256sum.

set -euo pipefail

yaml_val() {
  awk -v k="$1" -F': *' '$1==k { v=$2; gsub(/["'\'' ]/, "", v); sub(/#.*/, "", v); print v; exit }' package.yaml
}

PACKAGE="$(yaml_val package_name)"
VERSION="${VERSION:?VERSION env var required}"
BUILD_VERSION="${BUILD_VERSION:?BUILD_VERSION env var required}"
OUT="${OUT:-provenance.json}"

# Builder action ref, straight from the workflow that's about to publish
# this provenance - single source of truth, never drifts from what actually
# ran.
builder_ref="$(grep -oP 'uses:\s*\Kranjithrajv/debian-multiarch-builder@\S+' \
  .github/workflows/release.yml 2>/dev/null | head -n1 || true)"

# Upstream provenance pin captured at vet time, if this repo has one yet
# (auto-watch releases before the first manual vet won't).
upstream_pin="null"
if [ -f .github/release-metadata.json ]; then
  upstream_pin="$(jq -c '{
    upstream_repo, tag, published_at, license,
    asset, sha256, checksum_verified
  }' .github/release-metadata.json)"
fi

# SHA-256 every artifact actually being shipped in this release.
artifacts_json="{}"
shopt -s nullglob
for f in ./*.deb ./*.dsc ./*.debian.tar.xz ./*.orig.tar.xz; do
  [ -f "$f" ] || continue
  sha="$(sha256sum "$f" | awk '{print $1}')"
  artifacts_json="$(jq -cn --arg name "${f#./}" --arg sha "$sha" \
    --argjson obj "$artifacts_json" '$obj + {($name): $sha}')"
done
shopt -u nullglob

jq -n \
  --arg package "$PACKAGE" \
  --arg version "$VERSION" \
  --arg build_version "$BUILD_VERSION" \
  --arg release_tag "${VERSION}+${BUILD_VERSION}" \
  --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repo "${GITHUB_REPOSITORY:-}" \
  --arg commit "${GITHUB_SHA:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  --arg runner_os "${RUNNER_OS:-}" \
  --arg builder_action "${builder_ref:-}" \
  --argjson upstream_pin "$upstream_pin" \
  --argjson artifacts "$artifacts_json" \
  '{package:$package, version:$version, build_version:$build_version,
    release_tag:$release_tag, built_at:$built_at,
    build: {repo:$repo, commit:$commit, run_id:$run_id, run_url:$run_url,
            runner_os:$runner_os, builder_action:$builder_action},
    upstream_pin:$upstream_pin, artifacts:$artifacts}' \
  > "$OUT"

echo "→ wrote $OUT ($(jq '.artifacts | length' "$OUT") artifact(s) pinned)"
