# SideshowDB Brand Integration Design

## Context

SideshowDB has four carousel brand candidates saved under
`site/static/assets/brand/`. The selected direction is the Core A carousel
identity. The logo art belongs in the SveltePress homepage title slot: the
large gradient `SideshowDB` word above the site description. It should not be a
separate image inside the custom playground hero, and it should not add a second
brand mark to the top navigation.

Tracked by `sideshowdb-ohc` and corrected by `sideshowdb-5x5`.

## Direction

Use the **Carousel Database Core A** mark as the primary site identity.

- Primary icon: `/assets/brand/svg/carousel-database-core-a-icon.svg`
- Primary logo lockup: `/assets/brand/raster-transparent/carousel-database-core-a-logo.png`
- SVG catalog asset: `/assets/brand/svg/carousel-database-core-a-logo.svg`

The transparent PNG lockup is used for the homepage title slot because it
faithfully preserves the approved raster artwork and avoids browser differences
around nested image references inside SVGs.

## Homepage

The homepage shall keep the existing SveltePress title and description structure
while replacing the visible gradient title treatment with the Core A logo
lockup.

- Keep `siteConfig.title` as `SideshowDB` for metadata, accessibility, and theme
  behavior.
- Visually hide the text in `.home-page .gradient-title` without removing the
  element.
- Render the Core A transparent logo lockup as the `.gradient-title` background.
- Keep the description text directly below the logo lockup.
- Keep the custom playground hero focused on the repo form and value
  proposition.

## Site Chrome

The top navigation shall remain text-forward.

- Keep the existing top-level `SideshowDB` nav title behavior.
- Do not configure `defaultTheme.logo` for a separate Core A icon in the header.
- Keep the Core A SVG icon as `site/static/favicon.svg`.

## Documentation And Playground Surfaces

The docs and playground shall use small brand moments only where they aid
orientation.

- Prefer small icons, headers, or callout marks over decorative panels.
- Keep documentation content dense and scannable.
- Do not add carousel art to every markdown page.

## Accessibility And Responsiveness

- The textual `SideshowDB` title remains present in the DOM.
- The visual logo treatment shall not overlap the site description.
- The title-slot logo shall fit on mobile and desktop.
- Brand images shall have useful `alt` text when content-bearing.

## Tests

Update the site tests before implementation.

- Homepage tests shall assert the custom hero does not contain the Core A logo
  lockup.
- Site branding tests shall assert `.home-page .gradient-title` uses the Core A
  transparent logo lockup background and hides the original gradient text.
- Site branding tests shall assert `defaultTheme.logo` is not configured with a
  separate Core A header icon.
- Favicon tests shall assert the favicon uses the Core A SVG structure or asset
  identity.
- Branding page tests shall continue to cover the saved asset links.

## Out Of Scope

- CLI ASCII art banner.
- Choosing a different final logo.
- Reworking the full SveltePress theme.
- Generating additional art assets.
