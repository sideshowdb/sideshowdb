<script lang="ts">
  let { actionHref = '/playground/', sampleRepo = 'sideshowdb/sideshowdb' } = $props()
</script>

<div class="hero-actions">
  <a class="primary" href={actionHref}>Try Playground</a>
  <a class="secondary" href={`/playground/?repo=${sampleRepo}`}>Use Sample Repo</a>
</div>
