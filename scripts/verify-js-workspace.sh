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

bun run --cwd bindings/typescript/sideshowdb-core build
bun run --cwd bindings/typescript/sideshowdb-effect build
bun run --cwd bindings/typescript/sideshowdb-core test
bun run --cwd bindings/typescript/sideshowdb-effect test
