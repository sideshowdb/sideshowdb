<script module lang="ts">
  export const frontmatter = {
    title: 'Playground',
    sidebar: false,
  }
</script>

<script lang="ts">
  import { browser } from '$app/environment'
  import { afterNavigate } from '$app/navigation'
  import { base } from '$app/paths'
  import { loadSideshowdbClient, type SideshowdbCoreClient } from '@sideshowdb/core'
  import HeroRepoForm from '$lib/components/HeroRepoForm.svelte'
  import PlaygroundStatus from '$lib/components/PlaygroundStatus.svelte'
  import ProjectionPanel from '$lib/components/ProjectionPanel.svelte'
  import RepoExplorer from '$lib/components/RepoExplorer.svelte'
  import { sampleRepos } from '$lib/content/sample-repos'
  import { createDemoRefHostBridge } from '$lib/playground/demo-ref-host-bridge'
  import { buildExplorerModel, type ExplorerModel } from '$lib/playground/explorer'
  import { fetchRepoRefs, fetchRepoSummary } from '$lib/playground/github'
  import { parseRepoInput, type RepoRef } from '$lib/playground/repo-input'

  const featuredRepo = sampleRepos[0]?.fullName ?? 'sideshowdb/sideshowdb'
  const demoBridge = createDemoRefHostBridge()
  const runtimeUnavailableMessage =
    'The public GitHub explorer is ready, but the shipped SideshowDB WASM module is unavailable so the playground is showing fetch-first fallback guidance.'
  const bridgeUnavailableMessage =
    'The playground demo could not access its ref host bridge, so the public GitHub explorer is still available while the binding-backed document walkthrough stays in fallback mode.'
  let requestedRepo = $state('')
  let model = $state<ExplorerModel | null>(null)
  let loadingMessage = $state('')
  let errorMessage = $state('')
  let wasmRuntime = $state<SideshowdbCoreClient | null>(null)
  let demoSummary = $state('')
  let runtimeUnavailable = $state(false)
  let bridgeUnavailable = $state(false)
  let requestVersion = 0

  function summarizeDemoResults(
    demoPut: Awaited<ReturnType<SideshowdbCoreClient['put']>>,
    demoList: Awaited<ReturnType<SideshowdbCoreClient['list']>>,
    demoHistory: Awaited<ReturnType<SideshowdbCoreClient['history']>>,
    demoDelete: Awaited<ReturnType<SideshowdbCoreClient['delete']>>,
  ): string {
    const versions = demoHistory.ok ? demoHistory.value.items.map((item) => item.version) : []
    const latestVersion = demoPut.ok ? demoPut.value.version : 'unavailable'
    const listedId = demoList.ok ? demoList.value.items[0]?.id ?? 'unknown' : 'unknown'
    const deleted = demoDelete.ok ? demoDelete.value.deleted : false

    return `Demo document ${listedId} was written at ${latestVersion}, history shows ${versions.join(', ') || 'no versions'}, and cleanup deleted=${deleted}.`
  }

  function findBridgeFailure(
    results: Array<
      | Awaited<ReturnType<SideshowdbCoreClient['put']>>
      | Awaited<ReturnType<SideshowdbCoreClient['list']>>
      | Awaited<ReturnType<SideshowdbCoreClient['history']>>
      | Awaited<ReturnType<SideshowdbCoreClient['delete']>>
    >,
  ): boolean {
    return results.some((result) => !result.ok && result.error.kind === 'host-bridge')
  }

  function isClientErrorKind(error: unknown, kind: 'runtime-load' | 'host-bridge'): boolean {
    return (
      typeof error === 'object' &&
      error !== null &&
      'kind' in error &&
      error.kind === kind
    )
  }

  function syncRequestedRepo() {
    if (!browser) {
      requestedRepo = ''
      return
    }

    requestedRepo = new URL(window.location.href).searchParams.get('repo') ?? ''
  }

  if (browser) {
    syncRequestedRepo()
    afterNavigate(syncRequestedRepo)
  }

  $effect(() => {
    if (!browser) {
      return
    }

    let cancelled = false

    void loadSideshowdbClient({
      wasmPath: `${base}/wasm/sideshowdb.wasm`,
      hostBridge: demoBridge,
    })
      .then(async (runtime) => {
        const demoPut = await runtime.put({
          type: 'issue',
          id: 'demo-1',
          data: { title: 'demo issue' },
        })
        const demoList = await runtime.list({ type: 'issue' })
        const demoHistory = await runtime.history({ type: 'issue', id: 'demo-1' })
        const demoDelete = await runtime.delete({ type: 'issue', id: 'demo-1' })
        const demoResults = [demoPut, demoList, demoHistory, demoDelete] as const

        if (!cancelled) {
          wasmRuntime = runtime
          runtimeUnavailable = false
          bridgeUnavailable = findBridgeFailure([...demoResults])
          demoSummary = bridgeUnavailable
            ? ''
            : summarizeDemoResults(demoPut, demoList, demoHistory, demoDelete)
        }
      })
      .catch((error) => {
        if (!cancelled) {
          wasmRuntime = null
          demoSummary = ''
          runtimeUnavailable = isClientErrorKind(error, 'runtime-load') || !isClientErrorKind(error, 'host-bridge')
          bridgeUnavailable = isClientErrorKind(error, 'host-bridge')
        }
      })

    return () => {
      cancelled = true
    }
  })

  let selectedRepo: RepoRef | null = $derived.by(() => {
    if (!requestedRepo) {
      return null
    }

    try {
      return parseRepoInput(requestedRepo)
    } catch {
      return null
    }
  })
  let invalidRepoMessage = $derived.by(() => {
    if (!requestedRepo) {
      return ''
    }

    try {
      parseRepoInput(requestedRepo)
      return ''
    } catch (error) {
      return error instanceof Error ? error.message : 'Repository must use owner/repo format.'
    }
  })

  async function loadRepo(repo: RepoRef) {
    const currentRequest = ++requestVersion

    loadingMessage = `Loading ${repo.owner}/${repo.repo} from GitHub...`
    errorMessage = ''
    model = null

    try {
      const [summary, refs] = await Promise.all([fetchRepoSummary(repo), fetchRepoRefs(repo)])

      if (currentRequest !== requestVersion) {
        return
      }

      model = buildExplorerModel({ summary, refs })
      loadingMessage = ''
    } catch (error) {
      if (currentRequest !== requestVersion) {
        return
      }

      loadingMessage = ''
      model = null
      errorMessage =
        error instanceof Error
          ? error.message
          : 'GitHub data could not be loaded right now. Try again or use the sample repo.'
    }
  }

  $effect(() => {
    if (!browser) {
      return
    }

    const repo = selectedRepo
    const invalidMessage = invalidRepoMessage

    if (!requestedRepo) {
      requestVersion += 1
      loadingMessage = ''
      errorMessage = ''
      model = null
      return
    }

    if (!repo) {
      requestVersion += 1
      loadingMessage = ''
      errorMessage = invalidMessage
      model = null
      return
    }

    void loadRepo(repo)
  })
