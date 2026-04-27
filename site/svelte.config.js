import adapter from '@sveltejs/adapter-static'
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte'

/** @type {import('@sveltejs/kit').Config} */
const config = {
  extensions: ['.svelte', '.md'],
  preprocess: [vitePreprocess()],
  kit: {
    adapter: adapter({
      pages: 'dist',
      assets: 'dist',
      fallback: '404.html',
    }),
    paths: {
      base: process.env.BASE_PATH ?? '',
      relative: false,
    },
    prerender: {
      handleHttpError: ({ path, referrer, message }) => {
        const base = process.env.BASE_PATH ?? ''
        if (path === `${base}/reference/` || path === `${base}/reference`) {
          return
        }
        throw new Error(`${message} (linked from ${referrer})`)
      },
    },
  },
  compilerOptions: {
    runes: true,
  },
}

export default config
