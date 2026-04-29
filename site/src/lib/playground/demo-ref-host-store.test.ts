import { describe, expect, it } from 'vitest'

import { createDemoRefHostStore } from './demo-ref-host-store'

describe('demo ref host store', () => {
  it('supports put, list, history, and delete for the wasm document demo', async () => {
    const connector = createDemoRefHostStore()

    const first = await connector.put('documents/default/issue/demo.json', '{"title":"one"}')
    await connector.put('documents/default/issue/demo.json', '{"title":"two"}')

    expect(await connector.list()).toContain('documents/default/issue/demo.json')
    expect(await connector.history('documents/default/issue/demo.json')).toEqual([
      expect.any(String),
      first,
    ])

    await connector.delete('documents/default/issue/demo.json')
    expect(await connector.get('documents/default/issue/demo.json')).toBeNull()
  })
})
