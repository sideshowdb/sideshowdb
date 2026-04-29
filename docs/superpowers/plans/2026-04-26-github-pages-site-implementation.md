# GitHub Pages Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a static GitHub Pages site for SideshowDB with an evaluator-first homepage, authored docs, generated Zig reference docs, and a browser-only read-only playground for public GitHub repositories.

**Architecture:** Add a dedicated `site/` SveltePress workspace that uses Bun for runtime and package management, keep Zig as the source of truth for the compiled WASM artifact and generated reference docs, and assemble both outputs into a single static Pages artifact in CI. Implement the playground as a thin Svelte/TypeScript shell around public GitHub fetches and the existing Zig WASM exports, with graceful fallback to a curated sample repo.

**Tech Stack:** Zig 0.16, Bun, SvelteKit, SveltePress default theme, TypeScript, Vitest, Testing Library, GitHub Actions, GitHub Pages

---

## File Structure

### Existing files to modify

- Modify: `.gitignore`
  Responsibility: ignore generated site assets and Pages build output.
- Modify: `.github/workflows/ci.yml`
  Responsibility: add Bun-backed site verification to CI.
- Modify: `build.zig`
  Responsibility: optional follow-up only if the implementation chooses to add a first-class Zig docs step instead of shelling out directly. Default plan keeps this file unchanged.
- Modify: `src/wasm/root.zig`
  Responsibility: extend the browser API surface only if the current exports are insufficient for the first release playground.

### New root-level scripts and docs

- Create: `scripts/build-zig-docs.sh`
  Responsibility: run Zig doc generation with `zig test -femit-docs=...`.
- Create: `scripts/prepare-site-assets.sh`
  Responsibility: build the WASM artifact and stage it for the site build.
- Create: `scripts/assemble-pages-artifact.sh`
  Responsibility: merge the site output, Zig reference docs, and WASM artifact into one static directory.
- Create: `scripts/verify-pages-artifact.sh`
  Responsibility: assert the assembled artifact contains homepage, reference docs, and WASM payload.
- Create: `.github/workflows/pages.yml`
  Responsibility: build and deploy GitHub Pages from `main`.

### New Bun + SveltePress workspace

- Create: `site/package.json`
  Responsibility: Bun-managed site dependencies and scripts.
- Create: `site/bun.lock`
  Responsibility: lock Bun dependencies for reproducible CI.
- Create: `site/tsconfig.json`
  Responsibility: TypeScript configuration for the site workspace.
- Create: `site/svelte.config.js`
  Responsibility: static SvelteKit adapter and `.md` route support.
- Create: `site/vite.config.ts`
  Responsibility: SveltePress default theme configuration, navbar, sidebar roots, and base path handling for GitHub Pages.
- Create: `site/src/app.d.ts`
  Responsibility: SveltePress theme type references.
- Create: `site/src/app.css`
  Responsibility: Graph Atlas visual tokens and global styling.
- Create: `site/static/favicon.svg`
  Responsibility: site icon.

### New content and route files

- Create: `site/src/lib/content/nav.ts`
  Responsibility: shared top-level navigation metadata.
- Create: `site/src/lib/content/sample-repos.ts`
  Responsibility: curated public repo list and fallback content.
- Create: `site/src/lib/playground/repo-input.ts`
  Responsibility: parse and validate `owner/repo` input.
- Create: `site/src/lib/playground/github.ts`
  Responsibility: browser-only fetch helpers for public GitHub API calls.
- Create: `site/src/lib/playground/wasm.ts`
  Responsibility: lazy-load and call `sideshowdb.wasm`.
- Create: `site/src/lib/playground/explorer.ts`
  Responsibility: transform fetched GitHub data into the focused explorer view model.
- Create: `site/src/lib/components/HeroRepoForm.svelte`
  Responsibility: homepage CTA and repo entry form.
- Create: `site/src/lib/components/ConceptCardGrid.svelte`
  Responsibility: homepage concept cards.
- Create: `site/src/lib/components/PlaygroundStatus.svelte`
  Responsibility: shared empty, loading, and error states.
- Create: `site/src/lib/components/RepoExplorer.svelte`
  Responsibility: read-only explorer shell.
- Create: `site/src/lib/components/ProjectionPanel.svelte`
  Responsibility: explain SideshowDB interpretation of fetched repo data.
- Create: `site/src/routes/+layout.svelte`
  Responsibility: required root layout for SveltePress plus shared chrome.
- Create: `site/src/routes/+layout.ts`
  Responsibility: prerender and trailing slash behavior.
- Create: `site/src/routes/+page.svelte`
  Responsibility: evaluator-first homepage.
- Create: `site/src/routes/docs/getting-started/+page.md`
  Responsibility: install and quickstart.
- Create: `site/src/routes/docs/concepts/+page.md`
  Responsibility: Git-as-source-of-truth explanation.
- Create: `site/src/routes/docs/playground/+page.md`
  Responsibility: explain public-repo-only playground behavior.
