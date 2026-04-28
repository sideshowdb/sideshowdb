import { describe, expect, it } from 'vitest'

import { createDemoRefHostBridge } from './demo-ref-host-bridge'

describe('demo ref host bridge', () => {
  it('supports put, list, history, and delete for the wasm document demo', async () => {
    const bridge = createDemoRefHostBridge()

    const first = await bridge.put('documents/default/issue/demo.json', '{"title":"one"}')
    await bridge.put('documents/default/issue/demo.json', '{"title":"two"}')

    expect(await bridge.list()).toContain('documents/default/issue/demo.json')
    expect(await bridge.history('documents/default/issue/demo.json')).toEqual([
      expect.any(String),
      first,
    ])

    await bridge.delete('documents/default/issue/demo.json')
    expect(await bridge.get('documents/default/issue/demo.json')).toBeNull()
  })
})
