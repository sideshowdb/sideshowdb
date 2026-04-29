#!/usr/bin/env bash
set -euo pipefail

rm -rf dist/npm

SIDESHOWDB_JS_RELEASE_VERSION=0.0.0 zig build js:release-prepare

test -f dist/npm/sideshowdb-core/package.json
test -f dist/npm/sideshowdb-effect/package.json
test -f dist/npm/sideshowdb-core/README.md
test -f dist/npm/sideshowdb-effect/README.md
test -f dist/npm/sideshowdb-core/LICENSE
test -f dist/npm/sideshowdb-effect/LICENSE
if find dist/npm -path '*.test.*' | grep -q .; then
  echo "release staging should not include test artifacts" >&2
  exit 1
fi

node <<'EOF'
const fs = require('node:fs')
const path = require('node:path')

for (const dir of ['sideshowdb-core', 'sideshowdb-effect']) {
  const root = path.join('dist', 'npm', dir)
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))

  if (!pkg.description) {
    throw new Error(`${dir} missing description`)
  }

  if (!pkg.repository?.url) {
    throw new Error(`${dir} missing repository url`)
  }

  if (!pkg.publishConfig || pkg.publishConfig.access !== 'public') {
    throw new Error(`${dir} missing public publishConfig`)
  }

  if (!Array.isArray(pkg.files) || !pkg.files.includes('dist')) {
    throw new Error(`${dir} missing files whitelist`)
  }

  if (pkg.dependencies?.['@sideshowdb/core'] === 'workspace:*') {
    throw new Error(`${dir} still exposes workspace dependency`)
  }
}
EOF

npm publish --dry-run dist/npm/sideshowdb-core
npm publish --dry-run dist/npm/sideshowdb-effect

rg -n "Publish TypeScript bindings|js:release-prepare|npm publish --provenance --access public dist/npm/" .github/workflows/release.yml
