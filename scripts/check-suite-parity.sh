#!/usr/bin/env bash
# check-suite-parity.sh - report where Debian already carries a tool at its
# latest upstream version, per the "we don't duplicate Debian" policy
# (README.md#debian-parity--when-we-step-aside). We step aside per SUITE:
# a suite Debian already covers is handed back by build-repo.sh, while every
# other suite keeps shipping.
#
# Generic across suites via --suite:
#   (no flag)                default - all five live suites at once.
#   --suite sid               any single suite (bookworm, trixie, forky, sid).
#   --suite trixie,sid        a comma-separated list.
#   --suite all                explicit spelling of the default.
# Narrowing to one/some suites is for targeted lookups (e.g. "is trixie
# caught up yet") - the gate only sees the suites actually checked, so
# narrowing also narrows what it can catch.
#
# Two modes:
#
#   Full scan (no --name/--repo) - reads tools.yaml, checks every tracked
#     tool's version(s) in the requested suite(s) against its upstream
#     latest release, and reports each suite's verdict. Nothing is removed
#     from tools.yaml automatically; the per-suite hand-back is applied at
#     build time from the published parity.json.
#
#   Single check (--name + --repo, used by add-package.sh at vet time) -
#     checks one candidate before it's scaffolded. Exits 3 only when a
#     RELEASED suite is at parity (see the grades below); rolling-suite
#     parity is advisory and exits 0. With --out <dir>, also writes
#     debian-parity-report.json (gate pass/fail, plus parity_suites and
#     advisory_suites) - same audit-trail shape as vet-prechecks.sh's
#     vet-report.json, so a rejected request has a structured record to
#     build the issue comment from instead of just a log line.
#
# Two grades of parity, per suites.json's `rolling` list:
#
#   RETIRE      - parity in a RELEASED suite (bullseye/bookworm/trixie).
#                 Users get it from the suite they already run with a plain
#                 `apt install`, so this channel is genuinely redundant.
#                 Hard stop for new requests; retirement candidate for
#                 tracked tools.
#   PIN-ADVISED - parity only in a rolling suite (forky/sid). We recommend
#                 pinning that single package from the suite rather than
#                 switching a stable box to it wholesale - but a user
#                 unwilling to enable sid at all still has no way to get the
#                 current version, so WE KEEP PACKAGING IT. Advisory only:
#                 never blocks a request, never triggers retirement.
#
# Version comparison uses dpkg --compare-versions after stripping the
# Debian revision and common repack suffixes (+ds, +dfsg) from the Debian
# version, and a leading "v" from the upstream tag - so "0.26.1+ds-1" (sid)
# and "v0.26.1" (upstream tag) compare equal.
#
# Requirements: curl, jq, dpkg.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_YAML="$ROOT/tools.yaml"
SUITES_JSON="$ROOT/suites.json"
. "$ROOT/scripts/lib.sh"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GITHUB_TOKEN")

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$SUITES_JSON" ] || { echo "ERROR: missing $SUITES_JSON" >&2; exit 1; }
# Single source of truth for the tracked suite list - see suites.json.
ALL_SUITES="$(jq -r '.suites | join(" ")' "$SUITES_JSON")"
# Rolling (non-released) suites: parity there is advisory, not a step-aside
# signal. Absent/empty `rolling` degrades to "every suite is released",
# i.e. the stricter pre-2026-09 behaviour.
ROLLING_SUITES="$(jq -r '(.rolling // []) | join(" ")' "$SUITES_JSON")"

is_rolling() {
  local s="$1" r
  for r in $ROLLING_SUITES; do [ "$s" = "$r" ] && return 0; done
  return 1
}

name="" repo="" debian_name="" upstream_version="" suite_arg="all" out="" json_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2;;
    --repo) repo="$2"; shift 2;;
    --debian-name) debian_name="$2"; shift 2;;
    --upstream-version) upstream_version="$2"; shift 2;;
    --suite) suite_arg="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    --json) json_out="$2"; shift 2;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2;;
  esac
