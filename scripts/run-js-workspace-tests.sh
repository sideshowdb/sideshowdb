#!/usr/bin/env bash
set -euo pipefail

source scripts/ensure-js-workspace-prereqs.sh

ensure_wasm_artifact
ensure_binding_outputs

bun run test:raw
