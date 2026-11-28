#!/usr/bin/env bash
# sign-repo.sh - GPG-sign the generated repository indexes.
#
# Runs in CI on every rebuild (the "Sign repository" step in rebuild.yml,
# on ubuntu-latest) with APT_SIGNING_KEY / APT_SIGNING_KEY_PASS supplied as
# Actions secrets - so the private key is held in GitHub Actions, not only
# offline. See RUNBOOK.md for custody, backup and rotation.
#
# Also runnable by hand on any Debian/Ubuntu host:
#
#   export APT_SIGNING_KEY="<ascii-armored private key or path to keyring>"
#   export APT_SIGNING_KEY_PASS="<passphrase>"
#   scripts/sign-repo.sh
#
# Produces dists/<suite>/InRelease and dists/<suite>/Release.gpg.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTS="$ROOT/dists"

log() { printf '[sign-repo] %s\n' "$*"; }
die() { printf '[sign-repo] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gpg >/dev/null || die "gpg is required"
[[ -n "${APT_SIGNING_KEY:-}" ]] || die "APT_SIGNING_KEY is not set"
[[ -d "$DISTS" ]] || die "no dists/ found; run build-repo.sh first"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"

if [[ -f "$APT_SIGNING_KEY" ]]; then
  gpg --batch --import "$APT_SIGNING_KEY"
else
  echo "$APT_SIGNING_KEY" | gpg --batch --import
fi

KEYID="$(gpg --list-secret-keys --with-colons | awk -F: '$1=="sec"{print $5; exit}')"
[[ -n "$KEYID" ]] || die "no secret key found"

sign_suite() {
  local suite="$1"
  log "   signing dists/$suite"
  local rel="$DISTS/$suite/Release"

  gpg --pinentry-mode loopback --batch \
      --passphrase "${APT_SIGNING_KEY_PASS:-}" \
      --default-key "$KEYID" \
      --armor --detach-sign -o "$rel.gpg" "$rel"

  gpg --pinentry-mode loopback --batch \
      --passphrase "${APT_SIGNING_KEY_PASS:-}" \
      --default-key "$KEYID" \
      --clearsign -o "$DISTS/$suite/InRelease" "$rel"
}

for suite in "$DISTS"/*/; do
  suite="${suite%/}"
  suite="${suite##*/}"
  sign_suite "$suite"
done

log "done. dists/*/InRelease and dists/*/Release.gpg written."
