<script lang="ts">
  let {
    title = 'SideshowDB interpretation',
    repoName = 'sideshowdb/sideshowdb',
    body = 'This panel explains how the fetched repository data maps into derived SideshowDB views.',
    runtimeBanner = '',
    runtimeVersion = '',
  }: {
    title?: string
    repoName?: string
    body?: string
    runtimeBanner?: string
    runtimeVersion?: string
  } = $props()
</script>

<aside class="projection-panel">
  <h2>{title}</h2>
  <p>
    Featured public repo:
    <code>{repoName}</code>
  </p>
  <p>{body}</p>

  {#if runtimeBanner}
    <p>
      Runtime:
      <code>{runtimeBanner}</code>
      {#if runtimeVersion}
        <span> v{runtimeVersion}</span>
      {/if}
    </p>
  {/if}
</aside>
