# lib.sh - shared constants and helpers for apt-repo automation scripts.
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

# parse_tools <tools.yaml> - emit one "pkg<TAB>source<TAB>debian_name<TAB>
# homepage" line per package. debian_name defaults to pkg when tools.yaml
# doesn't override it; source/homepage are raw (empty when absent).
#
# The single parser for tools.yaml's flat "name:\n  field: value\n" format -
# every script that needs a subset of these fields should call this and
# select columns with cut (e.g. `parse_tools "$TOOLS_YAML" | cut -f1,2`)
# rather than re-implementing the awk state machine.
parse_tools() {
  awk '
    /^[a-zA-Z0-9_.-]+:/ {
      if (pkg != "") print pkg "\t" src "\t" (dname != "" ? dname : pkg) "\t" homepage
      pkg = $0; sub(/:.*/, "", pkg); gsub(/[[:space:]]/, "", pkg)
      src = ""; dname = ""; homepage = ""
      next
    }
    /^  source:/      { src = $0; sub(/^  source:[[:space:]]*/, "", src); gsub(/"/, "", src) }
    /^  debian_name:/ { dname = $0; sub(/^  debian_name:[[:space:]]*/, "", dname); gsub(/"/, "", dname) }
    /^  homepage:/    { homepage = $0; sub(/^  homepage:[[:space:]]*/, "", homepage) }
    END { if (pkg != "") print pkg "\t" src "\t" (dname != "" ? dname : pkg) "\t" homepage }
  ' "$1"
}
