import { defineConfig, type PluginOption } from 'vite'
import { sveltepress } from '@sveltepress/vite'
import { defaultTheme } from '@sveltepress/theme-default'
import { svelteTesting } from '@testing-library/svelte/vite'
import { topNav } from './src/lib/content/nav'

const referenceStaticFallback: PluginOption = {
  name: 'sideshowdb:reference-static-fallback',
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (!req.url) {
        next()
        return
      }
      const [pathname, search = ''] = req.url.split('?', 2)
      if (pathname === '/reference/api' || pathname === '/reference/api/') {
        req.url = '/reference/api/index.html' + (search ? `?${search}` : '')
      }
      next()
    })
  },
  configurePreviewServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (!req.url) {
        next()
        return
      }
      const [pathname, search = ''] = req.url.split('?', 2)
      if (pathname === '/reference/api' || pathname === '/reference/api/') {
        req.url = '/reference/api/index.html' + (search ? `?${search}` : '')
      }
      next()
    })
  },
}

const config = {
  plugins: [
    referenceStaticFallback,
    svelteTesting(),
    sveltepress({
      siteConfig: {
        title: 'SideshowDB',
        description: 'Git-backed local-first data, docs, and a public repo playground.',
      },
      theme: defaultTheme({
        navbar: topNav,
        sidebar: {
          enabled: true,
          roots: ['/docs/'],
        },
        github: 'https://github.com/sideshowdb/sideshowdb',
        highlighter: {
          languages: [
            'svelte',
            'sh',
            'bash',
            'js',
            'ts',
            'html',
            'css',
            'scss',
            'md',
            'json',
            'zig',
          ],
        },
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
