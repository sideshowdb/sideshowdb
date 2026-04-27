<script lang="ts">
  import { goto } from '$app/navigation'
  import { base } from '$app/paths'
  import { sampleRepos } from '$lib/content/sample-repos'
  import { parseRepoInput } from '$lib/playground/repo-input'

  const defaultSampleRepo = sampleRepos[0]?.fullName ?? 'sideshowdb/sideshowdb'

  let {
    actionHref = '/playground/',
    sampleRepo = defaultSampleRepo,
  }: {
    actionHref?: string
    sampleRepo?: string
  } = $props()

  let repoInput = $state('')
  let errorMessage = $state('')

  $effect(() => {
    if (!repoInput) {
      repoInput = sampleRepo
    }
  })

  function handleSubmit(event: SubmitEvent) {
    event.preventDefault()

    try {
      const { owner, repo } = parseRepoInput(repoInput)
      const normalizedRepo = `${owner}/${repo}`

      repoInput = normalizedRepo
      errorMessage = ''
      void goto(`${base}${actionHref}?repo=${encodeURIComponent(normalizedRepo)}`)
    } catch (error) {
      errorMessage =
        error instanceof Error ? error.message : 'Repository must use owner/repo format.'
    }
  }
</script>

<form class="hero-form" method="GET" action={`${base}${actionHref}`} onsubmit={handleSubmit} novalidate>
  <label for="hero-repo-input">Enter a public GitHub repo</label>
  <div class="hero-actions">
    <input
      id="hero-repo-input"
      name="repo"
      bind:value={repoInput}
      autocapitalize="none"
      autocomplete="off"
      autocorrect="off"
      placeholder="owner/repo"
      spellcheck="false"
    />
    <button class="primary" type="submit">Try Playground</button>
    <a class="secondary" href={`${base}${actionHref}?repo=${encodeURIComponent(sampleRepo)}`}>
      Use Sample Repo
    </a>
  </div>
  <p>Public GitHub repositories only in v1.</p>
  {#if errorMessage}
    <p role="alert">{errorMessage}</p>
  {/if}
</form>
