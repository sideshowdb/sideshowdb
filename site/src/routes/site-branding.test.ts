import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const faviconPath = join(process.cwd(), 'static/favicon.svg')
const viteConfigPath = join(process.cwd(), 'vite.config.ts')
const appCssPath = join(process.cwd(), 'src/app.css')

describe('site branding assets', () => {
  it('uses the selected Core A carousel icon as the favicon', async () => {
    const favicon = await readFile(faviconPath, 'utf8')

    expect(favicon).toContain('viewBox="0 0 512 512"')
    expect(favicon).toContain('#009c98')
    expect(favicon).toContain('#ffb000')
    expect(favicon).toContain('#2e8deb')
    expect(favicon).toContain('carousel canopy')
  })

  it('uses the Core A carousel logo lockup in the home title slot', async () => {
    const appCss = await readFile(appCssPath, 'utf8')

    expect(appCss).toContain(".home-page .gradient-title")
    expect(appCss).toContain(
      "background: url('/assets/brand/raster-transparent/carousel-database-core-a-logo.png')"
    )
    expect(appCss).toContain('font-size: 0;')
  })

  it('does not add a separate Core A icon to the top navigation', async () => {
    const config = await readFile(viteConfigPath, 'utf8')

    expect(config).not.toContain("logo: '/assets/brand/svg/carousel-database-core-a-icon.svg'")
  })
})
