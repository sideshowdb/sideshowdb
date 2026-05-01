import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const routePath = join(process.cwd(), 'src/routes/branding/+page.svelte')
const navPath = join(process.cwd(), 'src/lib/content/nav.ts')

describe('branding page', () => {
  it('publishes carousel brand assets and links them from top navigation', async () => {
    const [page, nav] = await Promise.all([
      readFile(routePath, 'utf8'),
      readFile(navPath, 'utf8'),
    ])

    expect(nav).toContain("{ title: 'Branding', to: '/branding/' }")
    expect(page).toContain('SideshowDB Brand')
    expect(page).toContain('/assets/brand/raster/sideshowdb-carousel-refinements-strip.png')
    expect(page).toMatch(
      /\.asset-actions \{\s+grid-column: 1 \/ -1;\s+display: grid;\s+width: 100%;\s+grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/
    )
    expect(page).toContain('min-width: 0;')
    expect(page).toContain('overflow-wrap: anywhere;')
    expect(page).not.toContain('grid-template-columns: repeat(2, minmax(9rem, 1fr));')

    for (const asset of [
      'carousel-database-core-a',
      'carousel-database-core-b',
      'ticket-ring-carousel-a',
      'ticket-ring-carousel-b',
    ]) {
      expect(page).toContain(`/assets/brand/raster/${asset}.png`)
      expect(page).toContain(`/assets/brand/raster-transparent/${asset}.png`)
      expect(page).toContain(`/assets/brand/raster/${asset}-logo.png`)
      expect(page).toContain(`/assets/brand/raster-transparent/${asset}-logo.png`)
      expect(page).toContain(`/assets/brand/svg/${asset}-icon.svg`)
      expect(page).toContain(`/assets/brand/svg/${asset}-logo.svg`)
    }
  })
})
