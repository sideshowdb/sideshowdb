#!/usr/bin/env bash
set -euo pipefail

if ! output="$(zig build site:build 2>&1)"; then
  printf '%s\n' "$output"
  exit 1
fi
printf '%s\n' "$output"

if grep -q '\[404\] GET /reference/api/' <<<"$output"; then
  printf '%s\n' "site build emitted a /reference/api/ 404" >&2
  exit 1
fi
