import { render, screen } from '@testing-library/svelte'
import { describe, expect, it } from 'vitest'

import PlaygroundPage from './playground/+page.svelte'

describe('playground page', () => {
  it('renders the sample repo path and a projection explanation panel', () => {
    render(PlaygroundPage)

    expect(screen.getByText(/sideshowdb\/sideshowdb/i)).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Sideshowdb interpretation' })).toBeTruthy()
  })
})
