# Docs Site Pages EARS

## Purpose

This specification captures the acceptance expectations for the
rendered docs site pages under
[`site/src/routes/docs/`](../../../site/src/routes/docs). The page
sources themselves are intentionally free of EARS blockquotes; this
file is the canonical home for those acceptance statements so internal
process notes do not bleed into user-facing documentation.

Each section below names the page it covers and lists the EARS
statements it must satisfy. New requirements added here must land
alongside an update to the rendered page so the two stay in lockstep.

## Getting Started

Page: [`docs/getting-started/+page.md`](../../../site/src/routes/docs/getting-started/+page.md)

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

## Architecture

Page: [`docs/architecture/+page.md`](../../../site/src/routes/docs/architecture/+page.md)

The system under discussion is the `Architecture docs page`.

1. The Architecture docs page shall explain events, refs,
   projections, and local-first operation as derived views over Git.

## Concepts

Page: [`docs/concepts/+page.md`](../../../site/src/routes/docs/concepts/+page.md)

The system under discussion is the `Concepts docs page`.

1. The Concepts docs page shall provide a Concept-to-Reference
   cross-link for each concept it introduces, pointing to the relevant
   generated `/reference/` symbol.

## Projection Walkthrough

Page: [`docs/projection-walkthrough/+page.md`](../../../site/src/routes/docs/projection-walkthrough/+page.md)

The system under discussion is the `Projection Walkthrough docs page`.

1. The Projection Walkthrough docs page shall map a real public
   repository to Sideshowdb concepts step by step.

## Playground Guide

Page: [`docs/playground/+page.md`](../../../site/src/routes/docs/playground/+page.md)

The system under discussion is the `Sideshowdb site` (playground
surface) as described by the Playground Guide.

1. When a user opens the playground, the Sideshowdb site shall allow
   the user to inspect a curated sample public repository without
   authentication.
2. While the first-release playground is active, the Sideshowdb site
   shall not offer UI that implies write-back, branch mutation, or
   authenticated private repository access.
3. When a user enters a repository in `owner/repo` format, the
   Sideshowdb site shall validate the input before attempting to
   fetch GitHub data.
4. If a user enters malformed repository input, then the Sideshowdb
   site shall present a specific validation error and shall not
   attempt a GitHub fetch.
5. If GitHub reports that the repository does not exist or is
   inaccessible, then the Sideshowdb site shall present a
   plain-language error and offer a fallback sample repository path.

## Mapping to Tests

The docs pages are verified by the docs build (svelte-check) and by
the install/test commands they document. Playground requirements are
additionally exercised by tests under
[`site/src/routes/`](../../../site/src/routes) and
[`site/src/lib/playground/`](../../../site/src/lib/playground).
