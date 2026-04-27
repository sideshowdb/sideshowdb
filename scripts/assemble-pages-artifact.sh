#!/usr/bin/env bash
set -euo pipefail

rm -rf dist/pages
mkdir -p dist/pages
cp -rf site/dist/. dist/pages/
mkdir -p dist/pages/reference
cp -rf .build/reference/. dist/pages/reference/
mkdir -p dist/pages/wasm
cp -f site/static/wasm/sideshowdb.wasm dist/pages/wasm/sideshowdb.wasm
