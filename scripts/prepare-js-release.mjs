import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const distRoot = path.join(repoRoot, 'dist', 'npm')
const licenseSource = path.join(repoRoot, 'LICENSE')
const releaseVersion = process.env.SIDESHOWDB_JS_RELEASE_VERSION

const packages = [
  {
    name: '@sideshowdb/core',
    sourceDir: path.join(repoRoot, 'bindings', 'typescript', 'sideshowdb-core'),
    stageDir: path.join(distRoot, 'sideshowdb-core'),
  },
  {
    name: '@sideshowdb/effect',
    sourceDir: path.join(repoRoot, 'bindings', 'typescript', 'sideshowdb-effect'),
    stageDir: path.join(distRoot, 'sideshowdb-effect'),
  },
]

await rm(distRoot, { recursive: true, force: true })

const sourcePackages = await Promise.all(
  packages.map(async (pkg) => {
    const packageJsonPath = path.join(pkg.sourceDir, 'package.json')
    const manifest = JSON.parse(await readFile(packageJsonPath, 'utf8'))
    return { ...pkg, manifest }
  }),
)

const coordinatedVersion = releaseVersion ?? sourcePackages[0]?.manifest.version

if (!coordinatedVersion) {
  throw new Error('missing coordinated release version')
}

for (const pkg of sourcePackages) {
  if (pkg.manifest.name !== pkg.name) {
    throw new Error(`${pkg.sourceDir} has unexpected package name ${pkg.manifest.name}`)
  }

  if (pkg.manifest.version !== coordinatedVersion) {
    throw new Error(
      `${pkg.name} version ${pkg.manifest.version} does not match coordinated release version ${coordinatedVersion}`,
    )
  }

  validatePublishMetadata(pkg.manifest, pkg.name)

  await assertFile(path.join(pkg.sourceDir, 'dist', 'index.js'))
  await assertFile(path.join(pkg.sourceDir, 'dist', 'index.d.ts'))
  await assertFile(path.join(pkg.sourceDir, 'README.md'))
}

for (const pkg of sourcePackages) {
  await mkdir(pkg.stageDir, { recursive: true })
  await cp(path.join(pkg.sourceDir, 'dist'), path.join(pkg.stageDir, 'dist'), { recursive: true })
  await pruneTestArtifacts(path.join(pkg.stageDir, 'dist'))
  await cp(path.join(pkg.sourceDir, 'README.md'), path.join(pkg.stageDir, 'README.md'))
  await cp(licenseSource, path.join(pkg.stageDir, 'LICENSE'))

  const stagedManifest = buildPublishManifest(pkg.manifest, coordinatedVersion)
  await writeFile(
    path.join(pkg.stageDir, 'package.json'),
    `${JSON.stringify(stagedManifest, null, 2)}\n`,
  )
}

function validatePublishMetadata(manifest, name) {
  const requiredStringFields = ['description', 'license', 'homepage']

  for (const field of requiredStringFields) {
    if (typeof manifest[field] !== 'string' || manifest[field].trim() === '') {
      throw new Error(`${name} missing ${field}`)
    }
  }

  if (!manifest.repository?.url || !manifest.repository?.directory) {
    throw new Error(`${name} missing repository metadata`)
  }

  if (!manifest.bugs?.url) {
    throw new Error(`${name} missing bugs.url`)
  }

  if (!Array.isArray(manifest.files) || !manifest.files.includes('dist')) {
    throw new Error(`${name} missing dist in files whitelist`)
  }

  if (manifest.publishConfig?.access !== 'public') {
    throw new Error(`${name} missing publishConfig.access=public`)
  }

  if (!manifest.exports?.['.']?.types || !manifest.exports?.['.']?.default) {
    throw new Error(`${name} missing root export metadata`)
  }
}

function buildPublishManifest(manifest, version) {
  const publishManifest = {
    name: manifest.name,
    version,
    type: manifest.type,
    description: manifest.description,
    license: manifest.license,
    homepage: manifest.homepage,
    bugs: manifest.bugs,
    repository: manifest.repository,
    keywords: manifest.keywords,
    files: manifest.files,
    publishConfig: manifest.publishConfig,
    exports: manifest.exports,
  }

  if (manifest.dependencies) {
    publishManifest.dependencies = rewriteDependencies(manifest.dependencies, version)
  }

  return publishManifest
}

function rewriteDependencies(dependencies, version) {
  const rewritten = { ...dependencies }

  if (rewritten['@sideshowdb/core'] === 'workspace:*') {
    rewritten['@sideshowdb/core'] = `^${version}`
  }

  return rewritten
}

async function assertFile(target) {
  let targetStat

  try {
    targetStat = await stat(target)
  } catch (error) {
    throw new Error(`missing required release artifact: ${path.relative(repoRoot, target)}`, {
      cause: error,
    })
  }

  if (!targetStat.isFile()) {
    throw new Error(`expected file: ${path.relative(repoRoot, target)}`)
  }
}

async function pruneTestArtifacts(root) {
  const entries = await readdir(root, { withFileTypes: true })

  for (const entry of entries) {
    const target = path.join(root, entry.name)

    if (entry.isDirectory()) {
      await pruneTestArtifacts(target)
      continue
    }

    if (entry.name.includes('.test.')) {
      await rm(target, { force: true })
    }
  }
}
