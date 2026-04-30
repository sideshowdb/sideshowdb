import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const repoRoot = join(process.cwd(), '..')
const appCssPath = join(repoRoot, 'site/src/app.css')
const rendererPath = join(repoRoot, 'site/src/lib/components/MermaidRenderer.svelte')
const architecturePath = join(repoRoot, 'site/src/routes/docs/architecture/+page.md')

describe('architecture Mermaid sizing', () => {
  it('keeps rendered diagrams proportional to the surrounding docs text', async () => {
    const [appCss, renderer, architecturePage] = await Promise.all([
      readFile(appCssPath, 'utf8'),
      readFile(rendererPath, 'utf8'),
      readFile(architecturePath, 'utf8'),
    ])

    expect(renderer).toContain("fontSize: '13px'")
    expect(renderer).toContain('nodeSpacing: 30')
    expect(renderer).toContain('rankSpacing: 36')

    expect(appCss).toContain('--docs-mermaid-max-width: 34rem')
    expect(appCss).toContain('--docs-mermaid-max-width: 28rem')
    expect(appCss).toContain('width: min(100%, calc(var(--docs-mermaid-max-width) + 3rem))')
    expect(appCss).toContain("data-mermaid-diagram='architecture-layers-diagram'")
    expect(appCss).toContain("data-mermaid-diagram='write-fan-out-diagram'")

    expect(architecturePage).toContain('put["put(key, value)"]')
    expect(architecturePage).not.toContain('put["put<br/>key, value"]')
  })
})
