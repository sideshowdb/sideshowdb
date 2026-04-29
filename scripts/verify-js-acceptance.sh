#!/usr/bin/env bash
set -euo pipefail

wipe_generated_outputs() {
  rm -rf acceptance/typescript/dist
  rm -f zig-out/wasm/sideshowdb.wasm
  rm -rf bindings/typescript/sideshowdb-core/dist
  rm -rf bindings/typescript/sideshowdb-effect/dist
}

wipe_generated_outputs
bun run acceptance

wipe_generated_outputs
zig build js:acceptance
