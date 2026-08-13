#!/usr/bin/env bash
# add-package.sh - validate, scaffold, deploy, and register a latest-debs
# package repo, driven by GitHub issue package requests.
#
# Subcommands:
#   scaffold        Validate the upstream repo + detect release format, then
#                   scaffold a <name>-debian repo from the template.
#   deploy-repo     Create the GitHub repo, push the scaffold, dispatch the
#                   first auto build. Requires GH_TOKEN (org admin PAT).
#   register-tools  Append the package to tools.yaml, commit, push.
#                   Requires GH_TOKEN.
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
  local name="" repo="" description="" out="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --repo) repo="$2"; shift 2;;
      --description) description="$2"; shift 2;;
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
  repo_json="$(curl -sf "${AUTH[@]}" "$API/repos/$repo" || true)"
  [ -n "$repo_json" ] || die "upstream repo $repo not found (or API rate-limited)"
  description="${description:-$(printf '%s' "$repo_json" | jq -r '.description // empty')}"
  echo "→ Upstream: $repo — $(printf '%s' "$repo_json" | jq -r '.full_name')"

  # Detect a Linux binary asset + archive format from the latest release.
  local release assets asset fmt
  release="$(curl -sf "${AUTH[@]}" "$API/repos/$repo/releases/latest" || true)"
  [ -n "$release" ] || die "upstream $repo has no (non-prerelease) release — nothing to package"
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

  echo "→ Creating latest-debs/$name-debian"
  GH_TOKEN="$GH_TOKEN" gh repo create "latest-debs/$name-debian" --public --source "$dir/$name-debian" --push >/dev/null

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
  [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required to update tools.yaml"
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