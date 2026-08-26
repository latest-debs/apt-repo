#!/usr/bin/env bash
# rollout-autowatch.sh - one-command feature channel: ship the latest
# templates/package-scaffold to every *-debian repo in a single pass.
#
# Bump the builder pin or fix a workflow/glob in templates/package-scaffold,
# commit it in apt-repo, then run this script to propagate it to all repos.
# Each repo gets one commit ("rollout: sync packaging files from apt-repo
# template") pushed to main. Idempotent: repos already at the template are
# skipped.
#
# Per repo, these template-owned files are regenerated (placeholders
# substituted from the repo's package.yaml) and pushed if they differ:
#   .github/workflows/release.yml          (builder version pin, globs, gates)
#   .github/workflows/notify-apt-repo.yml  (release-published rebuild webhook)
#   .github/workflows/notify-failure.yml   (structured failure notifications)
#   .github/scripts/detect-version.sh      (auto-watch version detection)
#   .github/scripts/license-check.sh       (license recheck / warn gate)
#   .github/scripts/collect-failure-report.sh (structured failure report)
# package.yaml is only touched to BACKFILL a missing license: pin (never
# regenerated - it carries per-repo config). README.md is not rolled out:
# child READMEs carry per-repo customizations the template cannot encode.
#
# Usage:
#   rollout-autowatch.sh                        # all repos in tools.yaml (remote)
#   rollout-autowatch.sh --repo latest-debs/uv-debian  # one remote repo
#   rollout-autowatch.sh --local ./uv-debian    # one local repo
#   rollout-autowatch.sh --dry-run              # preview only (no writes/pushes)
#   rollout-autowatch.sh --skip-ci-check        # bypass the CI gate below (not recommended)
#
# CI gate: refuses to run unless latest-debs/apt-repo's own CI workflow has
# already passed on HEAD - a rollout from a red (or not-yet-checked) commit
# is exactly how a broken templates/package-scaffold/.github/workflows/
# release.yml (bad YAML block-scalar indentation) got fanned out to 40
# *-debian repos' release.yml on 2026-08-19, breaking their workflow_dispatch
# and scheduled auto-builds simultaneously. Push HEAD and let CI finish
# before rolling out; --skip-ci-check exists only for a deliberate emergency
# override, not routine use.
#
# Requirements: gh (authenticated) plus a token with Contents:write on the
# latest-debs repos - GH_TOKEN if set, otherwise the logged-in gh token.
set -euo pipefail

APT_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$APT_REPO_DIR/templates/package-scaffold"
TOOLS_YAML="$APT_REPO_DIR/tools.yaml"
. "$APT_REPO_DIR/scripts/lib.sh"

