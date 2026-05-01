# SideshowDB Brand Integration Design

## Context

SideshowDB has four carousel brand candidates saved under
`site/static/assets/brand/`. The selected direction is the hero-forward Core A
carousel identity: the homepage shall make the logo art an immediate
first-viewport signal while preserving the site as a usable docs and playground
surface.

Tracked by `sideshowdb-ohc`.

## Direction

Use the **Carousel Database Core A** mark as the primary site identity.

- Primary icon: `/assets/brand/svg/carousel-database-core-a-icon.svg`
- Primary logo lockup: `/assets/brand/svg/carousel-database-core-a-logo.svg`
- Raster fallback/preview: `/assets/brand/raster-transparent/carousel-database-core-a-logo.png`

The brand shall feel colorful and memorable, but not make technical pages
harder to scan.

## Homepage

The homepage shall become logo-forward above the fold.

- Place the Core A logo lockup in the hero as a major visual anchor.
- Keep the current Git-backed/local-first value proposition.
- Keep the existing repo form and playground entry path visible above the fold.
- Add a compact brand note that connects the carousel visual to refs,
  documents, and derived views without adding a marketing-only section.

## Site Chrome

The site shell shall use the Core A icon as a compact identity marker where the
layout provides a stable location.

- Replace the current favicon with the Core A SVG icon.
- Add a small brand mark/wordmark treatment near the top-level site navigation
  if the SveltePress layout allows it without fighting the framework.
- Avoid repeating large logos in every page header.

## Documentation And Playground Surfaces

The docs and playground shall use small brand moments only where they aid
orientation.

- Prefer small icons, headers, or callout marks over decorative panels.
- Keep documentation content dense and scannable.
- Do not add carousel art to every markdown page.

## Accessibility And Responsiveness

- Brand images shall have useful `alt` text when content-bearing.
- Decorative repeats shall use empty alt text.
- The hero shall remain readable on mobile and desktop.
- Text shall not overlap brand art or controls.

## Tests

Update the site tests before implementation.

- Homepage tests shall assert the Core A logo appears in the hero.
- Favicon tests shall assert the favicon uses the Core A SVG structure or asset
  identity.
- Branding page tests shall continue to cover the saved asset links.

## Out Of Scope

- CLI ASCII art banner.
- Choosing a different final logo.
- Reworking the full SveltePress theme.
- Generating additional art assets.
