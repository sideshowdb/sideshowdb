import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

const cliReferencePath = join(process.cwd(), 'src/routes/docs/cli/+page.md')
const readRepoFile = (path: string) => readFile(join(process.cwd(), '..', path), 'utf8')
const readCliReference = () => readFile(cliReferencePath, 'utf8')

describe('CLI reference docs', () => {
  it('documents every supported command and option', async () => {
    const page = await readCliReference()

    for (const expected of [
      'title: CLI Reference',
      'sideshow version',
      'sideshow doc put',
      'sideshow doc get',
      'sideshow doc list',
      'sideshow doc delete',
      'sideshow doc history',
      'sideshow event append',
      'sideshow event load',
      'sideshow snapshot put',
      'sideshow snapshot get',
      'sideshow snapshot list',
      '--aggregate-type',
      '--aggregate-id',
      '--expected-revision',
      '--from-revision',
      '--up-to-event-id',
      '--state-file',
      '--metadata-file',
      '--latest',
      '--at-or-before',
      'sideshow auth status',
      'sideshow auth logout',
      'sideshow gh auth login',
      'sideshow gh auth status',
      'sideshow gh auth logout',
      '--json',
      '--refstore subprocess',
      '--repo <owner/name>',
      '--ref <refname>',
      '--with-token',
      '--skip-verify',
      '--host <hostname>',
      '--namespace <namespace>',
      '--type <type>',
      '--id <id>',
      '--data-file <path>',
      '--version <version>',
      '--limit <count>',
      '--cursor <cursor>',
      '--mode <mode>',
      'SIDESHOWDB_REFSTORE',
      '.sideshowdb/config.toml',
      '--data-file wins',
      'A missing or unreadable --data-file path returns exit code 1',
    ]) {
      expect(page).toContain(expected)
    }
  })

  it('is linked from README and Getting Started', async () => {
    const readme = await readRepoFile('README.md')
    const gettingStarted = await readFile(
      join(process.cwd(), 'src/routes/docs/getting-started/+page.md'),
      'utf8',
    )

    expect(readme).toContain('/docs/cli/')
    expect(gettingStarted).toContain('/docs/cli/')
  })
})
