<script lang="ts">
  import { base } from '$app/paths'

  let { actionHref = '/playground/', sampleRepo = 'sideshowdb/sideshowdb' } = $props()
</script>

<div class="hero-actions">
  <a class="primary" href={`${base}${actionHref}`}>Try Playground</a>
  <a class="secondary" href={`${base}/playground/?repo=${sampleRepo}`}>Use Sample Repo</a>
</div>
