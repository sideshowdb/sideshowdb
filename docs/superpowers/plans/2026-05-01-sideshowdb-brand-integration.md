# SideshowDB Brand Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Integrate the selected Carousel Database Core A brand into the homepage, favicon, and useful site surfaces.

**Architecture:** Keep the integration in the existing Svelte site files. The homepage owns the hero-forward logo treatment, `app.css` owns shared presentation, `favicon.svg` becomes the Core A icon, and route tests assert the public brand contract.

**Tech Stack:** SvelteKit/SveltePress, Svelte Testing Library, Vitest, SVG assets under `site/static/assets/brand/`, Zig build tasks for JS checks and site build.

---

## File Structure

- Modify `site/src/routes/+page.svelte`: add the Core A logo lockup to the homepage hero and add a compact brand note.
- Modify `site/src/app.css`: style the logo-forward homepage hero, responsive logo block, and small brand note.
- Modify `site/static/favicon.svg`: replace the old node-dot favicon with the Core A carousel icon SVG structure.
- Modify `site/src/routes/homepage.test.ts`: assert the hero logo, brand note, and existing CTAs render.
- Create `site/src/routes/site-branding.test.ts`: assert the favicon uses the Core A palette/structure.
- Keep `site/src/routes/branding/+page.svelte` as the canonical asset catalog.

### Task 1: Homepage Brand Contract

**Files:**
- Modify: `site/src/routes/homepage.test.ts`
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/src/app.css`

- [x] **Step 1: Write the failing homepage test**

Update `site/src/routes/homepage.test.ts` so the existing test also checks the homepage brand contract:

```ts
expect(screen.getByAltText('SideshowDB carousel database logo')).toBeTruthy()
expect(screen.getByText(/refs, documents, and views moving together/i)).toBeTruthy()
```

- [x] **Step 2: Run the homepage test to verify it fails**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts
```

Expected: FAIL because the logo alt text and brand note are not present yet.

- [x] **Step 3: Add the homepage brand markup**

In `site/src/routes/+page.svelte`, keep the existing imports and add this brand media block inside `<section class="hero">`, before `<div class="hero-text">`:

```svelte
<div class="hero-brand" aria-label="SideshowDB brand mark">
  <img
    class="hero-brand-logo"
    src={`${base}/assets/brand/svg/carousel-database-core-a-logo.svg`}
    alt="SideshowDB carousel database logo"
  />
  <p>Refs, documents, and views moving together.</p>
</div>
```

- [x] **Step 4: Style the homepage brand block**

In `site/src/app.css`, update `.hero` to fit three columns on desktop and add these rules near the existing hero styles:

```css
.hero {
  grid-template-columns: minmax(10rem, 0.62fr) minmax(0, 1fr) minmax(0, 1fr);
}

.hero-brand {
  display: grid;
  gap: 1rem;
  align-content: center;
  justify-items: start;
  min-width: 0;
}

.hero-brand-logo {
  display: block;
  width: min(100%, 18rem);
  height: auto;
  filter: drop-shadow(0 18px 32px rgba(12, 47, 56, 0.18));
}

.hero-brand p {
  max-width: 15rem;
  margin: 0;
  color: var(--atlas-body-text-muted);
  font-size: 0.95rem;
  font-weight: 700;
  line-height: 1.45;
}
```

Update the existing mobile media query for `.hero` so the hero becomes one column and centers the brand:

```css
.hero {
  grid-template-columns: 1fr;
}

.hero-brand {
  justify-items: center;
  text-align: center;
}
```

- [x] **Step 5: Run the homepage test to verify it passes**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts
```

Expected: PASS.

### Task 2: Core A Favicon Contract

**Files:**
- Create: `site/src/routes/site-branding.test.ts`
- Modify: `site/static/favicon.svg`

- [x] **Step 1: Write the failing favicon test**

Create `site/src/routes/site-branding.test.ts`:

```ts
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const faviconPath = join(process.cwd(), 'static/favicon.svg')

describe('site branding assets', () => {
  it('uses the selected Core A carousel icon as the favicon', async () => {
    const favicon = await readFile(faviconPath, 'utf8')

    expect(favicon).toContain('viewBox="0 0 256 256"')
    expect(favicon).toContain('#009c98')
    expect(favicon).toContain('#ffb000')
    expect(favicon).toContain('#2e8deb')
    expect(favicon).toContain('carousel canopy')
  })
})
```

- [x] **Step 2: Run the favicon test to verify it fails**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts
```

Expected: FAIL because the current favicon still uses the old node-dot mark.

- [x] **Step 3: Replace the favicon with Core A SVG**

Copy the meaningful Core A icon structure from
`site/static/assets/brand/svg/carousel-database-core-a-icon.svg` into
`site/static/favicon.svg`, keeping it self-contained and adding this metadata
comment near the top:

```xml
<!-- SideshowDB Core A carousel canopy favicon -->
```

- [x] **Step 4: Run the favicon test to verify it passes**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts
```

Expected: PASS.

### Task 3: Site Surface Polish And Full Verification

**Files:**
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/src/app.css`
- Modify: `site/src/routes/homepage.test.ts`
- Create: `site/src/routes/site-branding.test.ts`

- [x] **Step 1: Check the homepage and brand page in the running dev site**

Run:

```bash
curl -I --max-time 2 http://127.0.0.1:5173/
curl -I --max-time 2 http://127.0.0.1:5173/branding/
```

Expected: both return HTTP 200 if the dev server is running. If not running,
start it with:

```bash
screen -dmS sideshowdb-brand-carousel zsh -lc 'cd /Users/damian/code/github/sideshowdb/sideshowdb/.worktrees/brand-carousel && bun run --cwd site dev -- --host 127.0.0.1'
```

- [x] **Step 2: Run focused route tests**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts src/routes/site-branding.test.ts src/routes/branding-page.test.ts
```

Expected: PASS for all three files.

- [x] **Step 3: Run full JS tests**

Run:

```bash
zig build js:test
```

Expected: all TypeScript binding and site tests pass.

- [x] **Step 4: Run JS type checks**

Run:

```bash
zig build js:check
```

Expected: `svelte-check found 0 errors and 0 warnings`.

- [x] **Step 5: Run production site build**

Run:

```bash
zig build site:build
```

Expected: build exits 0. Existing SveltePress code-block a11y and chunk-size
warnings may still appear.

- [x] **Step 6: Close the bead issue and commit**

Run:

```bash
bd close sideshowdb-ohc --reason="Integrated the selected Core A brand into the homepage, favicon, and site tests." --json
git add site/src/routes/+page.svelte site/src/app.css site/static/favicon.svg site/src/routes/homepage.test.ts site/src/routes/site-branding.test.ts docs/superpowers/plans/2026-05-01-sideshowdb-brand-integration.md
git commit -m "docs(site): integrate carousel brand"
```

- [x] **Step 7: Push code and beads**

Run:

```bash
git pull --rebase
bd dolt push
git push
git status --short --branch
```

Expected: branch is up to date with `origin/docs/brand-carousel`.
