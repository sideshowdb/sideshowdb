# GitHub API RefStore EARS

This document defines user-facing EARS requirements for the
`GitHubApiRefStore` — a `RefStore` implementation that talks to the
**GitHub Git Database REST API** instead of running git plumbing locally.

It is the primary remote-backed `RefStore` for the metrics platform
scenario where browsers, Chrome extensions, CLIs, and CI workflows all
need read/write access to a single shared store hosted on GitHub.

API symbols (Zig): `GitHubApiRefStore`, `HttpTransport`,
`StdHttpTransport`, `HostBridgeHttpTransport`, `CredentialProvider`.
TypeScript surface: `loadSideshowdbClient({ refstore: { kind: 'github', ... } })`.
**Design rationale:** `docs/design/adrs/2026-04-29-github-api-refstore.md`.
**Companion deprecation ADR:** `docs/design/adrs/2026-04-29-deprecate-ziggit.md`.

## Scope

- Single-ref `RefStore` over a configured `{owner, repo, ref_name}` triple.
- Operations: `put`, `get`, `get(version)`, `list`, `delete`, `history`.
- Credential indirection covering env var, explicit, host bridge, keychain
  (native), and `gh auth token` shell-out (native).
- Identical semantics on native and WASM. Native uses `std.http.Client`;
  WASM uses a host-imported `host_http_request` extern.

Out of scope for this version (tracked separately): rate-limit waiting
policy beyond surface-to-caller, history compaction, GitLab/Bitbucket
adapters, libgit2 native fallback, webhook-driven cache invalidation.

## EARS

### Construction and configuration

- **GHAPI-001**
  When `GitHubApiRefStore` is initialized with `owner`, `repo`,
  `ref_name`, and a configured `CredentialProvider`, the store shall be
  ready to serve `put`, `get`, `list`, `delete`, and `history`.

- **GHAPI-002**
  If `owner` or `repo` is empty, then `GitHubApiRefStore.init` shall
  return `InvalidConfig` and not perform any HTTP request.

- **GHAPI-003**
  When `ref_name` is omitted at construction, the
  `GitHubApiRefStore` shall default to `refs/sideshowdb/documents`.

### Authentication

- **GHAPI-010**
  When any operation is invoked with no credentials configured, the
  `GitHubApiRefStore` shall return `AuthMissing` and shall not initiate
  any HTTP request to the upstream.

- **GHAPI-011**
  If the upstream returns 401, then the `GitHubApiRefStore` shall
  return `AuthInvalid` and shall not retry.

- **GHAPI-012**
  If the upstream returns 403 with body indicating insufficient PAT
  scope, then the `GitHubApiRefStore` shall return `InsufficientScope`
  and shall not retry.

- **GHAPI-013**
  The `GitHubApiRefStore` shall send the configured token only via the
  `Authorization` request header and shall not log the header value at
  any severity.

- **GHAPI-014**
  Where the configured `CredentialSpec` is `gh_helper` and the `gh` CLI
  is unavailable, the native `CredentialProvider` shall return
  `HelperUnavailable` so a fallback source can be tried.

### Put

- **GHAPI-020**
  When `put` is called with a known repo and write-scoped credentials,
  the `GitHubApiRefStore` shall return a `VersionId` equal to the SHA of
  the new commit produced by the upstream.

- **GHAPI-021**
  When `put` is called against a `ref_name` that does not yet exist on
  the upstream, the `GitHubApiRefStore` shall create the ref via
  `POST /git/refs` with the new commit and return its SHA.

- **GHAPI-022**
  When the upstream rejects `PATCH /git/refs` with 422 "not a
  fast-forward" and the configured `retry_concurrent_writes` budget has
  not been exhausted, the `GitHubApiRefStore` shall refresh the parent
  commit and replay the put before returning `ConcurrentUpdate`.

- **GHAPI-023**
  If the value passed to `put` exceeds the upstream blob limit, then the
  `GitHubApiRefStore` shall return `ValueTooLarge` and shall not create
  any blob, tree, or commit.

- **GHAPI-024**
  When `put` succeeds, the `GitHubApiRefStore` shall expose the new
  commit SHA and tree SHA via the result so callers may pin reads.

