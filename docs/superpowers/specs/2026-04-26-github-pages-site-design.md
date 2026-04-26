# Sideshowdb GitHub Pages Site Design

Date: 2026-04-26
Status: Proposed
Issue: `sideshowdb-oob`

## Summary

Sideshowdb needs a GitHub Pages site that combines three jobs in one
experience:

- present the project to developers who are evaluating it
- provide hand-authored documentation and getting-started guides
- offer an in-browser playground that explains the system using real public
  GitHub repositories

The first release should optimize for static hosting simplicity, conceptual
clarity, and a stronger visual identity than a generic documentation site.

## Goals

- Give evaluators a clear answer to "what is Sideshowdb?" within the first
  screen.
- Let evaluators try the core idea quickly through a guided, read-only
  playground.
- Publish authored docs and generated Zig reference docs in one coherent site.
- Keep the deployment fully static so it can ship on GitHub Pages.
- Reuse the repo's existing `wasm` target as the browser-facing runtime for the
  playground where practical.

## Non-Goals

- Private repository access in the first release
- Browser-side write operations back to GitHub in the first release
- A custom backend, API proxy, or token exchange service
- Replacing Zig-generated API docs with hand-maintained reference content
- Building a fully generic "any Git host" playground before the GitHub-first
  experience is validated

## Product Decisions

### Audience

The first release targets developers who are evaluating the project, not users
already committed to building on top of it.

### Documentation Model

The site uses a hybrid docs model:

- SveltePress owns the product pages, guides, tutorials, install docs, and
  concept explanations.
- Zig-generated docs remain the authoritative API and low-level reference.
- The site links to or embeds the generated reference section as a distinct
  `Reference` area.

### Playground Scope

The first release playground is:

- browser-only
- read-only
- limited to public GitHub repositories
- optimized to teach the system's model, not to expose every underlying Git
  primitive

### Visual Direction

The site should follow the `Graph Atlas` visual direction:

- airy blue-gray and pale mineral palette
- diagram-like shapes and relationship motifs
- a systems-map feel instead of a generic startup gradient or plain docs theme
- stronger editorial hierarchy than a default docs template

### Homepage Composition

The homepage should use a `Hero + Immediate Playground` flow:

1. explain the value proposition in one sentence
2. present a primary `Try Playground` call to action immediately
3. expose a lightweight public repo entry point in or near the hero
4. follow with concise conceptual explanation and then deeper docs entry points

## Information Architecture

The site has four top-level surfaces:

- `Home`
- `Docs`
- `Playground`
- `Reference`

### Home

The homepage is evaluator-first and should contain:

1. Hero with value proposition, primary CTA, and visible repo entry affordance
2. "Why this is different" section that explains Git as source of truth and
   projections as derived views
3. Core concept cards for events, refs, projections, and local-first operation
4. Featured example repo path for users who want a known-good starting point
5. Clear routes into authored docs and generated reference docs

### Docs

The docs section should contain:

- install and quickstart content
- conceptual guides for the Git-backed model
- walkthroughs that connect repo data to Sideshowdb concepts
- examples and tutorials
- links out to generated reference docs when deeper API detail is needed

### Playground

The playground section is the full interactive experience. It should support:

- a curated sample repo entry point
- custom `owner/repo` input for public GitHub repositories
- guided inspection of a repo through a small set of high-value views
- explanatory copy that maps GitHub/Git data to Sideshowdb concepts

### Reference

The reference section publishes Zig-generated documentation as the
authoritative, refreshable low-level API reference.

## Playground Experience

### User Flow

1. The user lands on the homepage or `Playground`.
2. The user either selects a featured public repo or enters `owner/repo`.
3. The client validates the input format before any fetch.
4. The browser fetches public GitHub data directly.
5. The UI renders a guided explorer with parallel explanatory views.
6. The user can switch among a small number of focused inspection modes.

### Views

The first release should emphasize explanation over exhaustiveness. The UI
should present a small number of focused views, such as:

- source data view for refs and selected repository structures
- Sideshowdb interpretation view for derived documents or projections
- explanatory panel that narrates what the user is seeing and why it matters

The first release should avoid becoming a generic Git object browser.

### Input Model

The primary input should be a public GitHub repository in `owner/repo` form.
The UI may additionally expose a small list of curated example repos to reduce
blank-page friction.

### Failure Handling

The playground must fail gracefully when:

- the repo input is malformed
- the repository does not exist
- the repository is inaccessible
- the repository shape is unsupported by the first-release demo
- GitHub rate limits or network failures block fetches

