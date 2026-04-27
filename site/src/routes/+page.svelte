<script module lang="ts">
  export const frontmatter = {
    layout: false,
    header: false,
    sidebar: false,
  }
</script>

<script lang="ts">
  import { base } from '$app/paths'
  import HeroRepoForm from '../lib/components/HeroRepoForm.svelte'
  import ConceptCardGrid from '../lib/components/ConceptCardGrid.svelte'
</script>

<svelte:head>
  <title>Sideshowdb | Git-backed local-first data</title>
</svelte:head>

<section class="hero">
  <p class="eyebrow">Git-backed local-first database</p>
  <h1>Understand Sideshowdb by exploring a real repo.</h1>
  <p class="lede">
    Git is the source of truth. Sideshowdb derives documents, refs, and higher-level
    views from repository data.
  </p>
  <HeroRepoForm />
</section>

<section class="why">
  <h2>What you can do here</h2>
  <p>
    Open the playground to inspect a public repository in the browser. When the staged
    WASM asset is present, the playground runs the shipped Sideshowdb runtime instead of
    just explaining the shell.
  </p>
  <div class="pathway-links">
    <a class="primary" href={`${base}/playground/`}>Open Playground</a>
    <a class="secondary" href={`${base}/docs/getting-started/`}>Getting Started</a>
    <a class="secondary" href={`${base}/docs/concepts/`}>Concepts</a>
  </div>
</section>

<ConceptCardGrid />
