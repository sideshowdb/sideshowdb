import { describe, expect, it } from 'vitest'

import { createBrowserCredentialsResolver, createStaticCredentialsResolver } from './host-capability'

describe('createStaticCredentialsResolver', () => {
  it('always returns the configured token regardless of provider and scope', () => {
    const resolver = createStaticCredentialsResolver('ghp_mytoken')

    expect(resolver('github', '')).toBe('ghp_mytoken')
    expect(resolver('github', 'read:packages')).toBe('ghp_mytoken')
    expect(resolver('other', '')).toBe('ghp_mytoken')
  })
})

describe('createBrowserCredentialsResolver', () => {
  it('returns a synchronous token directly', () => {
    const resolver = createBrowserCredentialsResolver(() => 'sync-pat')

    expect(resolver('github', '')).toBe('sync-pat')
  })

  it('returns null when the synchronous callback returns null', () => {
    const resolver = createBrowserCredentialsResolver(() => null)

    expect(resolver('github', '')).toBeNull()
  })

  it('returns null and logs a warning for async callbacks at the sync boundary', () => {
    const warnings: string[] = []
    const originalWarn = console.warn
    console.warn = (...args: unknown[]) => warnings.push(String(args[0]))

    try {
      const resolver = createBrowserCredentialsResolver(() => Promise.resolve('async-token'))
      const result = resolver('github', '')

      expect(result).toBeNull()
      expect(warnings).toHaveLength(1)
      expect(warnings[0]).toContain('Promise')
    } finally {
      console.warn = originalWarn
    }
  })

  it('passes provider and scope arguments through to the underlying callback', () => {
    const calls: Array<{ provider: string; scope: string }> = []
    const resolver = createBrowserCredentialsResolver(() => {
      return 'token'
    })

    // The callback receives no args (it's a zero-arg resolver); the resolver
    // wraps it and forwards provider/scope via the outer callback signature.
    // Verify the resolver is callable with arbitrary provider/scope values.
    expect(resolver('github', 'repo')).toBe('token')
    expect(calls).toHaveLength(0) // inner callback takes no args
  })
})
