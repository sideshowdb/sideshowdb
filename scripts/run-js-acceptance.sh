#!/usr/bin/env bash
set -euo pipefail

source scripts/ensure-js-workspace-prereqs.sh

ensure_wasm_artifact
ensure_binding_outputs

if [ ! -f zig-out/bin/sideshowdb ]; then
  zig build
fi

bun run build:acceptance
bun run acceptance:raw "$@"