</script>

<div class="playground-page-wrapper">
<section class="hero playground-hero">
  <div class="hero-text">
    <p class="eyebrow">Playground</p>
    <h1>Inspect a public repo through the SideshowDB model.</h1>
    <p class="lede">
      Enter any public GitHub <code>owner/repo</code>. The browser fetches refs and
      summary data directly, then maps them to the SideshowDB interpretation layer.
    </p>
  </div>
  <HeroRepoForm />
</section>

<section class="playground-results" aria-label="Repository results">
  <header class="playground-results-header">
    <p class="eyebrow">Results</p>
    <h2>Repository explorer</h2>
  </header>

  {#if !requestedRepo}
    <PlaygroundStatus
      title="Start with a public GitHub repository"
      message="Enter an owner/repo pair above or pick one of the sample repositories below."
      detail="Private repositories are out of scope for this first static GitHub Pages release."
    />
  {:else if loadingMessage}
    <PlaygroundStatus
      title="Loading repository data"
      message={loadingMessage}
      detail="The playground fetches public GitHub data directly in your browser."
      tone="loading"
    />
  {:else if errorMessage}
    <PlaygroundStatus
      title="This repository is not available in the playground right now"
      message={errorMessage}
      detail="Try one of the sample repositories below to keep exploring the public-repo flow."
      tone="error"
    />
  {:else if model}
    <RepoExplorer {model} />
  {/if}

  <div>
    <h3>Start with a sample repository</h3>
    <ul class="sample-repo-list">
      {#each sampleRepos as repo}
        <li>
          <a href={`${base}/playground/?repo=${encodeURIComponent(repo.fullName)}`}>{repo.label}</a>
          <span> {repo.description}</span>
        </li>
      {/each}
    </ul>
  </div>

  <ProjectionPanel
    repoName={featuredRepo}
    body={model
      ? wasmRuntime
        ? bridgeUnavailable
          ? bridgeUnavailableMessage
          : `The browser runtime is ready to interpret fetched repository data with the shipped SideshowDB WASM module. ${demoSummary}`
        : runtimeUnavailable
          ? runtimeUnavailableMessage
          : bridgeUnavailableMessage
      : bridgeUnavailable
        ? bridgeUnavailableMessage
        : wasmRuntime
          ? `Use the featured sample path or enter your own public owner/repo pair to compare GitHub refs with the SideshowDB interpretation layer. ${demoSummary}`
        : runtimeUnavailable
          ? runtimeUnavailableMessage
          : 'Use the featured sample path or enter your own public owner/repo pair to compare GitHub refs with the SideshowDB interpretation layer.'}
    runtimeBanner={wasmRuntime?.banner ?? ''}
    runtimeVersion={wasmRuntime?.version ?? ''}
  />
</section>
</div>
