import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const architecturePath = join(process.cwd(), 'src/routes/docs/architecture/+page.md')
const readArchitecturePage = () => readFile(architecturePath, 'utf8')

describe('architecture docs page', () => {
  it('uses accessible SVG diagrams instead of ASCII architecture drawings', async () => {
    const page = await readArchitecturePage()

    for (const diagramId of [
      'architecture-layers-diagram',
      'write-through-composite-diagram',
      'read-fall-through-diagram',
      'write-fan-out-diagram',
    ]) {
      expect(page).toContain(`id="${diagramId}"`)
    }

    expect(page.match(/<figure class="[^"]*docs-diagram/g) ?? []).toHaveLength(4)
    expect(page.match(/<svg[^>]+role="img"/g) ?? []).toHaveLength(4)
    expect(page).not.toContain('+----------------------------------------------------------+')
    expect(page).not.toContain('+-----------------+')
    expect(page).not.toContain('read fall-through:\n\n   get(key)')
    expect(page).not.toContain('write fan-out:\n\n   put(key, value)')

    expect(page).toContain('refs/sideshowdb/<section-name>')
    expect(page).toContain('refs/sideshowdb/documents')
  })
})