- Create: `site/src/routes/playground/+page.svelte`
  Responsibility: dedicated playground route.

### New tests

- Create: `site/src/lib/playground/repo-input.test.ts`
  Responsibility: happy path, negative, edge, and boundary validation for repo input.
- Create: `site/src/lib/playground/github.test.ts`
  Responsibility: GitHub fetch error mapping and unsupported shape handling.
- Create: `site/src/lib/playground/explorer.test.ts`
  Responsibility: view-model shaping for refs and derived panels.
- Create: `site/src/routes/homepage.test.ts`
  Responsibility: homepage CTA, sample repo affordance, and nav rendering.
- Create: `site/src/routes/playground-page.test.ts`
  Responsibility: sample repo flow, invalid input messaging, and unsupported repo fallback.

## Task 1: Scaffold the Bun + SveltePress workspace

**Files:**
- Create: `scripts/verify-site-workspace.sh`
- Create: `site/package.json`
- Create: `site/tsconfig.json`
- Create: `site/svelte.config.js`
- Create: `site/vite.config.ts`
- Create: `site/src/app.d.ts`
- Create: `site/src/app.html`
- Create: `site/src/routes/+layout.svelte`
- Create: `site/src/routes/+layout.ts`
- Create: `site/src/routes/+page.svelte`
- Create: `site/static/favicon.svg`
- Modify: `.gitignore`
- Test: `scripts/verify-site-workspace.sh`

- [ ] **Step 1: Write the failing workspace verification script**

```bash
#!/usr/bin/env bash
set -euo pipefail

test -f site/package.json
test -f site/tsconfig.json
test -f site/svelte.config.js
test -f site/vite.config.ts
test -f site/src/app.d.ts
test -f site/src/app.html
test -f site/src/routes/+layout.svelte
test -f site/src/routes/+layout.ts
test -f site/src/routes/+page.svelte
test -f site/static/favicon.svg
```

- [ ] **Step 2: Run the verification script to prove the workspace does not exist yet**

Run: `bash scripts/verify-site-workspace.sh`

Expected: FAIL with `test -f ...` on the first missing `site/...` path.

- [ ] **Step 3: Create the Bun workspace and base SveltePress config**

```json
{
  "name": "@sideshowdb/site",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
    "test": "vitest run"
  },
  "devDependencies": {
    "@sveltejs/adapter-static": "^3.0.0",
    "@sveltejs/kit": "^2.0.0",
    "@sveltejs/vite-plugin-svelte": "^6.2.4",
    "@sveltepress/theme-default": "^7.3.2",
    "@sveltepress/vite": "^1.3.11",
    "@testing-library/svelte": "^5.0.0",
    "@types/node": "^24.3.1",
    "jsdom": "^25.0.0",
    "svelte": "^5.0.0",
    "svelte-check": "^4.0.0",
    "typescript": "^5.0.0",
    "vite": "^7.2.4",
    "vitest": "^4.1.5"
  }
}
```

```json
// site/tsconfig.json
{
  "extends": "./.svelte-kit/tsconfig.json",
  "compilerOptions": {
    "allowJs": false,
    "checkJs": false,
    "moduleResolution": "bundler",
    "skipLibCheck": true,
    "strict": true
  }
}
```

```js
// site/svelte.config.js
import adapter from '@sveltejs/adapter-static'
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte'

/** @type {import('@sveltejs/kit').Config} */
const config = {
  extensions: ['.svelte', '.md'],
  preprocess: [vitePreprocess()],
  kit: {
    adapter: adapter({
      pages: 'dist',
      assets: 'dist',
      fallback: '404.html',
    }),
    paths: {
      base: process.env.BASE_PATH ?? '',
      relative: false,
    },
  },
  compilerOptions: {
    runes: true,
  },
}

export default config
```

```ts
// site/vite.config.ts
import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'

export default defineConfig({
  plugins: [
    sveltepress({
      siteConfig: {
        title: 'SideshowDb',
        description: 'Git-backed local-first data, docs, and a public repo playground.',
      },
      theme: defaultTheme({
        navbar: [
          { title: 'Home', to: '/' },
        ],
        github: 'https://github.com/sideshowdb/sideshowdb',
      }),
    }),
  ],
  test: {
    environment: 'jsdom',
    passWithNoTests: true,
  },
})
```

```ts
// site/src/routes/+layout.ts
export const prerender = true
export const trailingSlash = 'always'
```

```svelte
<!-- site/src/routes/+layout.svelte -->
<script lang="ts">
  let { children } = $props()
</script>

{@render children()}
```

```svelte
<!-- site/src/routes/+page.svelte -->
<svelte:head>
  <title>SideshowDb</title>
</svelte:head>
```

```ts
// site/src/app.d.ts
/// <reference types="vite/client" />
/// <reference types="@sveltepress/vite/types" />
/// <reference types="@sveltepress/theme-default/types" />
```

