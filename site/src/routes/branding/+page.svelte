<script module lang="ts">
  export const frontmatter = {
    sidebar: false,
  }
</script>

<script lang="ts">
  import { base } from '$app/paths'

  const asset = (path: string) => `${base}${path}`

  const concepts = [
    {
      name: 'Carousel Database Core A',
      note: 'Primary direction with the strongest database read.',
      iconPng: '/assets/brand/raster/carousel-database-core-a.png',
      iconTransparentPng: '/assets/brand/raster-transparent/carousel-database-core-a.png',
      logoPng: '/assets/brand/raster/carousel-database-core-a-logo.png',
      logoTransparentPng: '/assets/brand/raster-transparent/carousel-database-core-a-logo.png',
      iconSvg: '/assets/brand/svg/carousel-database-core-a-icon.svg',
      logoSvg: '/assets/brand/svg/carousel-database-core-a-logo.svg',
    },
    {
      name: 'Carousel Database Core B',
      note: 'A tighter technical variant with visible ref nodes.',
      iconPng: '/assets/brand/raster/carousel-database-core-b.png',
      iconTransparentPng: '/assets/brand/raster-transparent/carousel-database-core-b.png',
      logoPng: '/assets/brand/raster/carousel-database-core-b-logo.png',
      logoTransparentPng: '/assets/brand/raster-transparent/carousel-database-core-b-logo.png',
      iconSvg: '/assets/brand/svg/carousel-database-core-b-icon.svg',
      logoSvg: '/assets/brand/svg/carousel-database-core-b-logo.svg',
    },
    {
      name: 'Ticket Ring Carousel A',
      note: 'Badge-shaped alternate for GitHub avatars and docs callouts.',
      iconPng: '/assets/brand/raster/ticket-ring-carousel-a.png',
      iconTransparentPng: '/assets/brand/raster-transparent/ticket-ring-carousel-a.png',
      logoPng: '/assets/brand/raster/ticket-ring-carousel-a-logo.png',
      logoTransparentPng: '/assets/brand/raster-transparent/ticket-ring-carousel-a-logo.png',
      iconSvg: '/assets/brand/svg/ticket-ring-carousel-a-icon.svg',
      logoSvg: '/assets/brand/svg/ticket-ring-carousel-a-logo.svg',
    },
    {
      name: 'Ticket Ring Carousel B',
      note: 'Higher-contrast badge alternate with a darker outer frame.',
      iconPng: '/assets/brand/raster/ticket-ring-carousel-b.png',
      iconTransparentPng: '/assets/brand/raster-transparent/ticket-ring-carousel-b.png',
      logoPng: '/assets/brand/raster/ticket-ring-carousel-b-logo.png',
      logoTransparentPng: '/assets/brand/raster-transparent/ticket-ring-carousel-b-logo.png',
      iconSvg: '/assets/brand/svg/ticket-ring-carousel-b-icon.svg',
      logoSvg: '/assets/brand/svg/ticket-ring-carousel-b-logo.svg',
    },
  ]
</script>

<svelte:head>
  <title>SideshowDB Brand | Carousel logo concepts</title>
</svelte:head>

<section class="brand-hero">
  <div>
    <p class="eyebrow">Brand exploration</p>
    <h1>SideshowDB Brand</h1>
    <p class="lede">
      Modern carousel marks for the docs site, GitHub organization, repository
      identity, and future CLI banner work.
    </p>
  </div>
</section>

<section class="brand-strip" aria-labelledby="refinement-strip-heading">
  <div class="section-heading">
    <p class="eyebrow">Selected refinements</p>
    <h2 id="refinement-strip-heading">Carousel concept strip</h2>
  </div>
  <img
    src={asset('/assets/brand/raster/sideshowdb-carousel-refinements-strip.png')}
    alt="Four refined SideshowDB carousel logo concepts"
  />
  <div class="asset-links">
    <a href={asset('/assets/brand/concepts/sideshowdb-carousel-concepts-v1.png')}>First concept board</a>
    <a href={asset('/assets/brand/concepts/sideshowdb-carousel-refinements-v1.png')}>Refined concept board</a>
    <a href={asset('/assets/brand/svg/sideshowdb-carousel-refinements-strip.svg')}>SVG strip</a>
  </div>
</section>

