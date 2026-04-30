type CodeNode = {
  type: 'code' | 'html'
  lang?: string
  meta?: string
  value: string
}

type ParentNode = {
  children?: unknown[]
}

const escapeHtml = (value: string) =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll('{', '&#123;')
    .replaceAll('}', '&#125;')

const diagramIdFromMeta = (meta: string | undefined, fallbackIndex: number) => {
  const match = meta?.match(/(?:^|\s)diagram=([A-Za-z0-9_-]+)/)
  return match?.[1] ?? `mermaid-diagram-${fallbackIndex}`
}

export function remarkMermaid() {
  return (tree: unknown) => {
    let diagramCount = 0

    const visitCodeNodes = (node: unknown) => {
      if (!node || typeof node !== 'object') return

      const maybeCode = node as CodeNode
      if (maybeCode.type === 'code') {
        transformCodeNode(maybeCode)
      }

      for (const child of (node as ParentNode).children ?? []) {
        visitCodeNodes(child)
      }
    }

    const transformCodeNode = (node: CodeNode) => {
      if (node.lang !== 'mermaid') return

      diagramCount += 1
      node.type = 'html'
      node.value =
        `<figure class="docs-mermaid" data-mermaid-diagram="${diagramIdFromMeta(node.meta, diagramCount)}">` +
        `<pre class="mermaid">${escapeHtml(node.value)}</pre>` +
        `</figure>`
    }

    visitCodeNodes(tree)
  }
}
