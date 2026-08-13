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

API="https://api.github.com"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/package-scaffold"
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
  local name="" repo="" description="" out="." version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --repo) repo="$2"; shift 2;;
      --description) description="$2"; shift 2;;
      --version) version="$2"; shift 2;;
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
    | grep -iE '\.(tar\.gz|tgz|zip)$' \
    | grep -viE 'sha256|checksum|\.asc$|source|sums' \
    | head -n1 || true)"
  if [ -z "$asset" ]; then
    asset="$(printf '%s' "$assets" \
      | grep -iE '\.(tar\.gz|tgz|zip)$' \
      | grep -viE 'darwin|macos|windows|win32|msvc|apple|sha256|checksum|\.asc$|source|sums' \
      | head -n1 || true)"
  fi
  [ -n "$asset" ] || die "no Linux .tar.gz/.tgz/.zip asset found in the latest release of $repo"
  case "$asset" in
    *.tar.gz) fmt="tar.gz";;
    *.tgz) fmt="tgz";;
    *.zip) fmt="zip";;
  esac
  echo "→ Asset: $asset (format: $fmt)"

  # VET TIME: verify the upstream asset's SHA-256 against the release's
  # published checksum file and capture the release identity + digest as a
  # provenance pin. The builder re-verifies against this pin when building
  # the vetted version, so a release altered after this point is caught.
  echo "→ Verifying upstream asset checksum and capturing release metadata"
  local vet_dir="$out/vet-release"
  mkdir -p "$vet_dir"
  bash "$(dirname "$0")/vet-release.sh" \
    --repo "$repo" --name "$name" --asset "$asset" --version "$release_tag" \
    --out "$vet_dir"
  # A failed cross-check is a warning, not a scaffold blocker: the digest is
  # still pinned from the bytes we downloaded, and the admin reviews the
  # summary before approving. A mismatch is called out above in the log.
  [ -f "$vet_dir/release-metadata.json" ] || die "vet-release.sh produced no release-metadata.json"

  # Scaffold from template.
  local dest="$out/$name-debian"
  rm -rf "$dest"
  cp -a "$TEMPLATE" "$dest"
  for f in "$dest"/package.yaml "$dest"/README.md "$dest"/.github/workflows/release.yml; do
    sed -i \
      -e "s/__PKG_NAME__/$name/g" \
      -e "s|__GITHUB_REPO__|$repo|g" \
      -e "s/__ARTIFACT_FORMAT__/$fmt/g" \
      -e "s/__DESCRIPTION__/${description//\//\\/}/g" \
      "$f"
  done

  # Embed the vet-time provenance pin in the scaffolded repo. The build
  # workflow hands this file to the builder, which verifies the downloaded
  # upstream bytes against the pinned SHA-256 for the vetted version.
  cp "$vet_dir/release-metadata.json" "$dest/.github/release-metadata.json"

  ( cd "$dest" && git init -q -b main && git add -A && \
    git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
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

  echo "→ Deploying latest-debs/$name-debian"
  # Push with the token inline so it is never persisted into the scaffold's
  # .git/config (a credential helper could otherwise cache it); disable any
  # credential helper for this push. Only the deploy step uses the org
  # token - it must create repos in the org, which GITHUB_TOKEN cannot.
  local remote="https://x-access-token:${GH_TOKEN}@github.com/latest-debs/$name-debian.git"
  if gh repo view "latest-debs/$name-debian" >/dev/null 2>&1; then
    echo "→ Repo already exists; pushing updated scaffold"
    ( cd "$dir/$name-debian" && git -c credential.helper= push -q --force "$remote" main )
  else
    echo "→ Creating latest-debs/$name-debian"
    GH_TOKEN="$GH_TOKEN" gh repo create "latest-debs/$name-debian" --public --source "$dir/$name-debian" --push >/dev/null
  fi

  # Provision the apt-repo rebuild trigger token so this repo's
  # release-published webhook can dispatch an immediate rebuild. Best-effort:
  # if it can't be set (the org token lacks Secrets permission), the ~6h
  # scheduled rebuild still catches releases.
  if [ -n "${TRIGGER_TOKEN:-}" ]; then
    if printf '%s' "$TRIGGER_TOKEN" \
        | GH_TOKEN="$GH_TOKEN" gh secret set TRIGGER_TOKEN --repo "latest-debs/$name-debian" >/dev/null 2>&1; then
      echo "→ Set TRIGGER_TOKEN secret on latest-debs/$name-debian"
    else
      echo "  ⚠ could not set TRIGGER_TOKEN secret (schedule will still catch releases)"
    fi
  fi

  echo "→ Dispatching first auto build"
  GH_TOKEN="$GH_TOKEN" gh workflow run release.yml --repo "latest-debs/$name-debian" -f auto=true -f enable_lintian=true >/dev/null
  echo "→ Repo ready: https://github.com/latest-debs/$name-debian"
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

  printf '\n%s:\n  source: https://github.com/latest-debs/%s-debian\n  homepage: https://github.com/%s\n' \
    "$name" "$name" "$repo" >> "$tools_yaml"
  local dir branch refspec
  dir="$(dirname "$tools_yaml")"
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [ "$branch" = "HEAD" ]; then refspec="HEAD:main"; else refspec="HEAD"; fi
  ( cd "$dir" && git add "$(basename "$tools_yaml")" && \
    git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
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