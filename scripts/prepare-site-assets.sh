#!/usr/bin/env bash
set -euo pipefail

zig build wasm -Doptimize=ReleaseSafe
mkdir -p site/static/wasm
cp -f zig-out/wasm/sideshowdb.wasm site/static/wasm/sideshowdb.wasm
