#!/usr/bin/env bash
set -euo pipefail

test -f package.json
grep -q '"workspaces"' package.json
test -f tsconfig.base.json
test -f bindings/typescript/sideshowdb-core/package.json
test -f bindings/typescript/sideshowdb-effect/package.json
test -f bindings/typescript/sideshowdb-core/tsconfig.json
test -f bindings/typescript/sideshowdb-effect/tsconfig.json
test -f bindings/typescript/sideshowdb-core/src/index.ts
test -f bindings/typescript/sideshowdb-effect/src/index.ts
test -f docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md

node -e "const site = JSON.parse(require('fs').readFileSync('site/package.json', 'utf8')); process.exit(site.dependencies?.['@sideshowdb/core'] === 'workspace:*' ? 0 : 1)"

bun run check
rm -f zig-out/wasm/sideshowdb.wasm
rm -rf bindings/typescript/sideshowdb-core/dist
rm -rf bindings/typescript/sideshowdb-effect/dist
bun run test
rm -f zig-out/wasm/sideshowdb.wasm
rm -rf bindings/typescript/sideshowdb-core/dist
rm -rf bindings/typescript/sideshowdb-effect/dist
zig build js:test