done

if [ "$suite_arg" = "all" ]; then
  suites="$ALL_SUITES"
else
  suites="$(printf '%s' "$suite_arg" | tr ',' ' ')"
fi

log() { printf '[suite-parity] %s\n' "$*" >&2; }

# Raw madison text for a Debian package name (every suite, one request).
# NONE = tools.yaml has documented that Debian's same-named package is
# unrelated (e.g. "zed" is a 1980s Unix editor, not zed-industries/zed) -
# never look it up, or the collision reads as parity.
madison_for() {
  local dname="$1"
  [ "$dname" = "NONE" ] && { echo ""; return 0; }
  curl -fsSL "https://qa.debian.org/madison.php?package=${dname}&text=on" 2>/dev/null || echo ""
}

suite_version() {
  local madison_text="$1" suite="$2"
  printf '%s\n' "$madison_text" | awk -F'|' -v s="$suite" \
    '$3 ~ "^ *" s " *$" {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
}

# Debian version -> comparable upstream portion: strip epoch, the debian
# revision (everything after the last hyphen), and common DFSG repack tags.
normalize_debian() {
  local v="$1"
  v="${v#*:}"
  v="${v%-*}"
  v="${v%%+ds*}"
  v="${v%%+dfsg*}"
  printf '%s' "$v"
}

normalize_upstream() {
  local v="$1"
  v="${v#v}"; v="${v#V}"
  printf '%s' "$v"
}

version_ge_upstream() {
  if dpkg --compare-versions "$1" ge "$2" 2>/dev/null; then echo true; else echo false; fi
}

# Emits one "pkg<TAB>suite<TAB>debian_version_or_not-in-suite<TAB>upstream<TAB>verdict"
# line per requested suite, given already-fetched madison text for the package.
check_suites() {
  local pkg="$1" madison_text="$2" up_ver="$3"
  local up_norm; up_norm="$(normalize_upstream "$up_ver")"
  local suite dver dnorm ge
  for suite in $suites; do
    dver="$(suite_version "$madison_text" "$suite")"
    if [ -z "$dver" ]; then
      printf '%s\t%s\tnot-in-%s\t%s\tKEEP\n' "$pkg" "$suite" "$suite" "$up_ver"
      continue
    fi
    dnorm="$(normalize_debian "$dver")"
    ge="$(version_ge_upstream "$dnorm" "$up_norm")"
    if [ "$ge" = "true" ]; then
      if is_rolling "$suite"; then
        printf '%s\t%s\t%s\t%s\tPIN-ADVISED\n' "$pkg" "$suite" "$dver" "$up_ver"
      else
        printf '%s\t%s\t%s\t%s\tRETIRE\n' "$pkg" "$suite" "$dver" "$up_ver"
      fi
    else
      printf '%s\t%s\t%s\t%s\tKEEP\n' "$pkg" "$suite" "$dver" "$up_ver"
    fi
  done
}

