<script lang="ts">
  import MermaidRenderer from '$lib/components/MermaidRenderer.svelte'
  import '../app.css'

  let { children } = $props()
</script>

{@render children()}
<MermaidRenderer />
