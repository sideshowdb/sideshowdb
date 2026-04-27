<script lang="ts">
  import type { ExplorerModel } from '$lib/playground/explorer'

  let { model }: { model: ExplorerModel } = $props()
</script>

<section class="repo-explorer">
  <header>
    <h2>{model.fullName}</h2>
    {#if model.description}
      <p>{model.description}</p>
    {/if}
    <p>
      Default branch:
      <code>{model.defaultBranch}</code>
      · Visibility:
      <code>{model.visibility}</code>
    </p>
    <p>{model.explanation}</p>
  </header>

  <div>
    <h3>Refs</h3>
    <ul>
      {#each model.refs as ref}
        <li>
          <code>{ref.name}</code>
          <span> -> </span>
          <code>{ref.shortTarget}</code>
        </li>
      {/each}
    </ul>
  </div>
</section>
