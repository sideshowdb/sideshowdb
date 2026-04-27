# Site Typing Build Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SvelteKit include `site/src/app.d.ts` so the official Svelte type refs resolve `.svelte` component imports during `bun run check`.

**Architecture:** Keep the site shell and homepage code unchanged. Fix the TypeScript graph at the project config layer so the ambient declarations in `site/src/app.d.ts` are actually visible to `svelte-check`, then verify the homepage test and site build still pass.

**Tech Stack:** Zig build graph, SvelteKit, TypeScript, Bun

---

### Task 1: Make the app type declarations part of the TS program

**Files:**
- Modify: `site/tsconfig.json`
- Modify: `site/src/app.d.ts`

- [ ] **Step 1: Update the TypeScript entrypoint**

```json
{
  "extends": "./.svelte-kit/tsconfig.json",
  "files": ["src/app.d.ts"],
  "compilerOptions": {
    "allowJs": false,
    "checkJs": false,
    "moduleResolution": "bundler",
    "skipLibCheck": true,
    "strict": true
  }
}
```

- [ ] **Step 2: Keep only the official type references in `app.d.ts`**

```ts
/// <reference types="vite/client" />
/// <reference types="svelte" />
/// <reference types="@sveltepress/vite/types" />
/// <reference types="@sveltepress/theme-default/types" />
/// <reference types="@sveltejs/kit/vite" />
```

- [ ] **Step 3: Run the type checker**

Run: `cd site && bun run check`
Expected: PASS with no module declaration errors.

### Task 2: Re-verify the site surface

**Files:**
- Test: `site/src/routes/homepage.test.ts`

- [ ] **Step 1: Run the homepage test**

Run: `cd site && bun run test -- src/routes/homepage.test.ts`
Expected: PASS.

- [ ] **Step 2: Run the production build**

Run: `cd site && bun run build`
Expected: PASS.

- [ ] **Step 3: Commit the fix**

```bash
git add site/tsconfig.json site/src/app.d.ts docs/superpowers/plans/2026-04-27-site-typing-build-fix.md
git commit -m "fix: include site app typings in check"
```

