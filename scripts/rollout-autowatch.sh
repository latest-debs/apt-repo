#!/usr/bin/env bash
# rollout-autowatch.sh - apply the auto-watch release workflow + detect-version.sh
# to every local *-debian repo. Idempotent: skips repos already at the target.
# Also rolls out the release-published -> apt-repo rebuild notify workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="$ROOT/apt-repo/templates/package-scaffold"

rollout() {
  local repo_dir="$1"
  local pkg_yaml="$repo_dir/package.yaml"
  [ -f "$pkg_yaml" ] || { echo "skip $repo_dir: no package.yaml"; return; }

  local name fmt upstream desc
  name="$(awk '/^package_name:/{print $2}' "$pkg_yaml")"
  fmt="$(awk '/^artifact_format:/{print $2}' "$pkg_yaml")"
  upstream="$(awk '/^github_repo:/{print $2}' "$pkg_yaml")"
  desc="$(sed -n 's/^description: //p' "$pkg_yaml" | tr -d '"')"
  [ -n "$name" ] || { echo "skip $repo_dir: no package_name"; return; }

  local wf="$repo_dir/.github/workflows/release.yml"
  local dt="$repo_dir/.github/scripts/detect-version.sh"
  local nf="$repo_dir/.github/workflows/notify-apt-repo.yml"
  local tnf="$TPL/.github/workflows/notify-apt-repo.yml"

  sed -e "s|__PKG_NAME__|$name|g" \
      -e "s|__GITHUB_REPO__|$upstream|g" \
      -e "s|__ARTIFACT_FORMAT__|$fmt|g" \
      -e "s|__DESCRIPTION__|$desc|g" \
      "$TPL/.github/workflows/release.yml" > "$wf.tmp"

  if cmp -s "$wf" "$wf.tmp"; then
    rm "$wf.tmp"
    echo "ok    $name (unchanged)"
  else
    mv "$wf.tmp" "$wf"
    mkdir -p "$repo_dir/.github/scripts"
    cp "$TPL/.github/scripts/detect-version.sh" "$dt"
    chmod +x "$dt"
    echo "updated $name"
  fi

  # Release-published -> apt-repo rebuild webhook (no placeholders).
  if [ -f "$tnf" ]; then
    if [ -f "$nf" ] && cmp -s "$nf" "$tnf"; then
      : # already current
    else
      mkdir -p "$(dirname "$nf")"
      cp "$tnf" "$nf"
      echo "updated $name (notify-apt-repo workflow)"
    fi
  fi
}

if [ -n "${1:-}" ]; then
  rollout "$1"
else
  for d in "$ROOT"/*-debian/; do rollout "$d"; done
fi
