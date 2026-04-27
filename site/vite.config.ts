import { defineConfig } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'
import { svelteTesting } from '@testing-library/svelte/vite'
import { topNav } from './src/lib/content/nav'

const config = {
  plugins: [
    svelteTesting(),
    sveltepress({
      siteConfig: {
        title: 'Sideshowdb',
        description: 'Git-backed local-first data, docs, and a public repo playground.',
      },
      theme: defaultTheme({
        navbar: topNav,
        sidebar: {
          enabled: true,
          roots: ['/docs/'],
        },
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