if [ -n "$name" ] && [ -n "$repo" ]; then
  # Single-candidate mode (used by add-package.sh at vet time, all suites
  # by default).
  if [ -z "$upstream_version" ]; then
    rel="$(curl -sfL "${AUTH[@]}" "$API/repos/$repo/releases/latest" || true)"
    upstream_version="$(printf '%s' "$rel" | jq -r '.tag_name // empty')"
  fi
  [ -n "$upstream_version" ] || { echo "ERROR: could not resolve upstream version for $repo" >&2; exit 2; }

  madison_text="$(madison_for "${debian_name:-$name}")"
  parity_suites="" advisory_suites="" versions_json="{}"
  while IFS=$'\t' read -r p suite dver upv verdict; do
    [ -n "$p" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$suite" "$dver" "$upv" "$verdict"
    versions_json="$(jq -nc --argjson obj "$versions_json" --arg s "$suite" --arg v "$dver" '$obj + {($s): $v}')"
    case "$verdict" in
      RETIRE)
        echo "PARITY[$suite]: $p is already at $dver in Debian $suite (upstream: $upv)." >&2
        parity_suites="${parity_suites}${suite},"
        ;;
      PIN-ADVISED)
        echo "PIN-ADVISED[$suite]: $p is at $dver in Debian $suite (upstream: $upv) - advisory only, not a blocker." >&2
        advisory_suites="${advisory_suites}${suite},"
        ;;
    esac
  done < <(check_suites "$name" "$madison_text" "$upstream_version")
  parity_suites="${parity_suites%,}"
  advisory_suites="${advisory_suites%,}"

  if [ -n "$out" ]; then
    mkdir -p "$out"
    gate="pass"; [ -n "$parity_suites" ] && gate="fail"
    detail="no live Debian suite is at parity yet"
    [ -n "$advisory_suites" ] && detail="at parity only in rolling suite(s): $advisory_suites - pin advised, still packaged here"
    [ -n "$parity_suites" ] && detail="already at parity in released suite(s): $parity_suites"
    jq -n \
      --arg gate "$gate" \
      --arg package "$name" \
      --arg upstream_version "$upstream_version" \
      --argjson suites_checked "$(printf '%s\n' $suites | jq -R . | jq -s .)" \
      --argjson parity_suites "$(printf '%s' "$parity_suites" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)" \
      --argjson advisory_suites "$(printf '%s' "$advisory_suites" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)" \
      --argjson versions "$versions_json" \
      --arg detail "$detail" \
      --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{gate:$gate, package:$package, upstream_version:$upstream_version,
        suites_checked:$suites_checked, parity_suites:$parity_suites,
        advisory_suites:$advisory_suites,
        versions:$versions, detail:$detail, checked_at:$checked_at}' \
      > "$out/debian-parity-report.json"
  fi

  if [ -n "$parity_suites" ]; then
    echo "  Per policy (README.md#debian-parity--when-we-step-aside) we do not" >&2
    echo "  package tools already current in a RELEASED Debian suite. Debian" >&2
    echo "  already carries '$name' at the latest version in: $parity_suites." >&2
    echo "  That's the suite the requester already runs, so a plain" >&2
    echo "  'apt install $name' already gets them the current version." >&2
    exit 3
  fi
  if [ -n "$advisory_suites" ]; then
    echo "  NOTE: '$name' is already current in rolling suite(s): $advisory_suites." >&2
    echo "  Recommend pinning just that one package from there rather than" >&2
    echo "  switching the whole box to it. But that's advice, not a refusal -" >&2
    echo "  a user unwilling to enable $advisory_suites at all still has no" >&2
    echo "  other route to the current version, so we package it. Proceeding." >&2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Full scan mode: every tool in tools.yaml, across the requested suite(s).
# ---------------------------------------------------------------------------
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$TOOLS_YAML" ] || { echo "ERROR: missing $TOOLS_YAML" >&2; exit 1; }

# Dynamic header/format: PACKAGE, UPSTREAM, one column per requested suite,
# then VERDICT (the suites - if any - where the package is already at parity).
fmt="%-16s %-16s"
header=(PACKAGE UPSTREAM)
for s in $suites; do
  fmt="$fmt %-22s"
  header+=("$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')")
done
fmt="$fmt %s\n"
header+=(VERDICT)
# shellcheck disable=SC2059
printf "$fmt" "${header[@]}"

SCAN_TMP=""
SCAN_JSONL=""
if [ -n "$json_out" ]; then
  SCAN_TMP="$(mktemp -d)"
  trap 'rm -rf "$SCAN_TMP"' EXIT
  SCAN_JSONL="$SCAN_TMP/packages.jsonl"
  : > "$SCAN_JSONL"
fi

