#!/usr/bin/env bash
# smoke-release-local.sh — pre-tag local release gate.
#
# Builds the CLI + WASM at the requested version, runs the smoke CLI surface
# checks, the JS workspace tests, the JS acceptance suite, and the npm release
# staging dry run. Mirrors what CI will do after the tag push.
#
# Usage:
#   smoke-release-local.sh <version>

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

version="$1"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "==> [1/5] zig build (-Dversion=$version)"
zig build -Dversion="$version" -Doptimize=ReleaseSafe

echo "==> [2/5] smoke-cli (zig-out/bin/sideshow @ $version)"
bash scripts/smoke-cli.sh zig-out/bin/sideshow "$version"

echo "==> [3/5] zig build test"
zig build test -Doptimize=ReleaseSafe

echo "==> [4/5] zig build js:acceptance"
zig build js:acceptance -Doptimize=ReleaseSafe

echo "==> [5/5] npm publish dry run"
SIDESHOWDB_JS_RELEASE_VERSION="$version" zig build js:release-prepare -Dversion="$version"
npm publish --dry-run dist/npm/sideshowdb-core
npm publish --dry-run dist/npm/sideshowdb-effect

echo "smoke-release-local: OK at version $version"
