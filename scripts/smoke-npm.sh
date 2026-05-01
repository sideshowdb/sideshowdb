#!/usr/bin/env bash
# smoke-npm.sh — install published @sideshowdb/core + @sideshowdb/effect from the
# npm registry into a throwaway directory and verify the packages import cleanly.
#
# Usage:
#   smoke-npm.sh <expected-version> [<dist-tag>]
#
# dist-tag defaults to "latest" for stable, "next" for prereleases (auto-detected).

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <expected-version> [<dist-tag>]" >&2
  exit 64
fi

version="$1"
if [[ $# -ge 2 ]]; then
  dist_tag="$2"
elif [[ "$version" == *-* ]]; then
  dist_tag="next"
else
  dist_tag="latest"
fi

work_dir="$(mktemp -d -t sideshowdb-smoke-npm.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

echo "==> smoke-npm: version=$version dist-tag=$dist_tag work_dir=$work_dir"

cd "$work_dir"

cat >package.json <<EOF
{
  "name": "sideshowdb-smoke-npm",
  "private": true,
  "type": "module"
}
EOF

# Wait for the packages to be visible on the registry. CI may invoke this
# right after publish; npm CDN propagation can take a minute.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if npm view "@sideshowdb/core@$version" version >/dev/null 2>&1 \
     && npm view "@sideshowdb/effect@$version" version >/dev/null 2>&1; then
    break
  fi
  echo "smoke-npm: waiting for @sideshowdb/[email protected]$version on registry (attempt $attempt)…"
  sleep 15
done

npm install --no-audit --no-fund --silent \
  "@sideshowdb/core@$version" \
  "@sideshowdb/effect@$version"

actual_core="$(node -p "require('@sideshowdb/core/package.json').version")"
actual_effect="$(node -p "require('@sideshowdb/effect/package.json').version")"

if [[ "$actual_core" != "$version" ]]; then
  echo "smoke-npm FAIL: @sideshowdb/core resolved $actual_core, expected $version" >&2
  exit 1
fi
if [[ "$actual_effect" != "$version" ]]; then
  echo "smoke-npm FAIL: @sideshowdb/effect resolved $actual_effect, expected $version" >&2
  exit 1
fi

node --input-type=module -e "
import * as core from '@sideshowdb/core';
import * as effect from '@sideshowdb/effect';
const coreKeys = Object.keys(core).sort();
const effectKeys = Object.keys(effect).sort();
if (coreKeys.length === 0) throw new Error('@sideshowdb/core exported no symbols');
if (effectKeys.length === 0) throw new Error('@sideshowdb/effect exported no symbols');
console.log('smoke-npm: @sideshowdb/core exports:', coreKeys.length);
console.log('smoke-npm: @sideshowdb/effect exports:', effectKeys.length);
"

echo "smoke-npm: OK"
