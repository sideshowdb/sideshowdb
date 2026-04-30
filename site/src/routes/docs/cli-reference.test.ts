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
      'sideshowdb [--json] [--refstore <backend>] <SUBCOMMAND>',
      'sideshowdb version',
      'sideshowdb doc put',
      'sideshowdb doc get',
      'sideshowdb doc list',
      'sideshowdb doc delete',
      'sideshowdb doc history',
      '--json',
      '--refstore subprocess',
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
