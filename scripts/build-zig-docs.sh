#!/usr/bin/env bash
set -euo pipefail

rm -rf .build/reference
mkdir -p .build/reference
zig test src/core/root.zig -femit-docs=.build/reference -fno-emit-bin
