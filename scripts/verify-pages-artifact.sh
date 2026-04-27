#!/usr/bin/env bash
set -euo pipefail

test -f dist/pages/index.html
test -f dist/pages/reference/index.html
test -f dist/pages/wasm/sideshowdb.wasm
