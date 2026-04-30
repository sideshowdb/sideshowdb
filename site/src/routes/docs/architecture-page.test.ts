import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const architecturePath = join(process.cwd(), 'src/routes/docs/architecture/+page.md')
const readArchitecturePage = () => readFile(architecturePath, 'utf8')

describe('architecture docs page', () => {
  it('uses themed Mermaid diagrams instead of ASCII or custom SVG architecture drawings', async () => {
    const page = await readArchitecturePage()

    for (const diagramId of [
      'architecture-layers-diagram',
      'write-through-composite-diagram',
      'read-fall-through-diagram',
      'write-fan-out-diagram',
    ]) {
      expect(page).toContain('```mermaid diagram=' + diagramId)
    }

    expect(page.match(/```mermaid diagram=/g) ?? []).toHaveLength(4)
    expect(page).toContain('flowchart TD')
    expect(page).not.toContain('<svg')
    expect(page).not.toContain('role="img"')
    expect(page).not.toContain('+----------------------------------------------------------+')
    expect(page).not.toContain('+-----------------+')
    expect(page).not.toContain('read fall-through:\n\n   get(key)')
    expect(page).not.toContain('write fan-out:\n\n   put(key, value)')

    expect(page).toContain('refs/sideshowdb/<section-name>')
    expect(page).toContain('refs/sideshowdb/documents')
  })
})
