<script lang="ts">
  import HeroRepoForm from '$lib/components/HeroRepoForm.svelte'
  import ConceptCardGrid from '$lib/components/ConceptCardGrid.svelte'
</script>

<svelte:head>
  <title>Sideshowdb | Git-backed local-first data</title>
</svelte:head>

<section class="hero">
  <p class="eyebrow">Graph Atlas</p>
  <h1>Understand Sideshowdb by exploring a real repo.</h1>
  <p class="lede">
    Git is the source of truth. Sideshowdb derives documents, refs, and higher-level
    views from repository data.
  </p>
  <HeroRepoForm />
</section>

<section class="why">
  <h2>Why this is different</h2>
  <p>Keep Git-native workflows while projecting repository history into useful views.</p>
</section>

<ConceptCardGrid />
