#!/usr/bin/env bash
set -euo pipefail

rm -rf dist/pages
mkdir -p dist/pages
cp -rf site/dist/. dist/pages/
test -f dist/pages/reference/index.html
test -f dist/pages/wasm/sideshowdb.wasm
