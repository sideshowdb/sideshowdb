import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'

const config = {
  plugins: [
    sveltepress({
      theme: defaultTheme({
        navbar: [
          { title: 'Home', to: '/' },
        ],
        github: 'https://github.com/sideshowdb/sideshowdb',
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