In each case the UI should explain what happened in plain language and offer a
next step, such as correcting the input or trying a sample repo.

## Technical Architecture

### Site Workspace

The site should live in a dedicated web workspace inside the repo. That
workspace should own:

- SveltePress configuration
- authored site pages and docs
- playground UI components and state management
- the integration layer that connects browser UI code to the compiled WASM
  module

### WASM Integration

The browser playground should consume the repo's `wasm` build output. The site
workspace should not duplicate core domain logic in TypeScript unless that logic
is purely presentational or integration-oriented.

Expected responsibilities:

- Zig/WASM handles reusable browser-facing domain logic where practical.
- TypeScript/Svelte code handles GitHub fetches, input validation presentation,
  routing, state transitions, and explanatory UI composition.

### Reference Docs Publication

The publish flow should generate Zig docs during the site build and then place
the resulting reference output under the Pages artifact in a stable location
such as `/reference/`.

The authored docs should treat generated reference docs as a sibling section,
not an afterthought or an external disconnected experience.

## Deployment

The site should deploy through GitHub Pages using GitHub Actions.

The publish workflow should produce one assembled static artifact containing:

- the SveltePress site output
- the generated Zig reference docs
- the compiled browser playground assets
- the compiled `sideshowdb.wasm` artifact and any required browser glue

The deployment must not require a long-running service or runtime secrets for
the first release.

## Content And Messaging

The homepage message should emphasize these ideas:

- Git is the source of truth
- events and refs drive state
- documents and graphs are derived views
- local-first and Git-native workflows can coexist

The tone should feel technically serious and visually distinct, not like a
placeholder product page or a stock template.

## EARS Requirements

The following user-facing requirements define the first-release behavior.

1. The Sideshowdb site shall present top-level navigation entries for `Home`,
   `Docs`, `Playground`, and `Reference`.
2. When a user loads the homepage, the Sideshowdb site shall present a primary
   `Try Playground` call to action without requiring the user to scroll.
3. When a user loads the homepage, the Sideshowdb site shall present a concise
   explanation that Git is the source of truth and that Sideshowdb derives
   higher-level views from repository data.
4. When a user opens the playground, the Sideshowdb site shall allow the user
   to inspect a curated sample public repository without authentication.
5. When a user enters a repository in `owner/repo` format, the Sideshowdb site
   shall validate the input before attempting to fetch GitHub data.
6. If a user enters malformed repository input, then the Sideshowdb site shall
   present a specific validation error and shall not attempt a GitHub fetch.
7. When a user enters a valid public repository, the Sideshowdb site shall
   fetch repository data directly from GitHub in the browser without requiring
   sign-in.
8. If GitHub reports that the repository does not exist or is inaccessible, then
   the Sideshowdb site shall present a plain-language error and offer a fallback
   sample repository path.
9. If the selected repository is unsupported by the first-release playground,
   then the Sideshowdb site shall explain the limitation and shall offer a
   supported sample repository.
10. While the first-release playground is active, the Sideshowdb site shall not
    offer UI that implies write-back, branch mutation, or authenticated private
    repository access.
11. When reference docs are generated during site publication, the Sideshowdb
    site shall publish them under the static Pages artifact as the authoritative
    low-level reference.
12. If generated reference docs are unavailable during publication, then the
    publish workflow shall fail rather than deploying a partial `Reference`
    section silently.

## Testing Strategy

The implementation plan should include tests for:

- static site build success
- Zig reference docs generation and assembly into the final Pages artifact
- WASM asset generation and inclusion in the final Pages artifact
- homepage CTA visibility and navigation behavior
- curated sample repo flow
- valid custom repo flow
- malformed input validation
- missing repository and inaccessible repository errors
- unsupported repository fallback behavior
- negative cases around missing generated artifacts in CI

The coverage should include happy path, negative path, and boundary conditions
for repo input handling and artifact assembly.

## Rollout

The first release should ship as a static GitHub Pages deployment with public
repos only. Private repo access, browser auth, and write flows can be evaluated
later as separate design and implementation tracks after the read-only public
experience proves valuable.

## Follow-Up Work Expected

Implementation will likely need separate tasks for:

- scaffolding the web workspace and SveltePress configuration
- designing the homepage and shared visual system
- integrating the Zig docs publication flow
- integrating the WASM artifact into the site build
- implementing the public repo playground flow
- adding CI and Pages deployment
- defining curated sample repositories and explanatory content