```html
<!-- site/src/app.html -->
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <link rel="icon" href="%sveltekit.assets%/favicon.svg" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    %sveltekit.head%
  </head>
  <body data-sveltekit-preload-data="hover">
    <div style="display: contents">%sveltekit.body%</div>
  </body>
</html>
```

```svg
<!-- site/static/favicon.svg -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <circle cx="18" cy="18" r="8" fill="#1d4955" />
  <circle cx="46" cy="20" r="8" fill="#8fb0bd" />
  <circle cx="30" cy="46" r="8" fill="#96a575" />
  <path d="M23 22 40 20M22 24 28 39M42 26 33 40" stroke="#172228" stroke-width="3" fill="none" />
</svg>
```

```gitignore
# .gitignore
site/node_modules/
site/dist/
site/.svelte-kit/
site/static/wasm/
dist/pages/
```

- [ ] **Step 4: Install dependencies and generate `bun.lock`**

Run: `cd site && bun install`

Expected: PASS and create `site/bun.lock`.

- [ ] **Step 5: Re-run the workspace verification script and confirm the scaffold builds**

Run: `bash scripts/verify-site-workspace.sh`

Expected: PASS with no output.

Run: `cd site && bun run build`

Expected: PASS and emit the site build output under `site/dist/`.

Run: `cd site && bun run test`

Expected: PASS with no tests found, rather than crashing during Vitest startup.

- [ ] **Step 6: Commit the scaffold**

```bash
git add .gitignore scripts/verify-site-workspace.sh site
git commit -m "feat: scaffold Bun SveltePress site workspace"
```

## Task 2: Build the shared site shell, Graph Atlas visual system, and docs pages

**Files:**
- Create: `site/src/app.css`
- Modify: `site/src/app.d.ts`
- Create: `site/src/lib/content/nav.ts`
- Create: `site/src/lib/components/HeroRepoForm.svelte`
- Create: `site/src/lib/components/ConceptCardGrid.svelte`
- Create: `site/src/routes/homepage.test.ts`
- Modify: `site/src/routes/+layout.svelte`
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/vite.config.ts`
- Create: `site/src/routes/docs/getting-started/+page.md`
- Create: `site/src/routes/docs/concepts/+page.md`
- Create: `site/src/routes/docs/playground/+page.md`
- Create: `site/src/routes/playground/+page.svelte`
- Create: `site/src/routes/reference/+page.svelte`
- Test: `site/src/routes/homepage.test.ts`

- [ ] **Step 1: Write the failing homepage test**

```ts
import { render, screen } from '@testing-library/svelte'
import { describe, expect, it } from 'vitest'
import HomePage from './+page.svelte'

