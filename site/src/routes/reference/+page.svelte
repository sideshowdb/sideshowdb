<script module lang="ts">
  export const frontmatter = {
    title: 'Reference',
    sidebar: false,
  }
</script>

<script lang="ts">
  import { base } from '$app/paths'
  import MacWindow from '$lib/components/MacWindow.svelte'

  const apiHref = `${base}/reference/api/`
</script>

<svelte:head>
  <title>Reference | SideshowDB</title>
</svelte:head>

<section class="reference-shell">
  <MacWindow title="SideshowDB API" class="reference-frame">
    <iframe
      src={apiHref}
      title="SideshowDB Zig API reference"
      loading="lazy"
    ></iframe>
  </MacWindow>
</section>
