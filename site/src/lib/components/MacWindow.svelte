<script lang="ts">
  let {
    title,
    class: extraClass = '',
    children,
  }: {
    title: string
    class?: string
    children: import('svelte').Snippet
  } = $props()
</script>

<div class={`mac-window${extraClass ? ` ${extraClass}` : ''}`}>
  <div class="mac-window-bar" aria-hidden="true">
    <span class="mac-dot mac-dot-red"></span>
    <span class="mac-dot mac-dot-yellow"></span>
    <span class="mac-dot mac-dot-green"></span>
    <span class="mac-window-title">{title}</span>
  </div>
  {@render children()}
</div>
