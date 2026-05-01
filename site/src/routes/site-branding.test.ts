import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const faviconPath = join(process.cwd(), 'static/favicon.svg')
const viteConfigPath = join(process.cwd(), 'vite.config.ts')

describe('site branding assets', () => {
  it('uses the selected Core A carousel icon as the favicon', async () => {
    const favicon = await readFile(faviconPath, 'utf8')

    expect(favicon).toContain('viewBox="0 0 512 512"')
    expect(favicon).toContain('#009c98')
    expect(favicon).toContain('#ffb000')
    expect(favicon).toContain('#2e8deb')
    expect(favicon).toContain('carousel canopy')
  })

  it('uses the Core A carousel icon in the site header logo', async () => {
    const config = await readFile(viteConfigPath, 'utf8')

    expect(config).toContain("logo: '/assets/brand/svg/carousel-database-core-a-icon.svg'")
  })
})
