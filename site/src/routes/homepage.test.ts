import { render, screen } from '@testing-library/svelte'
import { describe, expect, it } from 'vitest'
import HomePage from './+page.svelte'

describe('homepage', () => {
  it('renders the primary playground CTA above the fold', () => {
    render(HomePage)
    expect(screen.getByRole('button', { name: 'Try Playground' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Use Sample Repo' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Open Playground' })).toBeTruthy()
    expect(screen.getByText(/Git is the source of truth/i)).toBeTruthy()
    expect(screen.getByAltText('SideshowDB carousel database logo')).toBeTruthy()
    expect(screen.getByText(/refs, documents, and views moving together/i)).toBeTruthy()
  })
})
