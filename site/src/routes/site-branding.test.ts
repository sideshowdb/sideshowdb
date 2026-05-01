import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const faviconPath = join(process.cwd(), 'static/favicon.svg')

describe('site branding assets', () => {
  it('uses the selected Core A carousel icon as the favicon', async () => {
    const favicon = await readFile(faviconPath, 'utf8')

    expect(favicon).toContain('viewBox="0 0 512 512"')
    expect(favicon).toContain('#009c98')
    expect(favicon).toContain('#ffb000')
    expect(favicon).toContain('#2e8deb')
    expect(favicon).toContain('carousel canopy')
  })
})
