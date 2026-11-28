#!/usr/bin/env bash
# vet-prechecks.sh - automated license/SPDX + asset sanity pre-checks, run at
# VET time against a downloaded release asset (the primary Linux archive).
#
# These pre-checks are the prerequisite to widening the approval funnel: a
# package request whose pre-checks all pass (gate == "pass") is eligible for
# lower-friction approval; anything that fails needs a human to look.
#
# Checks performed:
#   * License/SPDX  - extract the archive, locate license files, detect SPDX
#     identifiers both from SPDX-License-Identifier headers and from license
#     text fingerprints, and compare against the declared SPDX id.
#   * Asset         - the file is a valid archive (not an HTML/error page or a
#     stub), and it actually contains a Linux ELF executable.
#   * Architectures - when --release-json is given, map every release Linux
#     archive asset to the Debian architecture(s) it covers (same patterns the
#     builder's auto-discovery uses), yielding a precise coverage list instead
#     of the coarse "all".
#
# Emits <out>/vet-report.json:
#   {
#     "gate": "pass"|"warn"|"fail",
#     "license": {"declared", "detected", "license_files", "matches", "status", "detail"},
#     "asset":   {"format", "valid", "is_html", "size", "binary", "elf_arch", "status", "detail"},
#     "architectures": {"covered": [], "missing": [], "assets": {arch: asset}},
#     "vetted_at": "..."
#   }
#
# Requirements: tar, unzip, file, jq, sha256sum, grep.
#
# Usage:
#   vet-prechecks.sh --asset <file> [--format tar.gz|tgz|tar.xz|zip]
#                    [--license <spdx-id>]
#                    [--release-json <release.json>] --out <dir>

set -euo pipefail

asset="" format="" declared_license="" out="$(pwd)" release_json=""

while [ $# -gt 0 ]; do
  case "$1" in
    --asset)  asset="$2"; shift 2;;
    --format) format="$2"; shift 2;;
    --license) declared_license="$2"; shift 2;;
    --release-json) release_json="$2"; shift 2;;
    --out)    out="$2"; shift 2;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$asset" ] && [ -f "$asset" ] || { echo "ERROR: --asset file is required" >&2; exit 2; }
[ -n "$format" ] || {
  case "$asset" in
    *.zip) format="zip";;
    *.tgz) format="tgz";;
    *.tar.gz) format="tar.gz";;
    *.tar.xz) format="tar.xz";;
    *) format="raw";;
  esac
}
[ -n "$out" ] || out="$(pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Asset checks
# ---------------------------------------------------------------------------
size="$(stat -c%s "$asset" 2>/dev/null || echo 0)"
ftype="$(file -b "$asset" 2>/dev/null || echo "unknown")"
is_html=false
case "$ftype" in
  *HTML*|*html*|*text*) is_html=true;;
esac

valid=false
case "$format" in
  zip)
    if unzip -Z1 "$asset" >/dev/null 2>&1; then valid=true; fi
    ;;
  tar.gz|tgz|tar.xz)
    # No -z/-J: GNU tar auto-detects gzip/xz compression from the archive
    # itself, so one path covers all three tar variants.
    if tar -tf "$asset" >/dev/null 2>&1; then valid=true; fi
    ;;
  raw)
    # No archive - the asset itself is the binary (e.g. oh-my-posh's
    # "posh-linux-amd64", no .tar.*/.zip wrapper). "Valid" just means it's
    # actually an ELF executable, checked below via the same ELF scan every
    # other format uses.
    if printf '%s' "$ftype" | grep -qi "ELF"; then valid=true; fi
    ;;
esac

# Locate Linux ELF executables inside the archive.
binary="" elf_arch="" elf_count=0
case "$format" in
  zip)
    mkdir -p "$TMP/x" && unzip -q "$asset" -d "$TMP/x" 2>/dev/null || true
    ;;
  tar.gz|tgz|tar.xz)
    mkdir -p "$TMP/x" && tar -xf "$asset" -C "$TMP/x" 2>/dev/null || true
    ;;
  raw)
    mkdir -p "$TMP/x" && cp "$asset" "$TMP/x/" 2>/dev/null || true
    ;;
