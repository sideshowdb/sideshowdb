---
title: Getting Started
order: 1
---

# Getting Started

Install Zig 0.16 and Bun, then use the repo in two parallel ways: build the core
database with Zig and explore the docs site and playground with Bun.

The shortest path is:

1. Clone the repo.
2. Run `zig build` to build the CLI.
3. Run `zig build wasm` to build the browser runtime.
4. Run `cd site && bun install --frozen-lockfile`.
5. Run `cd site && bun run dev` while iterating on the site.

For a full static Pages artifact, use:

1. `bash scripts/prepare-site-assets.sh`
2. `bash scripts/build-zig-docs.sh`
3. `cd site && bun run build`
4. `cd .. && bash scripts/assemble-pages-artifact.sh`

That flow stages the WASM artifact, emits Zig reference docs, builds the
SveltePress site shell, and assembles the final `dist/pages/` output.
