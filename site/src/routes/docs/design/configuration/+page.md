---
title: Configuration
order: 4
---

This page is the field-by-field reference for configuring
`GitHubApiRefStore` from native CLI/library callers and from the
TypeScript bindings.

It is the configuration companion to the
[GitHub API RefStore design](../github-api-refstore/).

## Selector

The store is one of several `RefStore` implementations selected via
`Config.refstore`:

```zig
pub const RefStoreKind = enum { memory, github, indexeddb, subprocess };

pub const RefStoreSelector = union(RefStoreKind) {
    memory: struct {},
    github: GitHubConfig,
    indexeddb: IndexedDbConfig,
    subprocess: SubprocessConfig,
};
```

`indexeddb` is the existing browser-local persistence path
(`sideshowdb-auk`). `subprocess` is the escape hatch for environments
without API access. `github` is the focus of this page.

## `GitHubConfig`

```zig
pub const GitHubConfig = struct {
    owner: []const u8,
    repo: []const u8,
    ref_name: []const u8 = "refs/sideshowdb/documents",
    api_base: []const u8 = "https://api.github.com",
    user_agent: []const u8 = "sideshowdb/0.x",
    rate_limit: RateLimitPolicy = .surface_to_caller,
    cache: CacheConfig = .{},
    credentials: CredentialSpec = .auto,
    retry_concurrent_writes: u8 = 3,
    history_limit: u32 = 1024,
};
```

| Field | Required | Default | Notes |
| ---- | ---- | ---- | ---- |
| `owner` | yes | — | GitHub user or organization. |
| `repo` | yes | — | Repository name. |
| `ref_name` | no | `refs/sideshowdb/documents` | Single ref the store reads/writes. Use distinct ref names to namespace logical stores in one repo. |
| `api_base` | no | `https://api.github.com` | Override for GitHub Enterprise (`https://github.example.com/api/v3`). |
| `user_agent` | no | `sideshowdb/0.x` | Sent on every request; recommended to include a contact for upstream operators. |
| `rate_limit` | no | `surface_to_caller` | Controls behavior on 403 rate-limit. `wait_until_reset` mode is filed as a future enhancement. |
| `cache` | no | in-memory defaults | See [Caching](../caching/). |
| `credentials` | no | `.auto` | See [Auth model](../auth-model/). |
| `retry_concurrent_writes` | no | `3` | Bounded fast-forward retry budget for `put`/`delete`. |
| `history_limit` | no | `1024` | Cap on commits returned by `history(key)` before pagination stops. |

## `CredentialSpec`

```zig
pub const CredentialSpec = union(enum) {
    auto: void,
    env: []const u8,
    explicit: []const u8,
    keychain: KeychainConfig,
    gh_helper: void,
    git_helper: void,
    host_capability: void,
};
```

`.auto` walks the per-platform priority list documented in
[Auth model](../auth-model/). `.explicit` accepts a raw token but is
intended only for tests and short-lived scripts.

`.host_capability` is the variant browser callers use; it tells the
store to ask the host environment via `hostCapabilities.credentials`.

## CLI surface

```
sideshow doc put my-key < value.json \
  --refstore github \
  --github-owner sideshow \
  --github-repo metrics-store \
  --github-ref refs/sideshowdb/documents
```

Auth is **never accepted as a CLI flag value** because shell history
leaks the token. The CLI walks the auto credential list (env, `gh auth
token`, keychain helper, git helper) and surfaces a helpful error if
nothing resolves.

A config file (`sideshowdb.toml` or equivalent project convention) can
hold every field above and a **reference** to a credential source — for
example an env-var name — but never a literal token.

## TypeScript bindings surface

```ts
const client = await loadSideshowDbClient({
  wasmPath: '/sideshowdb.wasm',
  refstore: {
    kind: 'github',
    owner: 'sideshow',
    repo: 'metrics-store',
    refName: 'refs/sideshowdb/documents',
    credentials: { kind: 'host-capability' },
  },
  hostCapabilities: {
    transport: { http: createBrowserHttpTransport() },
    credentials: createBrowserCredentialsResolver({ provider: 'github' }),
  },
})
```

`hostCapabilities.transport.http` is the HTTP egress capability for the
WASM build. The browser implementation delegates to the global
`fetch`. Tests inject a recording fake.

`hostCapabilities.credentials` resolves a token on demand. Extension
implementations read from `chrome.storage`; web-page implementations
typically prompt the user once and keep the token in session memory.

## Security guidance

- Never commit a config file containing a literal token. Use env-var
  references or platform credential helpers instead.
- Token values are sent only to the configured `api_base`. The store
  does not follow redirects to other hosts.
- For browser deployments serving a public web page, fine-grained
  PATs scoped to a single repository and the minimum scopes
  (`Contents: read` for read-only, `Contents: write` for writers) are
  strongly recommended over classic PATs.
