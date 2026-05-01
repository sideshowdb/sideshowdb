import { createServer, type IncomingMessage, type ServerResponse, type Server } from 'node:http'
import { createHash } from 'node:crypto'

type CommitObject = {
  sha: string
  tree: { sha: string }
  parents: Array<{ sha: string }>
  message: string
}

type TreeEntry = {
  path: string
  mode: string
  type: string
  sha: string
}

type TreeObject = {
  sha: string
  tree: TreeEntry[]
}

type BlobObject = {
  sha: string
  content: string
  encoding: 'base64'
}

export type FailureRule = {
  status: number
  body?: string
  headers?: Record<string, string>
  after_n_requests?: number
  only_for_method?: string
  only_for_path_pattern?: string
}

function sha1(content: string): string {
  return createHash('sha1').update(content).digest('hex')
}

export class GitHubMock {
  private server: Server | null = null
  private refs = new Map<string, string>()
  private commits = new Map<string, CommitObject>()
  private trees = new Map<string, TreeObject>()
  private blobs = new Map<string, BlobObject>()
  private _requestCount = 0
  private _commitCounter = 0
  private failureRules: FailureRule[] = []
  private _url = ''
  private _port = 0

  get url(): string { return this._url }
  get port(): number { return this._port }

  requestCount(): number { return this._requestCount }

  state() {
    return {
      refs: Object.fromEntries(this.refs),
      commits: Object.fromEntries(this.commits),
      trees: Object.fromEntries(this.trees),
      blobs: Object.fromEntries(this.blobs),
    }
  }

  refExists(refName: string): boolean {
    return this.refs.has(refName)
  }

  injectFailure(rule: FailureRule): void {
    this.failureRules.push(rule)
  }

  resetFailures(): void {
    this.failureRules = []
  }

  reset(): void {
    this.refs.clear()
    this.commits.clear()
    this.trees.clear()
    this.blobs.clear()
    this._requestCount = 0
    this._commitCounter = 0
    this.failureRules = []
  }

  async serve(port = 0): Promise<{ url: string; port: number }> {
    return new Promise((resolve, reject) => {
      this.server = createServer((req, res) => {
        this.handleRequest(req, res).catch(err => {
          res.writeHead(500, { 'Content-Type': 'application/json' })
          res.end(JSON.stringify({ message: String(err) }))
        })
      })
      this.server.listen(port, '127.0.0.1', () => {
        const addr = this.server!.address() as { port: number }
        this._port = addr.port
        this._url = `http://127.0.0.1:${addr.port}`
        resolve({ url: this._url, port: this._port })
      })
      this.server.on('error', reject)
    })
  }

  async stop(): Promise<void> {
    return new Promise((resolve, reject) => {
      if (!this.server) return resolve()
      this.server.close(err => (err ? reject(err) : resolve()))
    })
  }

