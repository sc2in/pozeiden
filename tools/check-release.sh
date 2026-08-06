#!/usr/bin/env bash
# Release-tag guards, runnable locally (`bash tools/check-release.sh v0.4.0`)
# and in CI (`nix run .#check-release -- "$tag"`). Two checks:
#   1. CHANGELOG.md changed since the previous release tag (so a release always
#      documents itself). Skipped when there is no previous tag (first release).
#   2. The version stamped in build.zig.zon matches the tag, so the released
#      binary can never disagree with the tag it was cut from.
# `::error::` lines are GitHub Actions annotations; harmless when run locally.
set -euo pipefail

tag="${1:?usage: check-release.sh <tag>}"
version="${tag#v}"
status=0

# 1. CHANGELOG updated since the previous release tag.
prev="$(git describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)"
if [ -z "$prev" ]; then
  echo "No previous tag before $tag; skipping CHANGELOG check."
elif git diff --quiet "$prev" "$tag" -- CHANGELOG.md; then
  echo "::error::CHANGELOG.md has no changes between $prev and $tag. Update the changelog (e.g. 'nix run .#bump') before releasing."
  status=1
else
  echo "CHANGELOG.md updated since $prev ✓"
fi

# 2. Version stamped in build.zig.zon matches the tag.
zon_version="$(grep -oP '\.version = "\K[^"]+' build.zig.zon | head -1)"
if [ "$zon_version" != "$version" ]; then
  echo "::error::Version drift: tag=$version, build.zig.zon=$zon_version. Run 'nix run .#bump' and commit before tagging."
  status=1
else
  echo "Version $version is stamped in build.zig.zon ✓"
fi

exit "$status"
