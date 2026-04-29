#!/usr/bin/env bash
set -euo pipefail

source scripts/ensure-js-workspace-prereqs.sh

ensure_binding_outputs

bun run check:raw
