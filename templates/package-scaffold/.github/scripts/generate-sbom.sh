#!/usr/bin/env bash
# generate-sbom.sh - emit an SPDX 2.3 SBOM for a build, published alongside
# the .deb/.dsc release assets and signed by actions/attest-sbom.
#
# Derived entirely from provenance.json (generate-provenance.sh runs first),
# so there is exactly one place the build's facts are collected and the SBOM
# can never disagree with the provenance document beside it.
#
# SCOPE, stated plainly because an SBOM that overstates its coverage is worse
# than none: this documents the SHIPPED ARTIFACTS and the UPSTREAM RELEASE
# THEY WERE PACKAGED FROM - names, versions, licenses, checksums, and the CI
# run that produced them. It does NOT enumerate the upstream's transitive
# dependency graph; these packages repackage prebuilt upstream binaries, and
# the dependency-tree work is unbuilt (see PLATFORM-EVALUATION.md's
# "Dependency-tree multiplier"). The document says so in its comment field
# rather than letting a consumer infer coverage that isn't there.
#
# Requirements: jq. Reads provenance.json, writes sbom.spdx.json.

set -euo pipefail

IN="${IN:-provenance.json}"
OUT="${OUT:-sbom.spdx.json}"
[ -f "$IN" ] || { echo "::error::$IN not found - run generate-provenance.sh first" >&2; exit 1; }

# SPDX requires a globally unique document namespace. The release tag plus the
# CI run id is unique per build without needing a UUID generator.
NAMESPACE="https://github.com/$(jq -r '.build.repo // "latest-debs/unknown"' "$IN")/spdx/$(jq -r '.release_tag' "$IN")-$(jq -r '.build.run_id // "local"' "$IN")"

jq --arg ns "$NAMESPACE" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  # SPDX ids may only contain letters, digits, "." and "-".
  def spdxid: tostring | gsub("[^A-Za-z0-9.-]"; "-");

  .        as $p
  | ($p.upstream_pin // {})            as $up
  | ($up.license // "NOASSERTION")     as $lic
  | ($up.upstream_repo // "")          as $urepo
  # Debian version, not the upstream tag: the shipped files are
  # <pkg>_3.11.2-1+<suite>_<arch>.deb, so the leading "v" has to go.
  | ("\($p.version | sub("^v"; ""))-\($p.build_version)") as $fullver
  | ($p.artifacts | to_entries)        as $arts
  | {
      spdxVersion: "SPDX-2.3",
      dataLicense: "CC0-1.0",
      SPDXID: "SPDXRef-DOCUMENT",
      name: "\($p.package)-\($p.release_tag)",
      documentNamespace: $ns,
      creationInfo: {
        created: $created,
        creators: [
          "Organization: latest-debs",
          "Tool: latest-debs-generate-sbom.sh"
        ]
      },
      comment: ("Covers the shipped Debian artifacts and the upstream release they were "
                + "packaged from. Does NOT enumerate the transitive dependency graph of "
                + "that upstream. Build: \($p.build.run_url // "unknown")"),
      packages: ([
        {
          SPDXID: "SPDXRef-Package-\($p.package | spdxid)",
          name: $p.package,
          versionInfo: $fullver,
          downloadLocation: (
            if $p.build.repo != "" and $p.build.repo != null
            then "https://github.com/\($p.build.repo)/releases/tag/\($p.release_tag)"
            else "NOASSERTION" end),
          filesAnalyzed: false,
          licenseConcluded: $lic,
          licenseDeclared: $lic,
          supplier: "Organization: latest-debs",
          externalRefs: [{
            referenceCategory: "PACKAGE-MANAGER",
            referenceType: "purl",
            referenceLocator: "pkg:deb/debian/\($p.package)@\($fullver)"
          }]
        }
      ] + (if $urepo != "" then [
        {
          SPDXID: "SPDXRef-Upstream",
          name: $urepo,
          versionInfo: ($up.tag // "NOASSERTION"),
          downloadLocation: (
            if $up.asset != null and $up.asset != ""
            then "https://github.com/\($urepo)/releases/download/\($up.tag)/\($up.asset)"
            else "https://github.com/\($urepo)" end),
          filesAnalyzed: false,
          licenseConcluded: $lic,
          licenseDeclared: $lic,
          supplier: ("Organization: " + ($urepo | split("/")[0])),
          # The vet-time pin: the exact upstream bytes this build verified
          # against, which is the whole point of recording it here.
          checksums: (if ($up.sha256 // "") != ""
                      then [{algorithm: "SHA256", checksumValue: $up.sha256}]
                      else [] end),
          externalRefs: [{
            referenceCategory: "PACKAGE-MANAGER",
            referenceType: "purl",
            referenceLocator: "pkg:github/\($urepo)@\($up.tag // "")"
          }]
        }
      ] else [] end)),
      files: [ $arts[] | {
        SPDXID: "SPDXRef-File-\(.key | spdxid)",
        fileName: "./\(.key)",
        checksums: [{algorithm: "SHA256", checksumValue: .value}],
        licenseConcluded: $lic
      } ],
      relationships: ([
        {
          spdxElementId: "SPDXRef-DOCUMENT",
          relationshipType: "DESCRIBES",
          relatedSpdxElement: "SPDXRef-Package-\($p.package | spdxid)"
        }
      ] + (if $urepo != "" then [
        {
          spdxElementId: "SPDXRef-Package-\($p.package | spdxid)",
          relationshipType: "GENERATED_FROM",
          relatedSpdxElement: "SPDXRef-Upstream"
        }
      ] else [] end) + [ $arts[] | {
        spdxElementId: "SPDXRef-Package-\($p.package | spdxid)",
        relationshipType: "CONTAINS",
        relatedSpdxElement: "SPDXRef-File-\(.key | spdxid)"
      } ])
    }
' "$IN" > "$OUT"

echo "→ wrote $OUT ($(jq '.files | length' "$OUT") file(s), $(jq '.packages | length' "$OUT") package(s))"
