#!/usr/bin/env bash
set -euo pipefail

ensure_wasm_artifact() {
  if [ ! -f zig-out/wasm/sideshowdb.wasm ]; then
    zig build wasm
  fi
}

ensure_binding_outputs() {
  local missing=0

  for path in \
    bindings/typescript/sideshowdb-core/dist/index.js \
    bindings/typescript/sideshowdb-core/dist/index.d.ts \
    bindings/typescript/sideshowdb-effect/dist/index.js \
    bindings/typescript/sideshowdb-effect/dist/index.d.ts
  do
    if [ ! -f "$path" ]; then
      missing=1
    fi
  done

  if [ "$missing" -eq 1 ]; then
    bun run build:bindings
  fi
}
