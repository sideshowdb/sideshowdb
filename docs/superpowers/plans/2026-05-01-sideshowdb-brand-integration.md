# SideshowDB Brand Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Integrate the selected Carousel Database Core A brand into the site header, favicon, and useful site surfaces.

**Architecture:** Keep the integration in the existing Svelte site files. SveltePress theme config owns the top header logo, `favicon.svg` owns the browser icon, the homepage stays playground-focused, and route tests assert the public brand contract.

**Tech Stack:** SvelteKit/SveltePress, Svelte Testing Library, Vitest, SVG assets under `site/static/assets/brand/`, Zig build tasks for JS checks and site build.

---

## File Structure

- Modify `site/vite.config.ts`: configure the SveltePress header logo with the Core A icon.
- Modify `site/src/routes/+page.svelte`: remove the hero logo lockup and keep the hero text/form focused.
- Modify `site/src/app.css`: remove hero logo styles and keep the two-column hero layout.
- Modify `site/static/favicon.svg`: replace the old node-dot favicon with the Core A carousel icon SVG structure.
- Modify `site/src/routes/homepage.test.ts`: assert the hero logo/brand note are absent and existing CTAs render.
- Create/modify `site/src/routes/site-branding.test.ts`: assert the favicon and SveltePress theme logo use Core A.
- Keep `site/src/routes/branding/+page.svelte` as the canonical asset catalog.

## Tasks

### Task 1: Move Brand Mark To Header

**Files:**
- Modify: `site/vite.config.ts`
- Modify: `site/src/routes/site-branding.test.ts`

- [x] **Step 1: Write the failing header logo test**

```ts
it('uses the Core A carousel icon in the site header logo', async () => {
  const config = await readFile(viteConfigPath, 'utf8')

  expect(config).toContain("logo: '/assets/brand/svg/carousel-database-core-a-icon.svg'")
})
```

- [x] **Step 2: Run the focused test to verify it fails**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts
```

Expected before implementation: FAIL because `defaultTheme` has no `logo`.

- [x] **Step 3: Configure the SveltePress theme logo**

```ts
theme: defaultTheme({
  logo: '/assets/brand/svg/carousel-database-core-a-icon.svg',
  navbar: topNav,
  sidebar: {
    enabled: true,
    roots: ['/docs/'],
  },
  github: 'https://github.com/sideshowdb/sideshowdb',
  highlighter: {
    languages: [
      'svelte',
      'sh',
      'bash',
      'js',
      'ts',
      'html',
      'css',
      'scss',
      'md',
      'json',
      'toml',
      'zig',
    ],
  },
}),
```

- [x] **Step 4: Run the focused test to verify it passes**

Run:

```bash
bun run --cwd site test -- src/routes/site-branding.test.ts
```

Expected after implementation: PASS.

### Task 2: Remove Hero Logo Treatment

**Files:**
- Modify: `site/src/routes/homepage.test.ts`
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/src/app.css`

- [x] **Step 1: Write the failing homepage absence test**

```ts
expect(screen.queryByAltText('SideshowDB carousel database logo')).toBeNull()
expect(screen.queryByText(/refs, documents, and views moving together/i)).toBeNull()
```

- [x] **Step 2: Run the focused test to verify it fails**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts
```

Expected before implementation: FAIL because the hero still contains the logo.

- [x] **Step 3: Remove the hero logo markup**

Remove the `hero-brand` block from `site/src/routes/+page.svelte` and keep the
existing `.hero-text` and `<HeroRepoForm />` children.

- [x] **Step 4: Remove hero logo CSS and restore two columns**

Keep the desktop hero grid as:

```css
.hero {
  grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr);
}
```

Remove `.hero-brand`, `.hero-brand-logo`, and `.hero-brand p` rules.

- [x] **Step 5: Run the focused test to verify it passes**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts
```

Expected after implementation: PASS.

### Task 3: Verify And Ship

**Files:**
- Modify: `docs/superpowers/specs/2026-05-01-sideshowdb-brand-integration-design.md`
- Modify: `docs/superpowers/plans/2026-05-01-sideshowdb-brand-integration.md`
- Modify: `site/vite.config.ts`
- Modify: `site/src/routes/+page.svelte`
- Modify: `site/src/app.css`
- Modify: `site/src/routes/homepage.test.ts`
- Modify: `site/src/routes/site-branding.test.ts`

- [x] **Step 1: Verify no hero logo treatment remains in site code**

Run:

```bash
rg -n "hero-brand|carousel-database-core-a-logo|refs, documents, and views moving together" site/src
```

Expected: no matches except route tests that assert absence, if any.

- [x] **Step 2: Run focused route tests**

Run:

```bash
bun run --cwd site test -- src/routes/homepage.test.ts src/routes/site-branding.test.ts src/routes/branding-page.test.ts
```

Expected: PASS.

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

- [x] **Step 6: Close follow-up bead and commit**

```bash
bd close sideshowdb-9x9 --reason="Moved the Core A brand mark from the homepage hero to the SveltePress header logo." --json
git add docs/superpowers/specs/2026-05-01-sideshowdb-brand-integration-design.md docs/superpowers/plans/2026-05-01-sideshowdb-brand-integration.md site/vite.config.ts site/src/routes/+page.svelte site/src/app.css site/src/routes/homepage.test.ts site/src/routes/site-branding.test.ts
git commit -m "docs(site): move brand mark to header"
```

- [x] **Step 7: Push code and beads**

```bash
git pull --rebase
bd dolt push
git push
git status --short --branch
```
