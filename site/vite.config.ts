import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'

const config = {
  plugins: [
    sveltepress({
      theme: defaultTheme({
        navbar: [
          { title: 'Home', to: '/' },
          { title: 'Docs', to: '/docs/getting-started/' },
          { title: 'Playground', to: '/playground/' },
          { title: 'Reference', to: '/reference/' },
        ],
        github: 'https://github.com/sideshowdb/sideshowdb',
        sidebar: { enabled: true, roots: ['/docs/'] },
      }),
    }),
  ],
  test: {
    environment: 'jsdom',
  },
} satisfies import('vite').UserConfig & {
  test: {
    environment: string
  }
}

export default defineConfig(config)