describe('homepage', () => {
  it('renders the primary playground CTA above the fold', () => {
    render(HomePage)
    expect(screen.getByRole('link', { name: 'Try Playground' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Use Sample Repo' })).toBeTruthy()
    expect(screen.getByText(/Git is the source of truth/i)).toBeTruthy()
  })
})
```

- [ ] **Step 2: Run the homepage test to confirm it fails for the right reason**

Run: `cd site && bun run test -- src/routes/homepage.test.ts`

Expected: FAIL because the placeholder homepage does not render the CTA or the required explanatory copy.

- [ ] **Step 3: Implement the Graph Atlas shell and evaluator-first homepage**

```ts
// site/src/lib/content/nav.ts
export const topNav = [
  { title: 'Home', href: '/' },
  { title: 'Docs', href: '/docs/getting-started/' },
  { title: 'Playground', href: '/playground/' },
  { title: 'Reference', href: '/reference/' },
] as const
```

```svelte
<!-- site/src/lib/components/HeroRepoForm.svelte -->
<script lang="ts">
  import { base } from '$app/paths'

  export let actionHref = '/playground/'
  export let sampleRepo = 'sideshowdb/sideshowdb'
</script>

<div class="hero-actions">
  <a class="primary" href={`${base}${actionHref}`}>Try Playground</a>
  <a class="secondary" href={`${base}/playground/?repo=${sampleRepo}`}>Use Sample Repo</a>
</div>
```

```svelte
<!-- site/src/lib/components/ConceptCardGrid.svelte -->
<section class="concept-grid">
  <article>
    <h3>Events</h3>
    <p>Track append-only changes instead of overwriting state.</p>
  </article>
  <article>
    <h3>Refs</h3>
    <p>Understand which Git pointers define the active shape of the repository.</p>
  </article>
  <article>
    <h3>Derived Views</h3>
    <p>Project repository data into documents and higher-level read models.</p>
  </article>
</section>
```

```svelte
<!-- site/src/routes/+layout.svelte -->
<script lang="ts">
  import '../app.css'
  let { children } = $props()
</script>

{@render children()}
```

```svelte
<!-- site/src/routes/+page.svelte -->
<script module lang="ts">
  export const frontmatter = {
    layout: false,
    header: false,
    sidebar: false,
  }
</script>

<script lang="ts">
  import HeroRepoForm from '../lib/components/HeroRepoForm.svelte'
  import ConceptCardGrid from '../lib/components/ConceptCardGrid.svelte'
</script>

<svelte:head>
  <title>SideshowDb | Git-backed local-first data</title>
</svelte:head>

<section class="hero">
  <p class="eyebrow">Git-backed local-first database</p>
  <h1>Understand SideshowDb by exploring a real repo.</h1>
  <p class="lede">
    Git is the source of truth. SideshowDb derives documents, refs, and higher-level
    views from repository data.
  </p>
  <HeroRepoForm />
</section>

<section class="why">
  <h2>Why this is different</h2>
  <p>Keep Git-native workflows while projecting repository history into useful views.</p>
</section>

<ConceptCardGrid />
```

```ts
// site/src/app.d.ts
/// <reference types="vite/client" />
/// <reference types="svelte" />
/// <reference types="@sveltepress/vite/types" />
/// <reference types="@sveltepress/theme-default/types" />
/// <reference types="@sveltejs/kit/vite" />

declare module '*.svelte' {
  import type { SvelteComponentTyped } from 'svelte'

  export default class SvelteComponent<
    Props extends Record<string, unknown> = Record<string, never>,
    Events extends Record<string, unknown> = Record<string, never>,
    Slots extends Record<string, unknown> = Record<string, never>,
  > extends SvelteComponentTyped<Props, Events, Slots> {}
}
```

```md
---
title: Getting Started
order: 1
---

# Getting Started

Install Zig 0.16, build the CLI with `zig build`, and explore the browser client with `zig build wasm`.
```

```css
/* site/src/app.css */
:root {
  --atlas-ink: #172228;
  --atlas-sky: #d7eef7;
  --atlas-paper: #f8fbfd;
  --atlas-mint: #ecf0e6;
  --atlas-line: #8fb0bd;
  --atlas-accent: #1d4955;
}

body {
  color: var(--atlas-ink);
  background:
    radial-gradient(circle at top left, var(--atlas-sky) 0%, var(--atlas-paper) 45%, var(--atlas-mint) 100%);
}
```

```svelte
<!-- site/src/routes/playground/+page.svelte -->
<script module lang="ts">
  export const frontmatter = {
    title: 'Playground',
  }
</script>

<section class="docs-shell">
  <h1>Playground</h1>
  <p>
    This route is reserved for the interactive repository playground. Task 3 will
    replace this placeholder with the working evaluator-first experience.
  </p>
</section>
```

```svelte
<!-- site/src/routes/reference/+page.svelte -->
<script module lang="ts">
  export const frontmatter = {
    title: 'Reference',
  }
</script>

<section class="docs-shell">
  <h1>Reference</h1>
  <p>
    Generated API and command reference content will live here in Task 6.
  </p>
</section>
```

```ts
// site/vite.config.ts
import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'
import { svelteTesting } from '@testing-library/svelte/vite'

const config = {
  plugins: [
    sveltepress({
      siteConfig: {
        title: 'SideshowDb',
        description: 'Git-backed local-first data, docs, and a public repo playground.',
      },
      theme: defaultTheme({
        navbar: [
          { title: 'Home', to: '/' },
          { title: 'Docs', to: '/docs/getting-started/' },
          { title: 'Playground', to: '/playground/' },
          { title: 'Reference', to: '/reference/' },
        ],
        github: 'https://github.com/sideshowdb/sideshowdb',
        sidebar: { enabled: true, roots: ['/docs/'] },
      }),
    }),
    svelteTesting(),
  ],
  test: {
    environment: 'jsdom',
    passWithNoTests: true,
  },
} satisfies import('vite').UserConfig & {
  test: {
    environment: string
    passWithNoTests: boolean
  }
}

export default defineConfig(config)
```

- [ ] **Step 4: Re-run the homepage test**

Run: `cd site && bun run test -- src/routes/homepage.test.ts`

Expected: PASS.

- [ ] **Step 5: Run site type and route checks**

Run: `cd site && bun run check`

Expected: PASS with SvelteKit and SveltePress configuration validated.

- [ ] **Step 6: Commit the homepage and docs shell**

```bash
git add site/src/app.css site/src/app.d.ts site/src/lib/content/nav.ts site/src/lib/components/HeroRepoForm.svelte site/src/lib/components/ConceptCardGrid.svelte site/src/routes site/vite.config.ts
git commit -m "feat: add Graph Atlas homepage and docs shell"
```

## Task 3: Implement repo input validation and curated sample repo support

**Files:**
- Create: `site/src/lib/content/sample-repos.ts`
- Create: `site/src/lib/playground/repo-input.ts`
- Create: `site/src/lib/playground/repo-input.test.ts`
- Modify: `site/src/lib/components/HeroRepoForm.svelte`
- Modify: `site/src/routes/playground/+page.svelte`
- Test: `site/src/lib/playground/repo-input.test.ts`

- [ ] **Step 1: Write failing tests for repo parsing and validation**

```ts
import { describe, expect, it } from 'vitest'
import { parseRepoInput } from './repo-input'

describe('parseRepoInput', () => {
  it('accepts owner/repo pairs', () => {
    expect(parseRepoInput('sideshowdb/sideshowdb')).toEqual({
      owner: 'sideshowdb',
      repo: 'sideshowdb',
    })
  })

  it('rejects empty input', () => {
    expect(() => parseRepoInput('')).toThrow(/owner\/repo/i)
  })

  it('rejects extra path segments', () => {
    expect(() => parseRepoInput('a/b/c')).toThrow(/owner\/repo/i)
  })

  it('trims surrounding whitespace', () => {
    expect(parseRepoInput('  octocat/Hello-World  ')).toEqual({
      owner: 'octocat',
      repo: 'Hello-World',
    })
  })
})
```

- [ ] **Step 2: Run the repo input tests to verify they fail**

Run: `cd site && bun run test -- src/lib/playground/repo-input.test.ts`

Expected: FAIL with module-not-found or export-not-found because `repo-input.ts` does not exist yet.

- [ ] **Step 3: Implement the parser and curated sample repo list**

```ts
// site/src/lib/content/sample-repos.ts
export const sampleRepos = [
  {
    label: 'SideshowDb',
    fullName: 'sideshowdb/sideshowdb',
    description: 'Use the project repo as the default evaluator path.',
  },
  {
    label: 'Hello World',
    fullName: 'octocat/Hello-World',
    description: 'Simple fallback repo for API and error-state smoke checks.',
  },
] as const
```

```ts
// site/src/lib/playground/repo-input.ts
export type RepoRef = { owner: string; repo: string }

export function parseRepoInput(input: string): RepoRef {
  const trimmed = input.trim()
  const parts = trimmed.split('/').filter(Boolean)
  if (parts.length !== 2) throw new Error('Repository must use owner/repo format.')
  const [owner, repo] = parts
  if (!owner || !repo) throw new Error('Repository must use owner/repo format.')
  return { owner, repo }
}
```

```svelte
<!-- site/src/routes/playground/+page.svelte -->
<script lang="ts">
  import { sampleRepos } from '$lib/content/sample-repos'
</script>

<h1>Playground</h1>
<p>Explore a public GitHub repository through the SideshowDb model.</p>
<ul>
  {#each sampleRepos as repo}
    <li><a href={`/playground/?repo=${repo.fullName}`}>{repo.label}</a></li>
  {/each}
</ul>
```

- [ ] **Step 4: Re-run the repo input tests**

Run: `cd site && bun run test -- src/lib/playground/repo-input.test.ts`

Expected: PASS.

- [ ] **Step 5: Run the site checks again**

Run: `cd site && bun run check`

Expected: PASS.

- [ ] **Step 6: Commit repo input handling**

```bash
git add site/src/lib/content/sample-repos.ts site/src/lib/playground/repo-input.ts site/src/lib/playground/repo-input.test.ts site/src/routes/playground/+page.svelte site/src/lib/components/HeroRepoForm.svelte
git commit -m "feat: add repo input validation and sample repos"
```

## Task 4: Add public GitHub fetch helpers and explorer state

**Files:**
- Create: `site/src/lib/playground/github.ts`
- Create: `site/src/lib/playground/explorer.ts`
- Create: `site/src/lib/playground/github.test.ts`
- Create: `site/src/lib/playground/explorer.test.ts`
- Create: `site/src/lib/components/PlaygroundStatus.svelte`
- Create: `site/src/lib/components/RepoExplorer.svelte`
- Modify: `site/src/routes/playground/+page.svelte`
- Test: `site/src/lib/playground/github.test.ts`
- Test: `site/src/lib/playground/explorer.test.ts`

- [ ] **Step 1: Write failing tests for GitHub error mapping and explorer shaping**

```ts
import { describe, expect, it } from 'vitest'
import { mapGitHubError } from './github'

describe('mapGitHubError', () => {
  it('maps 404 to a plain-language missing repo message', () => {
    expect(mapGitHubError(404)).toMatch(/not found/i)
  })

  it('maps 403 to a rate-limit or access message', () => {
    expect(mapGitHubError(403)).toMatch(/rate|access/i)
  })
})
```

```ts
import { describe, expect, it } from 'vitest'
import { buildExplorerModel } from './explorer'

describe('buildExplorerModel', () => {
  it('keeps the selected repo name and refs in the view model', () => {
    const model = buildExplorerModel({
      fullName: 'sideshowdb/sideshowdb',
      refs: [{ name: 'refs/heads/main', target: 'abc123' }],
    })

    expect(model.fullName).toBe('sideshowdb/sideshowdb')
    expect(model.refs[0].name).toBe('refs/heads/main')
  })
})
```

- [ ] **Step 2: Run the new playground logic tests**

Run: `cd site && bun run test -- src/lib/playground/github.test.ts src/lib/playground/explorer.test.ts`

Expected: FAIL because the modules do not exist yet.

- [ ] **Step 3: Implement GitHub helpers and the focused explorer model**

```ts
// site/src/lib/playground/github.ts
import type { RepoRef } from './repo-input'

export function mapGitHubError(status: number): string {
  if (status === 404) return 'Repository not found. Try a public owner/repo or use the sample repo.'
  if (status === 403) return 'GitHub rejected the request. You may have hit a public API rate limit.'
  return 'GitHub data could not be loaded right now. Try again or use the sample repo.'
}

export async function fetchRepoSummary(repo: RepoRef) {
  const response = await fetch(`https://api.github.com/repos/${repo.owner}/${repo.repo}`)
  if (!response.ok) throw new Error(mapGitHubError(response.status))
  return response.json()
}

export async function fetchRepoRefs(repo: RepoRef) {
  const response = await fetch(`https://api.github.com/repos/${repo.owner}/${repo.repo}/git/matching-refs/heads`)
  if (!response.ok) throw new Error(mapGitHubError(response.status))
  return response.json()
}
```

```ts
// site/src/lib/playground/explorer.ts
export function buildExplorerModel(input: {
  fullName: string
  refs: Array<{ name: string; target: string }>
}) {
  return {
    fullName: input.fullName,
    refs: input.refs.slice(0, 8),
    explanation:
      'GitHub is the fetch source. SideshowDb turns repository structures into focused derived views.',
  }
}
```

```svelte
<!-- site/src/lib/components/RepoExplorer.svelte -->
<script lang="ts">
  export let model: {
    fullName: string
    refs: Array<{ name: string; target: string }>
    explanation: string
  }
</script>

<section>
  <h2>{model.fullName}</h2>
  <p>{model.explanation}</p>
  <ul>
    {#each model.refs as ref}
      <li><code>{ref.name}</code> → <code>{ref.target}</code></li>
    {/each}
  </ul>
</section>
```

- [ ] **Step 4: Re-run the logic tests**

Run: `cd site && bun run test -- src/lib/playground/github.test.ts src/lib/playground/explorer.test.ts`

Expected: PASS.

- [ ] **Step 5: Add route-level loading and graceful error display**

```svelte
<!-- site/src/routes/playground/+page.svelte -->
<script lang="ts">
  import { parseRepoInput } from '$lib/playground/repo-input'
  import { buildExplorerModel } from '$lib/playground/explorer'
  import { fetchRepoRefs, fetchRepoSummary } from '$lib/playground/github'
  import PlaygroundStatus from '$lib/components/PlaygroundStatus.svelte'
  import RepoExplorer from '$lib/components/RepoExplorer.svelte'

  let model = $state<ReturnType<typeof buildExplorerModel> | null>(null)
  let error = $state('')

  async function loadRepo(fullName: string) {
    error = ''
    model = null
    try {
      const repo = parseRepoInput(fullName)
      const summary = await fetchRepoSummary(repo)
      const refs = await fetchRepoRefs(repo)
      model = buildExplorerModel({
        fullName: summary.full_name,
        refs: refs.map((ref: { ref: string; object: { sha: string } }) => ({
          name: ref.ref,
          target: ref.object.sha,
        })),
      })
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Unknown playground error.'
    }
  }
</script>
```

- [ ] **Step 6: Run the full site test suite**

Run: `cd site && bun run test`

Expected: PASS.

- [ ] **Step 7: Commit the public GitHub explorer slice**

```bash
git add site/src/lib/playground site/src/lib/components/PlaygroundStatus.svelte site/src/lib/components/RepoExplorer.svelte site/src/routes/playground/+page.svelte
git commit -m "feat: add public GitHub repo explorer"
```

## Task 5: Integrate the Zig WASM artifact and SideshowDB projection panel

**Files:**
- Create: `site/src/lib/playground/wasm.ts`
- Create: `site/src/lib/components/ProjectionPanel.svelte`
- Create: `site/src/routes/playground-page.test.ts`
- Create: `scripts/prepare-site-assets.sh`
- Modify: `src/wasm/root.zig` only if browser integration needs an extra exported helper
- Modify: `site/src/routes/playground/+page.svelte`
- Test: `site/src/routes/playground-page.test.ts`

- [ ] **Step 1: Write the failing playground page test**

```ts
import { render, screen } from '@testing-library/svelte'
import { describe, expect, it } from 'vitest'
import PlaygroundPage from './playground/+page.svelte'

describe('playground page', () => {
  it('renders the sample repo path and a projection explanation panel', () => {
    render(PlaygroundPage)
    expect(screen.getByText(/sideshowdb\/sideshowdb/i)).toBeTruthy()
    expect(screen.getByText(/SideshowDb interpretation/i)).toBeTruthy()
  })
})
```

- [ ] **Step 2: Run the playground page test to verify it fails**

Run: `cd site && bun run test -- src/routes/playground-page.test.ts`

Expected: FAIL because the route does not yet render a projection panel.

- [ ] **Step 3: Stage the WASM artifact for the site and add a browser wrapper**

```bash
#!/usr/bin/env bash
set -euo pipefail

zig build wasm -Doptimize=ReleaseSafe
mkdir -p site/static/wasm
cp -f zig-out/wasm/sideshowdb.wasm site/static/wasm/sideshowdb.wasm
```

```ts
// site/src/lib/playground/wasm.ts
let wasmInstance: WebAssembly.Instance | null = null

export async function loadSideshowDbWasm() {
  if (wasmInstance) return wasmInstance.exports as Record<string, CallableFunction>
  const response = await fetch('/wasm/sideshowdb.wasm')
  const bytes = await response.arrayBuffer()
  const { instance } = await WebAssembly.instantiate(bytes, {})
  wasmInstance = instance
  return instance.exports as Record<string, CallableFunction>
}
```

```svelte
<!-- site/src/lib/components/ProjectionPanel.svelte -->
<script lang="ts">
  export let title = 'SideshowDb interpretation'
  export let body = 'This panel explains how the fetched repository data maps into derived SideshowDb views.'
</script>

<aside class="projection-panel">
  <h3>{title}</h3>
  <p>{body}</p>
</aside>
```

```svelte
<!-- site/src/lib/components/PlaygroundStatus.svelte -->
<script lang="ts">
  export let kind: 'idle' | 'loading' | 'error' = 'idle'
  export let message = ''
</script>

<div data-kind={kind}>
  <p>{message}</p>
</div>
```

- [ ] **Step 4: Update the playground route to load the WASM bundle and render the projection panel**

```svelte
<!-- site/src/routes/playground/+page.svelte -->
<script lang="ts">
  import ProjectionPanel from '$lib/components/ProjectionPanel.svelte'
  import { loadSideshowDbWasm } from '$lib/playground/wasm'

  let wasmReady = $state(false)

  $effect(() => {
    loadSideshowDbWasm()
      .then(() => {
        wasmReady = true
      })
      .catch(() => {
        wasmReady = false
      })
  })
</script>

{#if model}
  <RepoExplorer {model} />
  <ProjectionPanel
    body={wasmReady
      ? 'The browser runtime is ready to interpret repo data using the shipped SideshowDb WASM module.'
      : 'The browser runtime is unavailable, so the playground is showing fetch-only fallback details.'}
  />
{/if}
```

- [ ] **Step 5: Re-run the playground page test**

Run: `cd site && bun run test -- src/routes/playground-page.test.ts`

Expected: PASS.

- [ ] **Step 6: Run WASM preparation and the full site test suite**

Run: `bash scripts/prepare-site-assets.sh && cd site && bun run test`

Expected: PASS and `site/static/wasm/sideshowdb.wasm` exists.

- [ ] **Step 7: Commit the WASM-backed projection panel**

```bash
git add scripts/prepare-site-assets.sh site/src/lib/playground/wasm.ts site/src/lib/components/ProjectionPanel.svelte site/src/routes/playground/+page.svelte site/src/routes/playground-page.test.ts
git commit -m "feat: connect playground to Zig wasm artifact"
```

## Task 6: Publish Zig reference docs, assemble the Pages artifact, and add CI + Pages deployment

**Files:**
- Create: `scripts/build-zig-docs.sh`
- Create: `scripts/assemble-pages-artifact.sh`
- Create: `scripts/verify-pages-artifact.sh`
- Modify: `site/package.json`
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/pages.yml`
- Test: `scripts/verify-pages-artifact.sh`

- [ ] **Step 1: Write the failing Pages artifact verification script**

```bash
#!/usr/bin/env bash
set -euo pipefail

test -f dist/pages/index.html
test -f dist/pages/reference/index.html
test -f dist/pages/wasm/sideshowdb.wasm
```

- [ ] **Step 2: Run the artifact verification script before the build exists**

Run: `bash scripts/verify-pages-artifact.sh`

Expected: FAIL on the first missing `dist/pages/...` file.

- [ ] **Step 3: Add doc generation and artifact assembly scripts**

```bash
#!/usr/bin/env bash
set -euo pipefail

rm -rf .build/reference
mkdir -p .build/reference
zig test -femit-docs=.build/reference src/core/root.zig
```

```bash
#!/usr/bin/env bash
set -euo pipefail

rm -rf dist/pages
mkdir -p dist/pages
cp -rf site/dist/. dist/pages/
mkdir -p dist/pages/reference
cp -rf .build/reference/. dist/pages/reference/
mkdir -p dist/pages/wasm
cp -f site/static/wasm/sideshowdb.wasm dist/pages/wasm/sideshowdb.wasm
```

```json
{
  "scripts": {
    "build:site": "vite build",
    "build:pages": "bun run build:site"
  }
}
```

- [ ] **Step 4: Add GitHub Actions workflows for CI and Pages**

```yaml
# .github/workflows/ci.yml
  site-build-test:
    name: Site Build and Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      - name: Setup Bun
        uses: oven-sh/setup-bun@v2
      - name: Install site dependencies
        run: cd site && bun ci
      - name: Prepare site assets
        run: bash scripts/prepare-site-assets.sh
      - name: Build Zig reference docs
        run: bash scripts/build-zig-docs.sh
      - name: Build site
        env:
          BASE_PATH: ''
        run: cd site && bun run build
      - name: Assemble Pages artifact
        run: bash scripts/assemble-pages-artifact.sh
      - name: Verify Pages artifact
        run: bash scripts/verify-pages-artifact.sh
```

```yaml
# .github/workflows/pages.yml
name: Pages

on:
  push:
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/configure-pages@v5
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      - uses: oven-sh/setup-bun@v2
      - run: cd site && bun ci
      - run: bash scripts/prepare-site-assets.sh
      - run: bash scripts/build-zig-docs.sh
      - env:
          BASE_PATH: /${{ github.event.repository.name }}
        run: cd site && bun run build
      - run: bash scripts/assemble-pages-artifact.sh
      - uses: actions/upload-pages-artifact@v3
        with:
          path: dist/pages

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 5: Run the full local build and verify the artifact**

Run: `bash scripts/prepare-site-assets.sh && bash scripts/build-zig-docs.sh && cd site && bun run build && cd .. && bash scripts/assemble-pages-artifact.sh && bash scripts/verify-pages-artifact.sh`

Expected: PASS and `dist/pages/` contains `index.html`, `reference/index.html`, and `wasm/sideshowdb.wasm`.

- [ ] **Step 6: Run the existing Zig quality gate after site integration**

Run: `zig build test -Doptimize=ReleaseSafe`

Expected: PASS.

- [ ] **Step 7: Commit the Pages pipeline**

```bash
git add .github/workflows/ci.yml .github/workflows/pages.yml scripts/build-zig-docs.sh scripts/assemble-pages-artifact.sh scripts/verify-pages-artifact.sh site/package.json site/bun.lock
git commit -m "ci: publish GitHub Pages site and reference docs"
```

## Task 7: Final content polish, acceptance verification, and issue closure

**Files:**
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/src/routes/docs/getting-started/+page.md`
- Modify: `site/src/routes/docs/concepts/+page.md`
- Modify: `site/src/routes/docs/playground/+page.md`
- Modify: `site/src/routes/playground/+page.svelte`
- Modify: `docs/superpowers/specs/2026-04-26-github-pages-site-design.md` only if implementation forces a documented spec correction
- Test: all previously added tests and scripts

- [ ] **Step 1: Review the implemented site against each EARS requirement**

```md
Checklist:
- Home / Docs / Playground / Reference nav exists
- Homepage CTA is visible without scrolling
- Homepage states Git is the source of truth
- Playground supports a curated sample repo without auth
- owner/repo validation happens before fetch
- malformed input blocks fetch and shows a specific message
- public repo fetches happen browser-side
- 404 and 403 errors offer sample-repo fallback
- unsupported repos explain the limitation
- no write or private-auth affordances appear in v1
- reference docs publish under /reference/
- Pages build fails if reference docs are missing
- Bun is used for site install/build/verification
```

- [ ] **Step 2: Run the full verification bundle**

Run: `cd site && bun run test && bun run check && cd .. && bash scripts/prepare-site-assets.sh && bash scripts/build-zig-docs.sh && bash scripts/assemble-pages-artifact.sh && bash scripts/verify-pages-artifact.sh && zig build test -Doptimize=ReleaseSafe`

Expected: PASS across site tests, site checks, artifact verification, and Zig tests.

- [ ] **Step 3: Run git status and confirm only intended files changed**

Run: `git status --short`

Expected: only site, scripts, workflow, and any intentionally updated docs/spec files appear.

- [ ] **Step 4: Close the beads issue after merge-ready verification**

```bash
bd close sideshowdb-oob
```

- [ ] **Step 5: Commit the acceptance polish**

```bash
git add site scripts .github/workflows docs/superpowers/specs/2026-04-26-github-pages-site-design.md
git commit -m "docs: finalize GitHub Pages site acceptance details"
```

## Self-Review

- Spec coverage: Tasks 1-2 cover top-level navigation, homepage CTA, authored docs, and visual direction. Tasks 3-5 cover sample repo flow, owner/repo validation, browser-side public GitHub fetches, unsupported repo handling, and the read-only projection UI. Task 6 covers Zig reference docs publication, Bun-based CI, and Pages artifact assembly. Task 7 covers final EARS acceptance verification and issue closure.
- Placeholder scan: no `TODO`, `TBD`, or "write tests later" placeholders remain. Every task includes explicit files, commands, and code snippets.
- Type consistency: the plan consistently uses `parseRepoInput`, `mapGitHubError`, `buildExplorerModel`, and `loadSideshowDBWasm` across implementation and test tasks.
