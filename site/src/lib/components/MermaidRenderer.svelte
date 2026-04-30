<script lang="ts">
  import { browser } from '$app/environment'
  import { afterNavigate } from '$app/navigation'
  import { onMount, tick } from 'svelte'

  let pendingFrame: number | undefined
  let observer: MutationObserver | undefined
  let mermaidModule: typeof import('mermaid').default | undefined

  const readVar = (styles: CSSStyleDeclaration, name: string, fallback: string) =>
    styles.getPropertyValue(name).trim() || fallback

  function mermaidThemeVariables() {
    const styles = getComputedStyle(document.documentElement)
    const panel = readVar(styles, '--atlas-card-bg', '#ffffff')
    const panelSoft = readVar(styles, '--atlas-card-bg-soft', panel)
    const preBg = readVar(styles, '--atlas-pre-bg', panelSoft)
    const line = readVar(styles, '--atlas-line', '#d7dee2')
    const accent = readVar(styles, '--atlas-accent', '#ff6b7d')
    const accentStrong = readVar(styles, '--atlas-accent-strong', accent)
    const text = readVar(styles, '--atlas-body-text-strong', '#102027')

    return {
      primaryColor: preBg,
      primaryBorderColor: line,
      primaryTextColor: text,
      secondaryColor: panel,
      secondaryBorderColor: line,
      secondaryTextColor: text,
      tertiaryColor: panelSoft,
      tertiaryBorderColor: line,
      tertiaryTextColor: text,
      noteBkgColor: panelSoft,
      noteTextColor: text,
      noteBorderColor: line,
      lineColor: accent,
      textColor: text,
      mainBkg: panel,
      nodeBorder: line,
      clusterBkg: preBg,
      clusterBorder: line,
      edgeLabelBackground: panel,
      labelBackground: panel,
      titleColor: accentStrong,
      fontFamily:
        "Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
      fontSize: '13px',
    }
  }

  async function renderMermaidDiagrams() {
    if (!browser) return

    await tick()
    const nodes = Array.from(document.querySelectorAll<HTMLElement>('.docs-mermaid .mermaid'))
    if (nodes.length === 0) return

    mermaidModule ??= (await import('mermaid')).default
    mermaidModule.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'base',
      themeVariables: mermaidThemeVariables(),
      flowchart: {
        curve: 'basis',
        htmlLabels: false,
        nodeSpacing: 30,
        rankSpacing: 36,
      },
    })

    for (const node of nodes) {
      const source = node.dataset.mermaidSource ?? node.textContent ?? ''
      node.dataset.mermaidSource = source
      node.removeAttribute('data-processed')
      node.textContent = source
    }

    try {
      await mermaidModule.run({ nodes })
    } catch (error) {
      console.error('Unable to render Mermaid diagrams', error)
    }
  }

  function queueRender() {
    if (!browser) return
    if (pendingFrame !== undefined) {
      cancelAnimationFrame(pendingFrame)
    }
    pendingFrame = requestAnimationFrame(() => {
      pendingFrame = undefined
      void renderMermaidDiagrams()
    })
  }

  afterNavigate(() => queueRender())

  onMount(() => {
    queueRender()
    observer = new MutationObserver(() => queueRender())
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'data-theme', 'style'],
    })

    return () => {
      if (pendingFrame !== undefined) {
        cancelAnimationFrame(pendingFrame)
      }
      observer?.disconnect()
    }
  })
</script>
