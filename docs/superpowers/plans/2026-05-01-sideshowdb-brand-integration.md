# SideshowDB Brand Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Integrate the selected Carousel Database Core A brand into the
SveltePress homepage title slot and favicon without adding a separate header
icon or logo art inside the custom playground hero.

**Architecture:** Keep the integration in existing Svelte site files.
SveltePress still owns `siteConfig.title` and description. Global CSS replaces
the visible `.home-page .gradient-title` treatment with the selected transparent
PNG logo lockup. `favicon.svg` owns the browser icon. Route tests assert the
public brand contract.

**Tech Stack:** SvelteKit/SveltePress, Svelte Testing Library, Vitest, SVG and
PNG assets under `site/static/assets/brand/`, Zig build tasks for JS checks and
site build.

---

## File Structure

- Modify `site/src/app.css`: style `.home-page .gradient-title` as the Core A
  logo lockup slot.
- Modify `site/vite.config.ts`: remove `defaultTheme.logo` so the top nav does
  not add a separate Core A icon.
- Modify `site/src/routes/site-branding.test.ts`: assert the home title CSS,
  favicon identity, and absence of the header-logo config.
- Keep `site/src/routes/+page.svelte`: the custom hero remains text/form only.
- Keep `site/static/favicon.svg`: Core A carousel icon.
- Keep `site/src/routes/branding/+page.svelte`: canonical asset catalog.

## Tasks

### Task 1: Pin Corrected Branding Contract

**Files:**
- Modify: `site/src/routes/site-branding.test.ts`

- [x] **Step 1: Write the failing home title logo test**

```ts
it('uses the Core A carousel logo lockup in the home title slot', async () => {
  const appCss = await readFile(appCssPath, 'utf8')

  expect(appCss).toContain(".home-page .gradient-title")
  expect(appCss).toContain(
    "background: url('/assets/brand/raster-transparent/carousel-database-core-a-logo.png')"
  )
  expect(appCss).toContain('font-size: 0;')
})
```

- [x] **Step 2: Write the header-logo absence test**

```ts
it('does not add a separate Core A icon to the top navigation', async () => {
  const config = await readFile(viteConfigPath, 'utf8')

  expect(config).not.toContain("logo: '/assets/brand/svg/carousel-database-core-a-icon.svg'")
})
```

- [x] **Step 3: Run the focused test to verify it fails**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts src/routes/homepage.test.ts
```

Expected before implementation: FAIL because the title CSS is absent and the
old header-logo config is still present.

### Task 2: Move Brand Mark Into Home Title Slot

**Files:**
- Modify: `site/src/app.css`
- Modify: `site/vite.config.ts`

- [x] **Step 1: Remove the header-logo config**

Remove `logo: '/assets/brand/svg/carousel-database-core-a-icon.svg'` from the
`defaultTheme` options.

- [x] **Step 2: Style the SveltePress title slot**

Add global CSS for `.home-page .gradient-title` that preserves the element but
uses the Core A transparent logo lockup as the visible treatment.

```css
.home-page .gradient-title {
  width: min(100%, 26rem);
  min-height: clamp(5rem, 12vw, 7.5rem);
  overflow: hidden;
  color: transparent;
  font-size: 0;
  line-height: 0;
  background: url('/assets/brand/raster-transparent/carousel-database-core-a-logo.png') left center / contain no-repeat;
}
```

- [x] **Step 3: Keep mobile alignment stable**

Center the title-slot logo on narrow screens and keep the description separated
from the image.

- [x] **Step 4: Run the focused test to verify it passes**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts src/routes/homepage.test.ts
```

Expected after implementation: PASS.

### Task 3: Verify And Ship

**Files:**
- Modify: `docs/superpowers/specs/2026-05-01-sideshowdb-brand-integration-design.md`
- Modify: `docs/superpowers/plans/2026-05-01-sideshowdb-brand-integration.md`
- Modify: `site/src/app.css`
- Modify: `site/vite.config.ts`
- Modify: `site/src/routes/site-branding.test.ts`

- [x] **Step 1: Run focused route tests**

```bash
bun run --cwd site test -- src/routes/homepage.test.ts src/routes/site-branding.test.ts src/routes/branding-page.test.ts
```

- [x] **Step 2: Run full JS tests**

```bash
zig build js:test
```

- [x] **Step 3: Run JS type checks**

```bash
zig build js:check
```

- [x] **Step 4: Run production site build**

```bash
zig build site:build
```

Existing SveltePress code-block a11y and chunk-size warnings may still appear.

- [x] **Step 5: Close bead and commit**

```bash
bd close sideshowdb-5x5 --reason="Moved the selected Core A logo lockup into the SveltePress home title slot." --json
git add docs/superpowers/specs/2026-05-01-sideshowdb-brand-integration-design.md docs/superpowers/plans/2026-05-01-sideshowdb-brand-integration.md site/src/app.css site/vite.config.ts site/src/routes/site-branding.test.ts
git commit -m "docs(site): place logo in home title"
```

- [ ] **Step 6: Push code and beads**

```bash
git pull --rebase
bd dolt push
git push
git status --short --branch
```
