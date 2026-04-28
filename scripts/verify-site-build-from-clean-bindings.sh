#!/usr/bin/env bash
set -euo pipefail

rm -rf bindings/typescript/sideshowdb-core/dist
rm -rf bindings/typescript/sideshowdb-effect/dist

zig build site:build

test -f bindings/typescript/sideshowdb-core/dist/index.js
test -f bindings/typescript/sideshowdb-core/dist/index.d.ts
test -f bindings/typescript/sideshowdb-effect/dist/index.js
test -f bindings/typescript/sideshowdb-effect/dist/index.d.ts
