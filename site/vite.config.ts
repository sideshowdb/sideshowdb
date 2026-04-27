import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'

const config = {
  plugins: [
    sveltepress({
      siteConfig: {
        title: 'Sideshowdb',
        description: 'Git-backed local-first data, docs, and a public repo playground.',
      },
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
    passWithNoTests: true,
  },
} satisfies import('vite').UserConfig & {
  test: {
    environment: string
    passWithNoTests: boolean
  }
}

export default defineConfig(config)