DRY_RUN=false
SKIP_CI_CHECK=false
TARGETS=()

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --skip-ci-check) SKIP_CI_CHECK=true; shift;;
    --repo) TARGETS+=("remote:$2"); shift 2;;
    --local) TARGETS+=("local:$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) TARGETS+=("local:$1"); shift;;
  esac
done

TOKEN="${GH_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ "$DRY_RUN" = false ] && [ -z "$TOKEN" ]; then
  echo "ERROR: GH_TOKEN (or an authenticated gh) is required to push rollouts" >&2
  exit 1
fi

# CI gate: the template content this script fans out to every repo comes
# from this working tree's HEAD - refuse to propagate a commit whose own CI
# hasn't been verified green, so a red (or unpushed/unchecked) template
# change can't reach 40 repos before anyone notices it's broken.
check_source_ci() {
  local sha run_json status result url
  sha="$(git -C "$APT_REPO_DIR" rev-parse HEAD)"
  echo "→ Checking $ORG/apt-repo CI status for HEAD (${sha:0:7})..."
  # grep for the '[' line: some shell environments (e.g. a version-manager
  # shim) print an activation notice to stdout ahead of gh's own output,
  # which would otherwise corrupt the JSON fed to jq below.
  run_json="$(gh run list --repo "$ORG/apt-repo" --workflow CI \
      --json headSha,conclusion,status,url --limit 30 2>/dev/null \
      | grep '^\[' \
      | jq -c --arg sha "$sha" '[.[] | select(.headSha == $sha)] | .[0] // empty')"
  if [ -z "$run_json" ] || [ "$run_json" = "null" ]; then
    echo "ERROR: no CI run found for HEAD (${sha:0:7}) on $ORG/apt-repo." >&2
    echo "  Push this commit and wait for CI, or pass --skip-ci-check to bypass (not recommended)." >&2
    exit 1
  fi
  status="$(echo "$run_json" | jq -r '.status')"
  result="$(echo "$run_json" | jq -r '.conclusion')"
  url="$(echo "$run_json" | jq -r '.url')"
  if [ "$status" != "completed" ]; then
    echo "ERROR: CI is still running for HEAD (${sha:0:7}) on $ORG/apt-repo: $url" >&2
    echo "  Wait for it to finish, or pass --skip-ci-check to bypass (not recommended)." >&2
    exit 1
  fi
  if [ "$result" != "success" ]; then
    echo "ERROR: CI failed (conclusion=$result) for HEAD (${sha:0:7}) on $ORG/apt-repo: $url" >&2
    echo "  Rolling out from a red commit is exactly how a broken release.yml" >&2
    echo "  reached 40 repos on 2026-08-19. Fix CI before rolling out, or pass" >&2
    echo "  --skip-ci-check to bypass (not recommended)." >&2
    exit 1
  fi
  echo "  ✅ CI passed for HEAD (${sha:0:7}): $url"
}

if [ "$SKIP_CI_CHECK" = true ]; then
  echo "⚠ Skipping CI gate (--skip-ci-check) - rolling out without verifying apt-repo's own CI status" >&2
elif command -v gh >/dev/null 2>&1; then
  check_source_ci
else
  echo "ERROR: gh is required to check CI status before rolling out (or pass --skip-ci-check)" >&2
  exit 1
fi

# Default target: every registered repo, operated on remotely.
if [ ${#TARGETS[@]} -eq 0 ]; then
  while IFS= read -r repo; do
    [ -n "$repo" ] && TARGETS+=("remote:$repo")
  done < <(awk '/^[[:space:]]+source:[[:space:]]+https:\/\/github.com\//{print $2}' "$TOOLS_YAML" | sed 's|https://github.com/||')
fi
[ ${#TARGETS[@]} -gt 0 ] || { echo "ERROR: no repos found in $TOOLS_YAML" >&2; exit 1; }

CHANGED=0
UNCHANGED=0
FAILED=0
FAILED_REPOS=()

# Move $cand over $target only when they differ; record the change for the
# summary. In dry-run mode the working tree is never touched.
stage_file() {
  local target="$1" cand="$2" label="$3"
  if cmp -s "$target" "$cand"; then
    rm -f "$cand"
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    rm -f "$cand"
  else
    mv "$cand" "$target"
  fi
  changed_files+=("$label")
}

# Regenerate the rollout files for one repo directory from the template.
apply_to_dir() {
  local dir="$1"
  local pkg_yaml="$dir/package.yaml"
  changed_files=()
  [ -f "$pkg_yaml" ] || { echo "  skip $dir: no package.yaml"; return; }

  local name fmt upstream desc
  name="$(awk '/^package_name:/{print $2}' "$pkg_yaml")"
  fmt="$(awk '/^artifact_format:/{print $2}' "$pkg_yaml")"
  upstream="$(awk '/^github_repo:/{print $2}' "$pkg_yaml")"
  desc="$(sed -n 's/^description: //p' "$pkg_yaml" | tr -d '"')"
  [ -n "$name" ] || { echo "  skip $dir: no package_name"; return; }

  # Escape sed replacement metacharacters so desc text cannot corrupt the
  # substitutions (the '|' delimiter is used throughout).
  desc="${desc//\\/\\\\}"
  desc="${desc//&/\\&}"
  desc="${desc//|/\\|}"

  local subst=(-e "s|__PKG_NAME__|$name|g" -e "s|__GITHUB_REPO__|$upstream|g"
               -e "s|__ARTIFACT_FORMAT__|$fmt|g" -e "s|__DESCRIPTION__|$desc|g")

  # smoke_skip (optional package.yaml list) -> case-glob for the smoke
  # script's skip branch. Binaries like nu_plugin_* / protoc-gen-* /
  # flashfetch speak no --version; without a skip they fail the gate.
  # Empty/absent -> never-matching sentinel keeps the case valid.
  local skip_globs
  skip_globs="$(awk '/^smoke_skip:/{flag=1; next} flag && /^  - /{gsub(/^  - |"|\x27/, ""); printf "%s|", $0; next} {flag=0}' "$pkg_yaml")"
  skip_globs="${skip_globs%|}"
  if [ -n "$skip_globs" ]; then
    subst+=(-e "s|__SMOKE_SKIP_GLOB__|$skip_globs|g")
  else
    subst+=(-e "s|__SMOKE_SKIP_GLOB__|__SMOKE_SKIP_NONE__|g")
  fi

  local wf="$dir/.github/workflows/release.yml"
  local nf="$dir/.github/workflows/notify-apt-repo.yml"
  local ff="$dir/.github/workflows/notify-failure.yml"
  local dt="$dir/.github/scripts/detect-version.sh"
  local lc="$dir/.github/scripts/license-check.sh"
  local fr="$dir/.github/scripts/collect-failure-report.sh"

  mkdir -p "$(dirname "$wf")" "$(dirname "$nf")" "$(dirname "$dt")"
  sed "${subst[@]}" "$TPL/.github/workflows/release.yml" > "$wf.tmp"
  stage_file "$wf" "$wf.tmp" ".github/workflows/release.yml"
  if [ -f "$TPL/.github/workflows/notify-apt-repo.yml" ]; then
    cp "$TPL/.github/workflows/notify-apt-repo.yml" "$nf.tmp"
    stage_file "$nf" "$nf.tmp" ".github/workflows/notify-apt-repo.yml"
  fi
  if [ -f "$TPL/.github/workflows/notify-failure.yml" ]; then
    cp "$TPL/.github/workflows/notify-failure.yml" "$ff.tmp"
    stage_file "$ff" "$ff.tmp" ".github/workflows/notify-failure.yml"
  fi
  cp "$TPL/.github/scripts/detect-version.sh" "$dt.tmp"
  chmod +x "$dt.tmp"
  stage_file "$dt" "$dt.tmp" ".github/scripts/detect-version.sh"
  cp "$TPL/.github/scripts/license-check.sh" "$lc.tmp"
  chmod +x "$lc.tmp"
  stage_file "$lc" "$lc.tmp" ".github/scripts/license-check.sh"
  cp "$TPL/.github/scripts/collect-failure-report.sh" "$fr.tmp"
  chmod +x "$fr.tmp"
  stage_file "$fr" "$fr.tmp" ".github/scripts/collect-failure-report.sh"

  # Backfill a license: pin when package.yaml lacks one, using the upstream's
  # live SPDX id. New scaffolds already carry it; this covers repos created
  # before the license field existed. Targeted insert - package.yaml is never
  # regenerated wholesale (it carries per-repo config).
  if [ -n "$upstream" ] && ! grep -q '^license:' "$pkg_yaml"; then
    local spdx
    spdx="$(curl -fsSL -H "Authorization: token ${TOKEN:?}" "$API/repos/$upstream" 2>/dev/null | jq -r '.license.spdx_id // empty' 2>/dev/null || true)"
    if [ -n "$spdx" ]; then
      cp "$pkg_yaml" "$pkg_yaml.tmp"
      sed -i "/^github_repo:/a license: $spdx" "$pkg_yaml.tmp"
      stage_file "$pkg_yaml" "$pkg_yaml.tmp" "package.yaml"
    fi
  fi
}

commit_and_push() {
  local dir="$1" repo="$2"
  if [ ${#changed_files[@]} -eq 0 ]; then
    echo "  ok $repo (unchanged)"
    UNCHANGED=$((UNCHANGED + 1))
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "  → would update $repo: ${changed_files[*]}"
    CHANGED=$((CHANGED + 1))
    return
  fi
  ( cd "$dir" && git add "${changed_files[@]}" && \
    git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
      commit -q -m "rollout: sync packaging files from apt-repo template" )
  local remote="https://x-access-token:${TOKEN}@github.com/$repo.git"
  if ( cd "$dir" && git -c credential.helper= push -q "$remote" HEAD:main ); then
    echo "  → updated $repo: ${changed_files[*]}"
    CHANGED=$((CHANGED + 1))
  else
    echo "  ⚠ push failed for $repo (non-fast-forward? permissions?)" >&2
    FAILED_REPOS+=("$repo")
    FAILED=$((FAILED + 1))
  fi
}

run_remote() {
  local repo="$1"
  local dir="$TMP/${repo//\//_}"
  echo "== $repo =="
  rm -rf "$dir"
  if ! gh repo clone "$repo" "$dir" -- --quiet --depth 1 2>/dev/null; then
    echo "  ⚠ clone failed" >&2
    FAILED_REPOS+=("$repo")
    FAILED=$((FAILED + 1))
    return
  fi
  apply_to_dir "$dir"
  commit_and_push "$dir" "$repo"
}

run_local() {
  local dir="$1"
  local base repo
  base="$(basename "$dir")"
  # Prefer the canonical repo from tools.yaml so a local clone with a stale
  # or personal origin (e.g. ranjithrajv/uv-debian) still pushes to
  # latest-debs/uv-debian; fall back to the clone's origin, then its name.
  repo="$(awk -v b="$base" '/^[[:space:]]+source:[[:space:]]+https:\/\/github.com\//{u=$2; sub(/.*github.com\//,"",u); n=u; sub(/.*\//,"",n); if (n==b){print u; exit}}' "$TOOLS_YAML")"
  if [ -z "$repo" ]; then
    repo="$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#^https://github.com/##; s#\.git$##; s#/$##')"
  fi
  [ -n "$repo" ] || repo="$base"
  echo "== $dir ($repo) =="
  apply_to_dir "$dir"
  commit_and_push "$dir" "$repo"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for t in "${TARGETS[@]}"; do
  case "$t" in
    remote:*) run_remote "${t#remote:}";;
    local:*)  run_local  "${t#local:}";;
  esac
done

echo
echo "== summary =="
echo "updated:   $CHANGED"
echo "unchanged: $UNCHANGED"
echo "failed:    $FAILED"
if [ "$FAILED" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILED_REPOS[@]}" >&2
  exit 1
fi