### Get

- **GHAPI-030**
  When `get` is called with a key present in the latest tree on
  `ref_name`, the `GitHubApiRefStore` shall return the corresponding
  blob bytes.

- **GHAPI-031**
  When `get` is called with a key absent from the latest tree, the
  `GitHubApiRefStore` shall return `null`.

- **GHAPI-032**
  When `get` is called with a `version` that resolves to a commit on the
  upstream and the key exists in that commit's tree, the
  `GitHubApiRefStore` shall return the blob bytes from that historical
  tree.

- **GHAPI-033**
  When `get` is called with a `version` that does not resolve to any
  reachable commit, the `GitHubApiRefStore` shall return `null`.

- **GHAPI-034**
  Where ETag caching is enabled and the upstream returns 304 Not
  Modified for a ref read, the `GitHubApiRefStore` shall serve the
  cached commit/tree without counting against the rate-limit budget.

### List

- **GHAPI-040**
  When `list` is called and `ref_name` exists on the upstream, the
  `GitHubApiRefStore` shall return all blob entries in the latest tree
  reachable from the ref, ordered by path.

- **GHAPI-041**
  When `list` is called and `ref_name` does not exist on the upstream,
  the `GitHubApiRefStore` shall return an empty list and shall not
  return `RefNotFound`.

### Delete

- **GHAPI-050**
  When `delete` is called for a key present in the latest tree, the
  `GitHubApiRefStore` shall produce a new tree without that entry, a
  commit pointing to it, advance `ref_name`, and return the new commit
  SHA.

- **GHAPI-051**
  When `delete` is called for a key absent from the latest tree, the
  `GitHubApiRefStore` shall return `null` and shall not produce a
  commit.

### History

- **GHAPI-060**
  When `history(key)` is called, the `GitHubApiRefStore` shall return
  every commit reachable from `ref_name` in which `key` was put or
  deleted, in chronological put order, with the corresponding `VersionId`
  for each.

- **GHAPI-061**
  When `history(key)` traverses commits paginated by the upstream, the
  `GitHubApiRefStore` shall follow `Link: rel="next"` until exhausted or
  until the configured `history_limit` is reached.

### Rate limiting

- **GHAPI-070**
  If the upstream returns 403 with `X-RateLimit-Remaining: 0`, then the
  `GitHubApiRefStore` shall return `RateLimited` carrying the
  `X-RateLimit-Reset` timestamp and shall not retry.

- **GHAPI-071**
  When any successful response is received, the `GitHubApiRefStore`
  shall expose `X-RateLimit-Remaining` and `X-RateLimit-Reset` to the
  caller via the operation result so observability tools can record
  budget pressure.

### Transport and failure modes

- **GHAPI-080**
  If the upstream returns 5xx, then the `GitHubApiRefStore` shall return
  `UpstreamUnavailable` after at most one bounded retry with backoff.

- **GHAPI-081**
  If the underlying transport reports a network error, then the
  `GitHubApiRefStore` shall return `TransportError` and shall not retry
  beyond the transport's own retry policy.

- **GHAPI-082**
  When the upstream returns 404 for a blob, tree, or commit object that
  the store had just resolved a SHA for, the `GitHubApiRefStore` shall
  return `Corrupt` so the caller can decide whether to surface or
  re-resolve.

## Acceptance Mapping

- **GHAPI-001/002/003** -> `github-api-refstore.feature` / construction scenarios
- **GHAPI-010..014** -> `github-api-auth.feature` / auth scenarios
- **GHAPI-020..024** -> `github-api-refstore.feature` / put scenarios (delivered first)
- **GHAPI-030..034** -> `github-api-refstore.feature` / get scenarios
- **GHAPI-040..041** -> `github-api-refstore.feature` / list scenarios
- **GHAPI-050..051** -> `github-api-refstore.feature` / delete scenarios
- **GHAPI-060..061** -> `github-api-refstore.feature` / history scenarios
- **GHAPI-070..071** -> `github-api-auth.feature` / rate-limit scenarios
- **GHAPI-080..082** -> `github-api-refstore.feature` / transport scenarios
