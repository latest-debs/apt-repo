#!/usr/bin/env bash
# sync-readmes.sh - regenerate every *-debian README.md from
# templates/package-scaffold/README.md plus each repo's package.yaml.
#
# The scaffold owns the shared template (badges, install, verify,
# building, collaborate, disclaimer, license). Per-repo content the
# template cannot encode is preserved from the repo's current README:
#   - the intro paragraph (upstream display name / wording)
#   - the "Supported distributions & architectures" block
#     (distro line + arch lines)
#   - an optional "## Notes" section
# Everything else is regenerated. Idempotent: repos already current
# are skipped.
#
# Usage:
#   sync-readmes.sh                          # sibling *-debian checkouts
#   sync-readmes.sh --local ./uv-debian      # one local repo
#   sync-readmes.sh --dry-run                # preview only (no writes)
#   sync-readmes.sh --push                   # commit + pull --rebase + push
#                                            # (default: write files only)
set -euo pipefail

APT_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APT_REPO_DIR

DRY_RUN=false
PUSH=false
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --push) PUSH=true; shift ;;
    --local) ONLY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

targets=()
if [ -n "$ONLY" ]; then
  targets=("$ONLY")
else
  for d in "$APT_REPO_DIR"/../*-debian; do
    [ -d "$d" ] || continue
    targets+=("$d")
  done
fi

for dir in "${targets[@]}"; do
  export TARGET_DIR="$dir" DRY_RUN PUSH
  python3 - "$dir" << 'EOF'
import os, re, subprocess, sys

d = sys.argv[1]
apt = os.environ['APT_REPO_DIR']
name = os.path.basename(d)
pkg_file = os.path.join(d, 'package.yaml')
readme = os.path.join(d, 'README.md')

def fail(msg):
    print(f'SKIP {name}: {msg}')
    sys.exit(0)

if not os.path.isfile(pkg_file): fail('no package.yaml')
if not os.path.isfile(readme): fail('no README.md')

fields = {}
for line in open(pkg_file):
    m = re.match(r'^(package_name|github_repo|description|license):\s*"?([^"\n]*)"?\s*$', line)
    if m: fields[m.group(1)] = m.group(2)
pkg, repo = fields.get('package_name', ''), fields.get('github_repo', '')
lic = fields.get('license', '')

tpl = open(os.path.join(apt, 'templates/package-scaffold/README.md')).read()
rendered = (tpl.replace('__PKG_NAME__', pkg)
               .replace('__GITHUB_REPO__', repo)
               .replace('__DESCRIPTION__', fields.get('description', ''))
               .replace('__LICENSE__', lic))

cur = open(readme).read()

def section(text, heading):
    m = re.search(rf'^{re.escape(heading)}\s*\n\n(.*?)(?=^## |\Z)', text, re.S | re.M)
    return m.group(1).rstrip() + '\n' if m else None

# Preserve per-repo intro: text between badges and the SERVICE promo.
def intro_of(text):
    m = re.search(r'\]\(../../actions\)\n\n(.*?)\n\nWant your own project', text, re.S)
    return m.group(1) if m else None

cur_intro, new_intro = intro_of(cur), intro_of(rendered)
if cur_intro and new_intro:
    rendered = rendered.replace(new_intro, cur_intro, 1)

# Header banner only if the repo actually has the image.
import pathlib
if not pathlib.Path(d, '.github', 'readme-header.png').is_file():
    rendered = re.sub(r'^!\[.*?\]\(.*?\)\n\n', '', rendered, count=1)

# Preserve per-repo distro + arch block.
cur_supp = section(cur, '## Supported distributions & architectures')
if cur_supp:
    rendered = re.sub(r'(?<=## Supported distributions & architectures\n\n).*?(?=\n## )',
                      cur_supp, rendered, count=1, flags=re.S)

# Preserve optional ## Notes section (inserted before ## Building).
cur_notes = section(cur, '## Notes')
if cur_notes and '## Notes' not in rendered:
    rendered = rendered.replace('## Building', '## Notes\n\n' + cur_notes + '\n## Building', 1)

if cur == rendered:
    print(f'OK {name}: already current')
    sys.exit(0)

if os.environ['DRY_RUN'] == 'true':
    print(f'DIFF {name}: would update README.md')
    sys.exit(0)

open(readme, 'w').write(rendered)
print(f'UPDATED {name}')

if os.environ['PUSH'] == 'true':
    branch = subprocess.run(['git', '-C', d, 'branch', '--show-current'],
                            capture_output=True, text=True).stdout.strip()
    subprocess.run(['git', '-C', d, 'add', 'README.md'], check=True)
    subprocess.run(['git', '-C', d, 'commit', '-q', '-m',
                    'docs: sync README from apt-repo template'], check=False)
    has_remote = subprocess.run(['git', '-C', d, 'remote', 'get-url', 'origin'],
                                capture_output=True).returncode == 0
    ok = (has_remote
          and subprocess.run(['git', '-C', d, 'pull', '--rebase', 'origin', branch],
                             capture_output=True).returncode == 0
          and subprocess.run(['git', '-C', d, 'push', 'origin', branch],
                             capture_output=True).returncode == 0)
    print(('PUSHED ' if ok else 'PUSH-FAILED ') + name
          + ('' if has_remote else ' (no remote, committed locally only)'))
EOF
done
