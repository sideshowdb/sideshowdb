import { describe, expect, it } from 'vitest'

import { remarkMermaid } from './remark-mermaid'

describe('remarkMermaid', () => {
  it('converts mermaid code fences into docs Mermaid figures', () => {
    const tree = {
      type: 'root',
      children: [
        {
          type: 'code',
          lang: 'mermaid',
          meta: 'diagram=architecture-layers-diagram',
          value: 'flowchart TD\n  git["Git <truth>"] --> local["Local"]\n  git@{ shape: rect }',
        },
      ],
    }

    const transform = remarkMermaid()
    transform(tree)

    expect(tree.children[0]).toEqual({
      type: 'html',
      lang: 'mermaid',
      meta: 'diagram=architecture-layers-diagram',
      value:
        '<figure class="docs-mermaid" data-mermaid-diagram="architecture-layers-diagram">' +
        '<pre class="mermaid">flowchart TD\n  git[&quot;Git &lt;truth&gt;&quot;] --&gt; local[&quot;Local&quot;]\n  git@&#123; shape: rect &#125;</pre>' +
        '</figure>',
    })
  })
})
