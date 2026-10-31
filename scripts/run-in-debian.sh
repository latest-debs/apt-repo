#!/usr/bin/env bash
# run-in-debian.sh - run build-repo.sh inside a Debian container.
#
# build-repo.sh needs Debian/Ubuntu tools (apt-ftparchive, dpkg-deb) that are
# not available on non-Debian hosts. This wrapper mounts the repository into a
# Debian container and executes the build there, so you can develop on any OS.
#
# Usage:  scripts/run-in-debian.sh
#         DEBIAN_TAG=bookworm scripts/run-in-debian.sh   # override image

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBIAN_TAG="${DEBIAN_TAG:-bookworm}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

exec docker run --rm \
  -v "$ROOT:/repo" \
  -w /repo \
  -e DEBIAN_FRONTEND=noninteractive \
  "debian:$DEBIAN_TAG" \
  bash -c 'apt-get update -qq && apt-get install -y -qq curl jq dpkg-dev apt-utils >/dev/null && bash /repo/scripts/build-repo.sh'
