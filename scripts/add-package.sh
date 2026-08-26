#!/usr/bin/env bash
# add-package.sh - validate, scaffold, deploy, and register a latest-debs
# package repo, driven by GitHub issue package requests.
#
# Subcommands:
#   scaffold        Validate the upstream repo + detect release format, verify
#                   the asset checksum, then scaffold a <name>-debian repo
#                   from the template (embedding the vet-time provenance pin).
#                   Add --version <tag> to vet a specific release instead of
#                   latest (also used by CI's deterministic template dry-run).
#   deploy-repo     Create the GitHub repo, push the scaffold, dispatch the
#                   first auto build. Requires GH_TOKEN (org-restricted
#                   fine-grained PAT with Administration/Contents/Workflows
#                   write on latest-debs only). Also copies TRIGGER_TOKEN
#                   (apt-repo-scoped PAT for rebuild dispatch) to the new
#                   repo's secrets when provided.
#   register-tools  Append the package to tools.yaml, commit, push. Only
#                   needs a repo-scoped GITHUB_TOKEN.
#
# Requirements: curl, jq, gh, git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
TEMPLATE="$(cd "$SCRIPT_DIR/.." && pwd)/templates/package-scaffold"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# scaffold
# ---------------------------------------------------------------------------
scaffold() {
  local name="" repo="" description="" out="." version="" license=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --repo) repo="$2"; shift 2;;
      --description) description="$2"; shift 2;;
      --version) version="$2"; shift 2;;
      --license) license="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      *) die "unknown scaffold arg: $1";;
    esac
  done
  [ -n "$name" ] && [ -n "$repo" ] || die "scaffold requires --name and --repo"

  # Sanitize the package name (lowercase, hyphen-separated).
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/_/g; s/_/-/g; s/-+/-/g; s/^-|-$//g')"
  [ -n "$name" ] || die "could not derive a valid package name"
  case "$repo" in
    *github.com/*) repo="${repo#https://github.com/}"; repo="${repo#http://github.com/}";;
    *github.com:*) repo="${repo#git@github.com:}";;
  esac
  repo="$(printf '%s' "$repo" | sed 's|/$||')"
  case "$repo" in
    */*) : ;;
    *) die "upstream repo must be owner/repo, got: $repo";;
  esac

  # Validate upstream repo exists.
  repo_json="$(curl -sfL "${AUTH[@]}" "$API/repos/$repo" || true)"
  [ -n "$repo_json" ] || die "upstream repo $repo not found (or API rate-limited)"
  description="${description:-$(printf '%s' "$repo_json" | jq -r '.description // empty')}"
  # License: prefer the request's explicit license, else the upstream repo's
  # current SPDX id from the API. Pinned into package.yaml so every build
  # rechecks the live license against it (license-check.sh, warn-only).
  license="${license:-$(printf '%s' "$repo_json" | jq -r '.license.spdx_id // empty')}"
  [ -n "$license" ] || license="unknown"
  # Canonicalize renamed/redirected upstreams (e.g. extrawurst/gitui →
  # gitui-org/gitui). The API follows the redirect and reports the current
  # full_name, which the scaffold, version detection, and the builder must all
  # use — the redirect (301) breaks the builder's non-following release check.
  repo="$(printf '%s' "$repo_json" | jq -r '.full_name' || true)"
  case "$repo" in
    */*) : ;;
    *) die "could not canonicalize upstream repo name from: $repo_json";;
  esac
  echo "→ Upstream: $repo — $(printf '%s' "$repo_json" | jq -r '.description // empty')"

  # Detect a Linux binary asset + archive format from the upstream release
  # (a specific tag when --version is given, otherwise latest). vet-release.sh
  # is told the same tag so the asset it downloads is the one we detected.
  local release assets asset fmt
  if [ -n "$version" ]; then
    release="$(curl -sfL "${AUTH[@]}" "$API/repos/$repo/releases/tags/$version" || true)"
    [ -n "$release" ] || die "upstream $repo has no release tagged $version"
  else
    release="$(curl -sfL "${AUTH[@]}" "$API/repos/$repo/releases/latest" || true)"
    [ -n "$release" ] || die "upstream $repo has no (non-prerelease) release — nothing to package"
  fi
  local release_tag
  release_tag="$(printf '%s' "$release" | jq -r '.tag_name // empty')"
  assets="$(printf '%s' "$release" | jq -r '.assets[]?.name' || true)"
  # Prefer a Linux build; fall back to any non-mac/windows archive.
  asset="$(printf '%s' "$assets" \
    | grep -iE 'linux' \
    | grep -iE '\.(tar\.gz|tgz|tar\.xz|zip)$' \
    | grep -viE 'sha256|checksum|\.asc$|source|sums' \
    | head -n1 || true)"
  if [ -z "$asset" ]; then
    asset="$(printf '%s' "$assets" \
      | grep -iE '\.(tar\.gz|tgz|tar\.xz|zip)$' \
      | grep -viE 'darwin|macos|windows|win32|msvc|apple|sha256|checksum|\.asc$|source|sums' \
      | head -n1 || true)"
  fi
  [ -n "$asset" ] || die "no Linux .tar.gz/.tgz/.tar.xz/.zip asset found in the latest release of $repo"
  case "$asset" in
    *.tar.gz) fmt="tar.gz";;
    *.tgz) fmt="tgz";;
    *.tar.xz) fmt="tar.xz";;
    *.zip) fmt="zip";;
  esac
  echo "→ Asset: $asset (format: $fmt)"

  # DEBIAN PARITY: don't package a tool that any live Debian suite
  # (bookworm/trixie/forky/sid) already carries at this upstream version -
  # see README.md#debian-parity-when-we-step-aside. No --suite is passed, so
  # this checks all four. A brand-new request has no tools.yaml entry yet,
  # so the Debian package name defaults to $name (the common case); a
  # mismatched name just fails open to "not in <suite>" rather than
  # blocking a legitimate request. --out records debian-parity-report.json
  # (pass or fail) so a rejection has the same kind of structured audit
  # trail as the license/asset/architecture pre-checks below, instead of
  # just a log line - the package-request workflow reads it to comment
  # the specific reason on the issue.
  echo "→ Checking Debian suite parity"
  bash "$(dirname "$0")/check-suite-parity.sh" \
    --name "$name" --repo "$repo" --upstream-version "$release_tag" --out "$out" \
    || die "already at parity in a released Debian suite — see README.md#debian-parity-when-we-step-aside"

  # VET TIME: verify the upstream asset's SHA-256 against the release's
  # published checksum file and capture the release identity + digest as a
  # provenance pin. The builder re-verifies against this pin when building
  # the vetted version, so a release altered after this point is caught.
  echo "→ Verifying upstream asset checksum and capturing release metadata"
  local vet_dir="$out/vet-release"
  mkdir -p "$vet_dir"
  bash "$(dirname "$0")/vet-release.sh" \
    --repo "$repo" --name "$name" --asset "$asset" --version "$release_tag" \
    --license "$license" --out "$vet_dir"
  # A failed cross-check is a warning, not a scaffold blocker: the digest is
  # still pinned from the bytes we downloaded, and the admin reviews the
  # summary before approving. A mismatch is called out above in the log.
  [ -f "$vet_dir/release-metadata.json" ] || die "vet-release.sh produced no release-metadata.json"

  # VET PRE-CHECKS: license/SPDX scan + asset validation against the exact
  # vetted bytes, plus a per-arch asset-map check that yields the PRECISE
  # architecture set this release covers (instead of the coarse "all"). The
  # gate (pass/warn/fail) is the prerequisite to widening the approval
  # funnel: gate==pass requests are eligible for lower-friction approval.
  echo "→ Running vet pre-checks (license/SPDX scan, asset validation, arch coverage)"
  local precheck_out="$out/vet-prechecks"
  mkdir -p "$precheck_out"
  local pri_ext="$fmt"
  bash "$(dirname "$0")/vet-prechecks.sh" \
    --asset "$vet_dir/primary.$pri_ext" --format "$fmt" \
    --license "$license" \
    --release-json "$vet_dir/release.json" --out "$precheck_out" \
    || die "vet-prechecks.sh failed"
  [ -f "$precheck_out/vet-report.json" ] || die "vet-prechecks.sh produced no vet-report.json"
  local vet_gate
  vet_gate="$(jq -r '.gate' "$precheck_out/vet-report.json")"
  case "$vet_gate" in
    pass) echo "→ ✅ Pre-checks PASSED — request is eligible for lower-friction approval";;
    warn) echo "→ ⚠ Pre-checks WARNED — admin review recommended (see vet-report.json)";;
    fail) echo "→ ❌ Pre-checks FAILED — needs human review before any approval";;
  esac

  # Scaffold from template.
  local dest="$out/$name-debian"
  rm -rf "$dest"
  cp -a "$TEMPLATE" "$dest"
  for f in "$dest"/package.yaml "$dest"/README.md "$dest"/.github/workflows/release.yml; do
    sed -i \
      -e "s/__PKG_NAME__/$name/g" \
      -e "s|__GITHUB_REPO__|$repo|g" \
      -e "s/__ARTIFACT_FORMAT__/$fmt/g" \
      -e "s|__LICENSE__|$license|g" \
      -e "s/__DESCRIPTION__/${description//\//\\/}/g" \
      "$f"
  done

  # Embed the vet-time provenance pin in the scaffolded repo. The build
  # workflow hands this file to the builder, which verifies the downloaded
  # upstream bytes against the pinned SHA-256 for the vetted version.
  cp "$vet_dir/release-metadata.json" "$dest/.github/release-metadata.json"
  # Embed the vet pre-check report (license/SPDX + asset + arch coverage) so
  # approvers and the build can inspect what was validated at vet time.
  cp "$precheck_out/vet-report.json" "$dest/.github/vet-report.json"

  ( cd "$dest" && git init -q -b main && git add -A && \
    git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
      commit -q -m "scaffold $name Debian packaging" )
  echo "→ Scaffolded $dest"
}

# ---------------------------------------------------------------------------
# deploy-repo
# ---------------------------------------------------------------------------
deploy_repo() {
  local name="" dir="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --dir) dir="$2"; shift 2;;
      *) die "unknown deploy-repo arg: $1";;
    esac
  done
  [ -n "$name" ] || die "deploy-repo requires --name"
  [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN (org admin token) is required to create the repository"
  [ -d "$dir/$name-debian" ] || die "scaffold not found at $dir/$name-debian"

  local repo="$ORG/$name-debian"
  echo "→ Deploying $repo"
  # Push with the token inline so it is never persisted into the scaffold's
  # .git/config (a credential helper could otherwise cache it); disable any
  # credential helper for this push. Only the deploy step uses the org
  # token - it must create repos in the org, which GITHUB_TOKEN cannot.
  local remote="https://x-access-token:${GH_TOKEN}@github.com/$repo.git"
  if gh repo view "$repo" >/dev/null 2>&1; then
    echo "→ Repo already exists; pushing updated scaffold"
    ( cd "$dir/$name-debian" && git -c credential.helper= push -q --force "$remote" main )
  else
    echo "→ Creating $repo"
    GH_TOKEN="$GH_TOKEN" gh repo create "$repo" --public --source "$dir/$name-debian" --push >/dev/null
  fi

  # Provision the apt-repo rebuild trigger token so this repo's
  # release-published webhook can dispatch an immediate rebuild. Best-effort:
  # if it can't be set (the org token lacks Secrets permission), the ~6h
  # scheduled rebuild still catches releases.
  if [ -n "${TRIGGER_TOKEN:-}" ]; then
    if printf '%s' "$TRIGGER_TOKEN" \
        | GH_TOKEN="$GH_TOKEN" gh secret set TRIGGER_TOKEN --repo "$repo" >/dev/null 2>&1; then
      echo "→ Set TRIGGER_TOKEN secret on $repo"
    else
      echo "  ⚠ could not set TRIGGER_TOKEN secret (schedule will still catch releases)"
    fi
  fi

  echo "→ Dispatching first auto build"
  # GitHub needs a moment to index a just-pushed workflow file before it's
  # dispatchable; firing immediately after the push above reliably 404s
  # ("workflow release.yml not found on the default branch") even though
  # the push itself succeeded. Retry with backoff instead of failing the
  # whole deploy over a race that resolves itself within seconds.
  local attempt dispatched=0
  for attempt in $(seq 1 10); do
    if GH_TOKEN="$GH_TOKEN" gh workflow run release.yml --repo "$repo" -f auto=true -f enable_lintian=true >/dev/null 2>&1; then
      dispatched=1
      break
    fi
    echo "  workflow not indexed yet, retrying ($attempt/10)..."
    sleep $((attempt * 2))
  done
  [ "$dispatched" = "1" ] || die "release.yml never became dispatchable on $repo after repeated retries"
  echo "→ Repo ready: https://github.com/$repo"
}

# ---------------------------------------------------------------------------
# register-tools
# ---------------------------------------------------------------------------
register_tools() {
  local name="" repo="" tools_yaml=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --repo) repo="$2"; shift 2;;
      --tools-yaml) tools_yaml="$2"; shift 2;;
      *) die "unknown register-tools arg: $1";;
    esac
  done
  [ -n "$name" ] && [ -n "$repo" ] && [ -n "$tools_yaml" ] || die "register-tools requires --name, --repo, --tools-yaml"
  # Repo-scoped GITHUB_TOKEN is enough here (this only ever pushes to the
  # current repo); GH_TOKEN is accepted for local/back-compat.
  [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ] || die "GITHUB_TOKEN (or GH_TOKEN) is required to update tools.yaml"
  [ -f "$tools_yaml" ] || die "tools.yaml not found at $tools_yaml"

  if grep -q "^$name:" "$tools_yaml"; then
    echo "→ $name already registered in tools.yaml"
    return 0
  fi

  printf '\n%s:\n  source: https://github.com/%s/%s-debian\n  homepage: https://github.com/%s\n' \
    "$name" "$ORG" "$name" "$repo" >> "$tools_yaml"
  local dir branch refspec
  dir="$(dirname "$tools_yaml")"
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [ "$branch" = "HEAD" ]; then refspec="HEAD:main"; else refspec="HEAD"; fi
  ( cd "$dir" && git add "$(basename "$tools_yaml")" && \
    git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
      commit -q -m "register $name package" && git push -q origin "$refspec" )
  echo "→ Registered $name in tools.yaml"
}

# ---------------------------------------------------------------------------
cmd="${1:-}"
[ -n "$cmd" ] || usage
shift
case "$cmd" in
  scaffold) scaffold "$@";;
  deploy-repo) deploy_repo "$@";;
  register-tools) register_tools "$@";;
  *) usage;;
esac