retire_count=0
advisory_count=0
while IFS=$'\t' read -r pkg dname homepage; do
  [ -n "$pkg" ] || continue
  ghrepo="${homepage#https://github.com/}"
  if [ -z "$ghrepo" ] || [ "$ghrepo" = "$homepage" ]; then
    log "skip $pkg: no github homepage"
    continue
  fi
  rel="$(curl -sfL "${AUTH[@]}" "$API/repos/$ghrepo/releases/latest" 2>/dev/null || true)"
  up_ver="$(printf '%s' "$rel" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [ -z "$up_ver" ]; then
    log "skip $pkg: could not resolve upstream release"
    continue
  fi

  madison_text="$(madison_for "$dname")"
  cols=("$pkg" "$up_ver")
  parity_suites=""
  advisory_suites=""
  suites_json="{}"
  while IFS=$'\t' read -r p suite dver upv verdict; do
    [ -n "$p" ] || continue
    cols+=("$dver")
    suites_json="$(jq -nc --argjson obj "$suites_json" --arg s "$suite" --arg v "$dver" '$obj + {($s): $v}')"
    [ "$verdict" = "RETIRE" ] && parity_suites="${parity_suites}${suite},"
    [ "$verdict" = "PIN-ADVISED" ] && advisory_suites="${advisory_suites}${suite},"
  done < <(check_suites "$pkg" "$madison_text" "$up_ver")
  parity_suites="${parity_suites%,}"
  advisory_suites="${advisory_suites%,}"
  # VERDICT column: released-suite parity is the actionable one; rolling-suite
  # parity is shown as "pin:<suites>" so it reads as advice, not a to-do.
  if [ -n "$parity_suites" ]; then
    cols+=("$parity_suites")
  elif [ -n "$advisory_suites" ]; then
    cols+=("pin:$advisory_suites")
  else
    cols+=("-")
  fi

  # shellcheck disable=SC2059
  printf "$fmt" "${cols[@]}"

  [ -n "$parity_suites" ] && retire_count=$((retire_count + 1))
  [ -n "$advisory_suites" ] && advisory_count=$((advisory_count + 1))
  if [ -n "$SCAN_JSONL" ]; then
    jq -nc --arg pkg "$pkg" --arg upstream "$up_ver" --argjson suites "$suites_json" \
      --argjson parity "$(printf '%s' "$parity_suites" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)" \
      --argjson advisory "$(printf '%s' "$advisory_suites" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)" \
      '{package:$pkg, upstream_version:$upstream, suites:$suites,
        parity_suites:$parity, advisory_suites:$advisory}' >> "$SCAN_JSONL"
  fi
  sleep 0.5 # be polite to qa.debian.org and the GitHub API across many tools
done < <(parse_tools "$TOOLS_YAML" | cut -f1,3,4)

echo
if [ "$retire_count" -gt 0 ]; then
  echo "$retire_count package(s) flagged for retirement (already at parity in a RELEASED Debian suite - see the VERDICT column for which)." >&2
  echo "Review and remove from tools.yaml by hand - see README.md#debian-parity--when-we-step-aside." >&2
else
  echo "No tracked packages are at parity in a released suite - nothing to retire." >&2
fi
if [ "$advisory_count" -gt 0 ]; then
  echo "$advisory_count package(s) are also current in a rolling suite (VERDICT 'pin:<suite>')." >&2
  echo "Advisory only: recommend pinning that single package from the suite; we keep packaging it" >&2
  echo "for users unwilling to enable forky/sid at all. No action needed." >&2
fi

if [ -n "$json_out" ]; then
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson suites_checked "$(printf '%s\n' $suites | jq -R . | jq -s .)" \
    --argjson rolling_suites "$(printf '%s\n' $ROLLING_SUITES | jq -R . | jq -s 'map(select(. != ""))')" \
    --argjson retire_count "$retire_count" --argjson advisory_count "$advisory_count" \
    --slurpfile packages "$SCAN_JSONL" \
    '{generated_at:$generated_at, suites_checked:$suites_checked,
      rolling_suites:$rolling_suites, retire_count:$retire_count,
      advisory_count:$advisory_count, packages:$packages}' \
    > "$json_out"
fi
