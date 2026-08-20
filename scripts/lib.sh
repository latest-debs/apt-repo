# lib.sh - shared constants for apt-repo automation scripts.
#
# Source with:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib.sh"
#
# Not executable on its own; has no shebang and sets no -e/-u (the sourcing
# script's set -euo pipefail already applies).

# GitHub org every *-debian package repo (and this apt-repo) lives under.
ORG="latest-debs"

# GitHub REST API base URL.
API="https://api.github.com"

# Identity used for automation commits (scaffold, register-tools, rollout),
# matching GitHub Actions' own default bot identity.
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