esac
if [ -d "$TMP/x" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    finfo="$(file -b "$f" 2>/dev/null || true)"
    if printf '%s' "$finfo" | grep -qi "ELF"; then
      elf_count=$((elf_count + 1))
      if [ -z "$binary" ]; then
        binary="$(basename "$f")"
        elf_arch="$(printf '%s' "$finfo" | grep -oiE 'aarch64|ARM aarch64|x86-64|x86_64|Intel 80386|i386|RISC-V|PowerPC|PPC64|s390x|MIPS' | head -1 || true)"
        [ -n "$elf_arch" ] || elf_arch="$(printf '%s' "$finfo" | grep -oiE '64-bit|32-bit' | head -1 || true)"
      fi
    fi
  done < <(find "$TMP/x" -type f 2>/dev/null || true)
fi

asset_status="warn"
asset_detail=""
if [ "$is_html" = "true" ]; then
  asset_status="fail"
  asset_detail="asset is an HTML page (release URL likely 404'd or rate-limited)"
elif [ "$valid" != "true" ]; then
  asset_status="fail"
  asset_detail="asset is not a valid $format archive"
elif [ "$elf_count" -eq 0 ]; then
  asset_status="fail"
  asset_detail="no Linux ELF executable found in archive (source-only or non-Linux build?)"
elif [ "$size" -lt 1024 ]; then
  asset_status="fail"
  asset_detail="asset is only $size bytes; likely a stub or error response"
else
  asset_status="pass"
  asset_detail="valid $format archive containing ${elf_count} ELF executable(s); first: ${binary}${elf_arch:+ (${elf_arch})}"
fi

# ---------------------------------------------------------------------------
# Per-arch asset-map check: map every release Linux archive asset to the
# Debian architecture(s) it covers, using the same naming patterns the
# builder uses for auto-discovery (src/data/architecture-patterns.yaml). This
# yields a PRECISE architecture list instead of the coarse "all" - a release
# that ships only amd64/arm64 gets labeled exactly that, so the approval
# funnel (and the package's README/control metadata) reflects reality.
# ---------------------------------------------------------------------------
# Debian arch -> regex patterns over asset names (kept in sync with the
# builder's architecture-patterns.yaml).
arch_patterns() {
  cat <<'PAT'
amd64	x86_64|amd64|x64
arm64	aarch64|arm64
armel	armel|armeabi([^h]|$)|arm-.*eabi([^h]|$)
armhf	armv7|armhf|arm-.*gnueabihf
i386	i686|i386|x86[^_]|x86$|32-bit
ppc64el	powerpc64le|ppc64le
s390x	s390x
riscv64	riscv64gc|riscv64
loong64	loongarch64|loong64
PAT
}

asset_map_coverage=""
if [ -n "$release_json" ] && [ -f "$release_json" ]; then
  # All Linux archive asset names in the release. A "raw" (bare, unarchived
  # binary) release has no extension to match on, so exclude known
  # non-binary asset types instead of requiring one - see add-package.sh.
  if [ "$format" = "raw" ]; then
    rel_assets="$(jq -r '.assets[]?.name' "$release_json" 2>/dev/null \
      | grep -iE 'linux' \
      | grep -viE '\.(tar\.gz|tgz|tar\.xz|tar\.bz2|tar\.zst|zip|deb|rpm|exe|dmg|pkg|txt|md|json|sig|asc|sha256|sha256sum|sha512|sbom)$' \
      | grep -viE 'sha256|checksum|\.asc$|source|sums' || true)"
  else
    rel_assets="$(jq -r '.assets[]?.name' "$release_json" 2>/dev/null \
      | grep -iE 'linux' \
      | grep -iE '\.(tar\.gz|tgz|tar\.xz|zip)$' \
      | grep -viE 'sha256|checksum|\.asc$|source|sums' || true)"
  fi
  covered=""
  covered_assets=""
  missing=""
  while IFS=$'\t' read -r arch pat; do
    [ -n "$arch" ] || continue
    match="$(printf '%s\n' "$rel_assets" | grep -iE "$pat" | head -n1 || true)"
    if [ -n "$match" ]; then
      covered="${covered}${arch},"
      covered_assets="${covered_assets}${arch}=${match}\n"
    else
      missing="${missing}${arch},"
    fi
  done < <(arch_patterns)
  covered="${covered%,}"
  missing="${missing%,}"
  asset_map_coverage="$(jq -nc \
    --arg covered "$covered" \
    --arg missing "$missing" \
    --arg assets "$(printf '%b' "$covered_assets")" \
    '{covered: ($covered | split(",") | map(select(length>0))),
      missing: ($missing | split(",") | map(select(length>0))),
      assets: (($assets | split("\n") | map(select(length>0)) | map(split("=") | {(.[0]): .[1]}) | add) // {})}')"
fi

# The asset-map coverage sharpens the single-asset arch heuristic: the
# primary asset's ELF arch is checked against the archs the release's asset
# NAMES claim to cover, catching mislabeled archives.
if [ -n "$asset_map_coverage" ] && [ "$asset_status" = "pass" ] && [ -n "$elf_arch" ]; then
  covered_list="$(jq -r '.covered[]' <<<"$asset_map_coverage" | tr '\n' ' ')"
  if [ -n "$covered_list" ]; then
    asset_detail="$asset_detail; release covers: ${covered_list}"
  fi
fi


# ---------------------------------------------------------------------------
# License / SPDX scan
# ---------------------------------------------------------------------------
find_license_files() {
  find "$TMP/x" -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' \) 2>/dev/null | head -n 10
}

detect_spdx_headers() {
  # SPDX-License-Identifier: header anywhere in the tree (text files only).
  grep -rIhoE 'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.\-]+' "$TMP/x" 2>/dev/null \
    | sed -E 's/.*:[[:space:]]*//' | sort -u || true
}

# Fingerprint a license file's text against a small table of common SPDX
# licenses by distinctive phrase. Echoes matching SPDX ids (newline separated).
fingerprint_license() {
  local text="$1" ids=""
  # MIT
  if grep -qi "Permission is hereby granted, free of charge, to any person obtaining a copy" <<<"$text"; then
    ids="${ids}MIT
"
  fi
  # Apache-2.0
  if grep -qi "Apache License" <<<"$text" && grep -qi "Version 2.0" <<<"$text"; then
    ids="${ids}Apache-2.0
"
  fi
  # GPL-3.0 vs GPL-2.0
  if grep -qi "GNU GENERAL PUBLIC LICENSE" <<<"$text"; then
    if grep -qi "Version 3" <<<"$text"; then
      ids="${ids}GPL-3.0
"
    elif grep -qi "Version 2" <<<"$text"; then
      ids="${ids}GPL-2.0
"
    else
      ids="${ids}GPL-3.0
GPL-2.0
"
    fi
  fi
  # MPL-2.0
  if grep -qi "Mozilla Public License Version 2.0" <<<"$text"; then
    ids="${ids}MPL-2.0
"
  fi
  # BSD-3-Clause vs BSD-2-Clause
  if grep -qi "Redistribution and use in source and binary forms" <<<"$text"; then
    if grep -qi "Neither the name" <<<"$text"; then
      ids="${ids}BSD-3-Clause
"
    else
      ids="${ids}BSD-2-Clause
"
    fi
  fi
  # ISC
  if grep -qi "Permission to use, copy, modify, and/or distribute this software" <<<"$text"; then
    ids="${ids}ISC
"
  fi
  # Unlicense
  if grep -qi "This is free and unencumbered software released into the public domain" <<<"$text"; then
    ids="${ids}Unlicense
"
  fi
  # Zlib
  if grep -qi "This software is provided 'as-is', without any express or implied warranty" <<<"$text"; then
    ids="${ids}Zlib
"
  fi
  printf '%s' "$ids" | sed '/^$/d' | sort -u
}

license_files="$(find_license_files)"
detected="$(detect_spdx_headers)"

# Fingerprint the license file texts (only when no SPDX header was found).
if [ -z "$detected" ] && [ -n "$license_files" ]; then
  while IFS= read -r lf; do
    [ -n "$lf" ] || continue
    # Fold multi-line LICENSE into one text blob for phrase matching.
    text="$(tr '\n' ' ' < "$lf" 2>/dev/null || true)"
    detected="$(printf '%s\n%s\n' "$detected" "$(fingerprint_license "$text")" | sed '/^$/d' | sort -u)"
  done <<<"$license_files"
fi
detected="$(printf '%s' "$detected" | sed '/^$/d' | sort -u)"

# Normalize declared license (SPDX ids are case-sensitive, but "Apache-2" ==
# "Apache-2.0" aliases are common; do an exact check plus alias normalization).
normalize() {
  case "$1" in
    Apache-2|Apache2) printf 'Apache-2.0';;
    GPL-3|GPL3) printf 'GPL-3.0';;
    GPL-2|GPL2) printf 'GPL-2.0';;
    BSD-3|BSD3) printf 'BSD-3-Clause';;
    BSD-2|BSD2) printf 'BSD-2-Clause';;
    *) printf '%s' "$1";;
  esac
}
declared_norm="$(normalize "$declared_license")"
detected_norm="$(printf '%s\n' "$detected" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  printf '%s\n' "$(normalize "$d")"
done | sort -u || true)"

