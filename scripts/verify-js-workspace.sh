#!/usr/bin/env bash
set -euo pipefail

test -f package.json
grep -q '"workspaces"' package.json
test -f tsconfig.base.json
test -f bindings/typescript/sideshowdb-core/package.json
test -f bindings/typescript/sideshowdb-effect/package.json
test -f bindings/typescript/sideshowdb-core/tsconfig.json
test -f bindings/typescript/sideshowdb-effect/tsconfig.json
test -f docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md
