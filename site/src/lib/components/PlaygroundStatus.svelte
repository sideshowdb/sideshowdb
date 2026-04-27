<script lang="ts">
  let {
    title,
    message,
    detail = '',
    tone = 'neutral',
  }: {
    title: string
    message: string
    detail?: string
    tone?: 'neutral' | 'loading' | 'error'
  } = $props()
</script>

<section
  class={`playground-status playground-status--${tone}`}
  role={tone === 'error' ? 'alert' : 'status'}
  aria-live="polite"
>
  <h2>{title}</h2>
  <p>{message}</p>
  {#if detail}
    <p>{detail}</p>
  {/if}
</section>
