# Getting Started Docs Page EARS

## Purpose

This specification captures the acceptance expectations for the public
[Getting Started](../../site/src/routes/docs/getting-started/+page.md)
page. The page is the first end-to-end touch point for a user
evaluating sideshowdb, so the requirements pin the install paths,
prerequisites, and verifiable example it must offer.

These requirements are reflected by the rendered docs page; the
rendered page itself is intentionally free of EARS bleed-through.

## Requirements

The system under discussion is the `Getting Started docs page`.

1. The Getting Started docs page shall list at least two install paths
   for the CLI: a release-binary path and a build-from-source path.
2. The Getting Started docs page shall describe the release-binary
   path without requiring a Zig toolchain or other source-build
   prerequisites.
3. When a reader follows the build-from-source path, the Getting
   Started docs page shall declare the toolchain prerequisites
   (Zig 0.16, Bun for the docs site, Git) before the build commands.
4. The Getting Started docs page shall include at least one
   verifiable end-to-end example that puts a document and reads it
   back through the installed CLI.
5. The Getting Started docs page shall link to the Architecture,
   Concepts, Projection Walkthrough, and Playground Guide pages from
   a "Next Steps" section.
6. If a reader runs the documented test commands, then the Getting
   Started docs page shall surface the same gates CI enforces
   (`zig build test`, `zig build checkCoreDocs`, `zig fmt --check`).

## Mapping to Tests

The Getting Started page is verified by the docs build (svelte-check)
and by the install/test commands it documents. New requirements added
here must land alongside an update to the rendered page so the two
stay in lockstep.
