#!/usr/bin/env bash
set -euo pipefail

rm -rf acceptance/typescript/dist
rm -f zig-out/wasm/sideshowdb.wasm
rm -rf bindings/typescript/sideshowdb-core/dist
rm -rf bindings/typescript/sideshowdb-effect/dist

bun run acceptance
zig build js:acceptance
