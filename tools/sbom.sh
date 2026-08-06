#!/usr/bin/env bash
# Generate a CycloneDX 1.5 SBOM (JSON, stdout) for pozeiden.
#
# Scope: the transitive Zig dependencies statically compiled into the shipped
# binary, from build.zig.zon2json-lock (name, pinned source URL with commit,
# SRI hash). pozeiden invokes no subprocesses and vendors nothing else, so
# compiled-in deps are the whole story. The build toolchain itself (zig, glibc)
# is pinned by flake.lock and published on FlakeHub; a full build-environment
# closure SBOM (e.g. sbomnix) is intentionally out of scope — it would describe
# the CI machine, not the artifact users actually run.
#
# Usage: tools/sbom.sh > sbom.cdx.json
#   Requires jq. Run from anywhere; the script cd's to the repo root.
set -euo pipefail

cd "$(dirname "$0")/.."

LOCK=build.zig.zon2json-lock
[ -f "$LOCK" ] || { echo "missing $LOCK (regenerate with zon2json-lock)" >&2; exit 1; }

VERSION="$(sed -n 's/^\s*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg version "$VERSION" \
  --arg commit "$COMMIT" \
  --arg timestamp "$TIMESTAMP" \
  --slurpfile lock "$LOCK" \
  '
  # Compiled-in Zig deps. A lock key looks like "name-1.2.3-<fingerprint>".
  # Emit a pkg:github purl when the source is a GitHub URL (so CVE scanners can
  # resolve it), else pkg:generic.
  def zig_components:
    $lock[0]
    | to_entries
    | sort_by(.key)
    | map(
        ((.key | capture("^(?<n>.+?)-(?<v>[0-9][^-]*)-(?<fp>.+)$")?) // {v: "unknown"}) as $kv
        | ((.value.url | capture("github\\.com/(?<o>[^/?#]+)/(?<r>[^/?#.]+)")?) // null) as $gh
        | {
            type: "library",
            "bom-ref": .key,
            name: .value.name,
            version: $kv.v,
            purl: (if $gh then "pkg:github/" + $gh.o + "/" + $gh.r + "@" + $kv.v
                   else "pkg:generic/" + .value.name + "@" + $kv.v end),
            externalReferences: [ { type: "vcs", url: .value.url } ],
            properties: [
              { name: "pozeiden:dependency-kind", value: "compiled-in" },
              { name: "nix:sri-hash", value: .value.hash },
              { name: "zig:package-id", value: .key }
            ]
          }
      );

  zig_components as $all
  | ("pozeiden@" + $version) as $root
  | {
      bomFormat: "CycloneDX",
      specVersion: "1.5",
      version: 1,
      metadata: {
        timestamp: $timestamp,
        component: {
          type: "library",
          "bom-ref": $root,
          name: "pozeiden",
          version: $version,
          description: "Mermaid-compatible diagram-to-SVG renderer in Zig",
          externalReferences: [
            { type: "vcs", url: ("https://github.com/sc2in/pozeiden/tree/" + $commit) }
          ]
        },
        properties: [
          { name: "pozeiden:git-commit", value: $commit },
          { name: "pozeiden:sbom-scope", value: "compiled-in-zig-deps" }
        ]
      },
      components: $all,
      dependencies: [
        { ref: $root, dependsOn: ($all | map(.["bom-ref"])) }
      ]
    }
  '
