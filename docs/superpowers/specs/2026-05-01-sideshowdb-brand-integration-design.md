# SideshowDB Brand Integration Design

## Context

SideshowDB has four carousel brand candidates saved under
`site/static/assets/brand/`. The selected direction is the hero-forward Core A
carousel identity. After review, the logo art belongs in the site header rather
than inside the homepage hero, so the header shall carry the brand mark while
the homepage preserves the playground-oriented hero.

Tracked by `sideshowdb-ohc`.

## Direction

Use the **Carousel Database Core A** mark as the primary site identity.

- Primary icon: `/assets/brand/svg/carousel-database-core-a-icon.svg`
- Primary logo lockup: `/assets/brand/svg/carousel-database-core-a-logo.svg`
- Raster fallback/preview: `/assets/brand/raster-transparent/carousel-database-core-a-logo.png`

The brand shall feel colorful and memorable, but not make technical pages
harder to scan.

## Homepage

The homepage shall stay focused on the playground workflow above the fold.

- Keep the current Git-backed/local-first value proposition.
- Keep the existing repo form and playground entry path visible above the fold.
- Do not place the Core A logo lockup in the hero.

## Site Chrome

The site shell shall use the Core A icon as a compact identity marker where the
layout provides a stable location.

- Replace the current favicon with the Core A SVG icon.
- Configure the SveltePress theme logo to use the Core A SVG icon next to the
  top-level `SideshowDB` title.
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

- Homepage tests shall assert the hero does not contain the Core A logo lockup.
- Site branding tests shall assert the SveltePress theme logo uses the Core A
  SVG icon.
- Favicon tests shall assert the favicon uses the Core A SVG structure or asset
  identity.
- Branding page tests shall continue to cover the saved asset links.

## Out Of Scope

- CLI ASCII art banner.
- Choosing a different final logo.
- Reworking the full SveltePress theme.
- Generating additional art assets.
