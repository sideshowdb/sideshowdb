<script module lang="ts">
  export const frontmatter = {
    title: 'Reference',
    sidebar: false,
  }
</script>

<script lang="ts">
  import { base } from '$app/paths'

  const apiHref = `${base}/reference/api/`
</script>

<svelte:head>
  <title>Reference | SideshowDB</title>
</svelte:head>

<section class="reference-shell">
  <div class="mac-window reference-frame">
    <div class="mac-window-bar" aria-hidden="true">
      <span class="mac-dot mac-dot-red"></span>
      <span class="mac-dot mac-dot-yellow"></span>
      <span class="mac-dot mac-dot-green"></span>
      <span class="mac-window-title">SideshowDB API</span>
    </div>
    <iframe
      src={apiHref}
      title="SideshowDB Zig API reference"
      loading="lazy"
    ></iframe>
  </div>
</section>