<section class="brand-assets" aria-labelledby="asset-grid-heading">
  <div class="section-heading">
    <p class="eyebrow">Asset candidates</p>
    <h2 id="asset-grid-heading">Icons and logo lockups</h2>
  </div>

  <div class="asset-grid">
    {#each concepts as concept}
      <article class="asset-card">
        <div class="asset-preview">
          <img src={asset(concept.iconSvg)} alt={`${concept.name} icon`} />
        </div>
        <div class="asset-copy">
          <h3>{concept.name}</h3>
          <p>{concept.note}</p>
          <div class="asset-actions" aria-label={`${concept.name} asset links`}>
            <a href={asset(concept.iconPng)}>PNG icon</a>
            <a href={asset(concept.iconTransparentPng)}>Transparent PNG icon</a>
            <a href={asset(concept.iconSvg)}>SVG icon</a>
            <a href={asset(concept.logoPng)}>PNG logo</a>
            <a href={asset(concept.logoTransparentPng)}>Transparent PNG logo</a>
            <a href={asset(concept.logoSvg)}>SVG logo</a>
          </div>
        </div>
      </article>
    {/each}
  </div>
</section>

<style>
  .brand-hero,
  .brand-strip,
  .brand-assets {
    width: min(calc(100% - 2rem), 72rem);
    margin: 0 auto;
  }

  .brand-hero {
    margin-top: clamp(3rem, 7vw, 6rem);
    padding: clamp(2rem, 5vw, 3.5rem) 0 1rem;
  }

  .eyebrow {
    margin: 0 0 0.75rem;
    color: var(--atlas-accent);
    font-size: 0.78rem;
    font-weight: 800;
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }

  h1,
  h2,
  h3,
  p {
    margin-top: 0;
  }

  h1 {
    max-width: 13ch;
    margin-bottom: 1rem;
    color: var(--atlas-body-text-strong);
    font-size: clamp(3rem, 8vw, 6.5rem);
    line-height: 0.92;
  }

  .lede {
    max-width: 42rem;
    color: var(--atlas-body-text-muted);
    font-size: clamp(1.05rem, 1.8vw, 1.35rem);
    line-height: 1.65;
  }

  .brand-strip,
  .brand-assets {
    padding: clamp(2rem, 5vw, 4rem) 0;
  }

  .section-heading {
    margin-bottom: 1.25rem;
  }

  .section-heading h2 {
    color: var(--atlas-body-text-strong);
    font-size: clamp(1.75rem, 4vw, 3rem);
    line-height: 1;
  }

  .brand-strip > img {
    display: block;
    width: 100%;
    border: 1px solid var(--atlas-line);
    border-radius: 0.5rem;
    background: #fff9ec;
    box-shadow: var(--atlas-shadow);
  }

  .asset-links,
  .asset-actions {
    gap: 0.75rem;
  }

  .asset-links {
    display: flex;
    flex-wrap: wrap;
  }

  .asset-actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(9rem, 1fr));
  }

  .asset-links {
    margin-top: 1rem;
  }

  .asset-links a,
  .asset-actions a {
    display: inline-flex;
    min-height: 2.5rem;
    align-items: center;
    border: 1px solid var(--atlas-line);
    border-radius: 0.5rem;
    padding: 0 0.85rem;
    background: var(--atlas-secondary-bg);
    color: var(--atlas-accent-strong);
    font-size: 0.88rem;
    font-weight: 800;
    justify-content: center;
    text-decoration: none;
    text-align: center;
  }

  .asset-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 1rem;
  }

  .asset-card {
    display: grid;
    grid-template-columns: minmax(8rem, 12rem) minmax(0, 1fr);
    gap: 1.25rem;
    align-items: center;
    border: 1px solid var(--atlas-line);
    border-radius: 0.5rem;
    padding: 1rem;
    background: var(--atlas-card-bg);
    box-shadow: 0 14px 36px rgba(12, 47, 56, 0.12);
  }

  .asset-preview {
    display: grid;
    aspect-ratio: 1;
    place-items: center;
    overflow: hidden;
    border: 1px solid var(--atlas-line);
    border-radius: 0.5rem;
    background: #fff9ec;
  }

  .asset-preview img {
    display: block;
    width: 100%;
    height: 100%;
  }

  .asset-copy h3 {
    margin-bottom: 0.5rem;
    color: var(--atlas-body-text-strong);
    font-size: 1.1rem;
  }

  .asset-copy p {
    margin-bottom: 1rem;
    color: var(--atlas-body-text-muted);
    line-height: 1.55;
  }

  @media (max-width: 860px) {
    .asset-grid,
    .asset-card {
      grid-template-columns: 1fr;
    }

    .asset-preview {
      width: min(100%, 18rem);
    }

    .asset-actions {
      grid-template-columns: 1fr;
    }
  }
</style>