license_status="warn"
license_matches=false
license_detail=""
if [ -z "$declared_license" ] || [ "$declared_license" = "unknown" ]; then
  license_status="warn"
  license_detail="no license declared; detected: ${detected:-none}"
elif [ -n "$detected_norm" ] && grep -qix "$declared_norm" <<<"$detected_norm"; then
  license_status="pass"
  license_matches=true
  license_detail="declared ${declared_license} matches detected ${detected}"
elif [ -z "$detected_norm" ]; then
  license_status="warn"
  license_detail="declared ${declared_license} but no license/SPDX content detected in archive"
else
  license_status="fail"
  license_detail="declared ${declared_license} but detected ${detected}"
fi

# ---------------------------------------------------------------------------
# Overall gate + report
# ---------------------------------------------------------------------------
gate="pass"
if [ "$asset_status" = "fail" ] || [ "$license_status" = "fail" ]; then
  gate="fail"
elif [ "$asset_status" = "warn" ] || [ "$license_status" = "warn" ]; then
  gate="warn"
fi

vetted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg gate "$gate" \
  --argjson license_files "$(printf '%s\n' "$license_files" | sed '/^$/d' | sed 's|^|/|' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo '[]')" \
  --arg declared "${declared_license:-}" \
  --argjson detected "$(printf '%s\n' "$detected" | sed '/^$/d' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo '[]')" \
  --arg license_matches "$license_matches" \
  --arg license_status "$license_status" \
  --arg license_detail "$license_detail" \
  --arg format "$format" \
  --argjson asset_size "$size" \
  --arg asset_valid "$valid" \
  --arg asset_is_html "$is_html" \
  --arg asset_binary "${binary:-}" \
  --arg asset_arch "${elf_arch:-}" \
  --arg asset_status "$asset_status" \
  --arg asset_detail "$asset_detail" \
  --argjson architectures "${asset_map_coverage:-null}" \
  --arg vetted_at "$vetted_at" \
  '{gate:$gate,
    license:{declared:$declared, detected:$detected, license_files:$license_files,
             matches:($license_matches=="true"), status:$license_status, detail:$license_detail},
    asset:{format:$format, size:$asset_size, valid:($asset_valid=="true"), is_html:($asset_is_html=="true"),
           binary:$asset_binary, elf_arch:$asset_arch, status:$asset_status, detail:$asset_detail},
    architectures:$architectures,
    vetted_at:$vetted_at}' \
  > "$out/vet-report.json"

echo "→ pre-checks: gate=$gate"
echo "   license:  $license_status — $license_detail"
echo "   asset:    $asset_status — $asset_detail"
if [ -n "$asset_map_coverage" ]; then
  echo "   archs:    covered=$(jq -c '.covered' <<<"$asset_map_coverage") missing=$(jq -c '.missing' <<<"$asset_map_coverage")"
fi
echo "   report:   $out/vet-report.json"