  private async readBody(req: IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = []
      req.on('data', chunk => chunks.push(chunk as Buffer))
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
      req.on('error', reject)
    })
  }

  private respond(res: ServerResponse, status: number, body: unknown): void {
    const payload = JSON.stringify(body)
    res.writeHead(status, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload).toString(),
      'X-RateLimit-Remaining': '4999',
      'X-RateLimit-Reset': '1700000000',
    })
    res.end(payload)
  }

  private checkFailure(method: string, pathname: string): FailureRule | null {
    for (let i = 0; i < this.failureRules.length; i++) {
      const rule = this.failureRules[i]
      const methodMatch =
        !rule.only_for_method || rule.only_for_method.toUpperCase() === method.toUpperCase()
      const pathMatch = !rule.only_for_path_pattern || pathname.includes(rule.only_for_path_pattern)
      const countMatch =
        rule.after_n_requests === undefined || this._requestCount >= rule.after_n_requests
      if (methodMatch && pathMatch && countMatch) {
        this.failureRules.splice(i, 1)
        return rule
      }
    }
    return null
  }

  private async handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
    this._requestCount++
    const method = (req.method ?? 'GET').toUpperCase()
    const rawUrl = req.url ?? '/'
    const questionIdx = rawUrl.indexOf('?')
    const pathname = questionIdx >= 0 ? rawUrl.slice(0, questionIdx) : rawUrl
    const queryString = questionIdx >= 0 ? rawUrl.slice(questionIdx + 1) : ''

    const failure = this.checkFailure(method, pathname)
    if (failure) {
      const body = failure.body ?? JSON.stringify({ message: 'Injected failure' })
      res.writeHead(failure.status, {
        'Content-Type': 'application/json',
        ...failure.headers,
      })
      res.end(body)
      return
    }

    const reposMatch = pathname.match(/^\/repos\/([^/]+)\/([^/]+)\/(.*)$/)
    if (!reposMatch) {
      this.respond(res, 404, { message: 'Not Found' })
      return
    }

    const [, owner, repo, rest] = reposMatch

    // GET /repos/:owner/:repo/git/ref/:refname  (singular — ref tip lookup)
    if (method === 'GET' && rest.startsWith('git/ref/')) {
      const refName = rest.slice('git/ref/'.length)
      const commitSha = this.refs.get(refName)
      if (!commitSha) {
        this.respond(res, 404, { message: 'Reference does not exist' })
        return
      }
      this.respond(res, 200, { ref: refName, object: { sha: commitSha, type: 'commit' } })
      return
    }

    // GET /repos/:owner/:repo/git/commits/:sha
    if (method === 'GET' && rest.startsWith('git/commits/')) {
      const commitSha = rest.slice('git/commits/'.length)
      const commit = this.commits.get(commitSha)
      if (!commit) {
        this.respond(res, 404, { message: 'Not Found' })
        return
      }
      this.respond(res, 200, commit)
      return
    }

    // GET /repos/:owner/:repo/git/trees/:sha  (optional ?recursive=1 ignored — mock always returns full tree)
    if (method === 'GET' && rest.startsWith('git/trees/')) {
      const treeSha = rest.slice('git/trees/'.length)
      const tree = this.trees.get(treeSha)
      if (!tree) {
        this.respond(res, 404, { message: 'Not Found' })
        return
      }
      this.respond(res, 200, tree)
      return
    }

    // GET /repos/:owner/:repo/git/blobs/:sha
    if (method === 'GET' && rest.startsWith('git/blobs/')) {
      const blobSha = rest.slice('git/blobs/'.length)
      const blob = this.blobs.get(blobSha)
      if (!blob) {
        this.respond(res, 404, { message: 'Not Found' })
        return
      }
      this.respond(res, 200, blob)
      return
    }

    // POST /repos/:owner/:repo/git/blobs
    if (method === 'POST' && rest === 'git/blobs') {
      const bodyText = await this.readBody(req)
      const parsed = JSON.parse(bodyText) as { content: string; encoding: string }
      const blobSha = sha1(`blob:${parsed.content}`)
      this.blobs.set(blobSha, { sha: blobSha, content: parsed.content, encoding: 'base64' })
      this.respond(res, 201, {
        sha: blobSha,
        url: `${this._url}/repos/${owner}/${repo}/git/blobs/${blobSha}`,
      })
      return
    }

    // POST /repos/:owner/:repo/git/trees
    if (method === 'POST' && rest === 'git/trees') {
      const bodyText = await this.readBody(req)
      const parsed = JSON.parse(bodyText) as { base_tree?: string; tree: TreeEntry[] }

      let entries: TreeEntry[] = []
      if (parsed.base_tree) {
        const baseTree = this.trees.get(parsed.base_tree)
        if (baseTree) entries = [...baseTree.tree]
      }

      for (const newEntry of parsed.tree) {
        const idx = entries.findIndex(e => e.path === newEntry.path)
        if (idx >= 0) entries[idx] = newEntry
        else entries.push(newEntry)
      }

      const sortedForHash = [...entries].sort((a, b) => a.path.localeCompare(b.path))
      const treeSha = sha1(`tree:${JSON.stringify(sortedForHash)}`)
      const treeObj: TreeObject = { sha: treeSha, tree: entries }
      this.trees.set(treeSha, treeObj)
      this.respond(res, 201, {
        sha: treeSha,
        url: `${this._url}/repos/${owner}/${repo}/git/trees/${treeSha}`,
      })
      return
    }

    // POST /repos/:owner/:repo/git/commits
    if (method === 'POST' && rest === 'git/commits') {
      const bodyText = await this.readBody(req)
      const parsed = JSON.parse(bodyText) as { message: string; tree: string; parents: string[] }
      this._commitCounter++
      const commitSha = sha1(`commit:${this._commitCounter}:${JSON.stringify(parsed)}`)
      const commit: CommitObject = {
        sha: commitSha,
        tree: { sha: parsed.tree },
        parents: parsed.parents.map(p => ({ sha: p })),
        message: parsed.message,
      }
      this.commits.set(commitSha, commit)
      this.respond(res, 201, {
        sha: commitSha,
        url: `${this._url}/repos/${owner}/${repo}/git/commits/${commitSha}`,
      })
      return
    }

    // POST /repos/:owner/:repo/git/refs  (create new ref — first write)
    if (method === 'POST' && rest === 'git/refs') {
      const bodyText = await this.readBody(req)
      const parsed = JSON.parse(bodyText) as { ref: string; sha: string }
      this.refs.set(parsed.ref, parsed.sha)
      this.respond(res, 201, { ref: parsed.ref, object: { sha: parsed.sha, type: 'commit' } })
      return
    }

    // PATCH /repos/:owner/:repo/git/refs/:refname  (update existing ref)
    if (method === 'PATCH' && rest.startsWith('git/refs/')) {
      const refName = rest.slice('git/refs/'.length)
      const bodyText = await this.readBody(req)
      const parsed = JSON.parse(bodyText) as { sha: string; force?: boolean }
      this.refs.set(refName, parsed.sha)
      this.respond(res, 200, { ref: refName, object: { sha: parsed.sha, type: 'commit' } })
      return
    }

    // GET /repos/:owner/:repo/commits?path=:key&sha=:ref  (history — traverses commit chain)
    if (method === 'GET' && rest === 'commits') {
      const params = new URLSearchParams(queryString)
      const path = params.get('path') ?? ''
      const sha = params.get('sha') ?? ''

      const startSha = this.refs.get(sha) ?? (this.commits.has(sha) ? sha : null)
      if (!startSha) {
        this.respond(res, 200, [])
        return
      }

      const result: Array<{ sha: string }> = []
      let current: string | null = startSha
      const visited = new Set<string>()

      while (current && !visited.has(current)) {
        visited.add(current)
        const commit = this.commits.get(current)
        if (!commit) break

        const tree = this.trees.get(commit.tree.sha)
        if (tree) {
          const currentEntry = tree.tree.find(e => e.path === path && e.type === 'blob')
          const parentSha = commit.parents[0]?.sha ?? null
          let changed = false

          if (!parentSha) {
            changed = currentEntry !== undefined
          } else {
            const parentCommit = this.commits.get(parentSha)
            const parentTree = parentCommit ? this.trees.get(parentCommit.tree.sha) : undefined
            const parentEntry = parentTree?.tree.find(e => e.path === path && e.type === 'blob')
            changed = currentEntry?.sha !== parentEntry?.sha
          }

          if (changed) result.push({ sha: current })
        }

        current = commit.parents[0]?.sha ?? null
      }

      this.respond(res, 200, result)
      return
    }

    this.respond(res, 404, { message: `Not Found: ${method} ${pathname}` })
  }
}
