#!/usr/bin/env bash
set -euo pipefail

test -f site/package.json
test -f site/tsconfig.json
test -f site/svelte.config.js
test -f site/vite.config.ts
test -f site/src/app.d.ts
test -f site/src/routes/+layout.svelte
test -f site/src/routes/+layout.ts
test -f site/src/routes/+page.svelte
test -f site/static/favicon.svg
