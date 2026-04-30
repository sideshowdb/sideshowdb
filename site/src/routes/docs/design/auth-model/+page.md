---
title: Auth model
order: 2
---

`GitHubApiRefStore` authenticates every request with a token sent as
`Authorization: Bearer <token>`. This page describes where tokens come
from, what scopes they require, and how the store treats them at rest
and in transit.

It is the auth companion to the
[GitHub API RefStore design](../github-api-refstore/).

## Token sources, in priority order

The `CredentialProvider` indirection resolves a token from the first
source that succeeds. Native and WASM walk distinct lists.

### Native

1. **Explicit option** — `Config.refstore.github.credentials = .{ .explicit = "..." }`. Wins over everything. Intended for tests and short-lived scripts.
2. **`GITHUB_TOKEN` environment variable.** Standard CI signal; matches GitHub Actions defaults.
3. **`gh auth token` shell-out.** When the `gh` CLI is installed and the user is logged in, SideshowDB invokes `gh auth token` once per process to capture a fresh token. Behind `--credential-helper gh` (default if `gh` is on `PATH`).
4. **Keychain helper.** macOS Keychain, Linux `secret-tool`, Windows `cred.exe`. Behind `--credential-helper system`.
5. **`git credential fill` shell-out.** Honors the user's existing git credential helper. Behind `--credential-helper git`.

### Browser, Chrome extension

1. **Explicit option** — `loadSideshowDbClient({ refstore: { kind: 'github', credentials: { kind: 'explicit', token } } })`. Demos and integration tests.
2. **`hostCapabilities.credentials`** — host-supplied resolver. Extension implementations read from `chrome.storage`; web pages read from a session token store, an OAuth-device-flow handler, or a user prompt.

The CLI default order is **explicit > env > `gh auth token` > keychain > git helper**. The browser default order is **explicit > host capabilities**.

## Required scopes

| Operation | Classic PAT | Fine-grained PAT |
| ---- | ---- | ---- |
| `get`, `list`, `history` (public repo) | none | none |
| `get`, `list`, `history` (private repo) | `repo` | `Contents: read` |
| `put`, `delete` (public or private) | `repo` | `Contents: write` |

CLI help text and the `loadSideshowDbClient` JSDoc surface these
requirements at the source so misconfigured tokens fail with the right
hint.

## Token handling guarantees

- The Authorization header is **never logged** at any severity. Errors
  that reference upstream failures redact the header.
- Tokens flow through allocators and are zeroed where practical. When a
  token is held for the lifetime of a `GitHubApiRefStore`, it is held in
  exactly one place; rotation requires constructing a new store.
- SideshowDB **never persists tokens to disk on its own**. The user's
  chosen credential helper may persist; that is their decision.
- The token is sent **only** to the configured `api_base`
  (default `https://api.github.com`). The store does not follow
  redirects to other hosts.

## Failure mapping

| Upstream signal | Returned error |
| ---- | ---- |
| 401 (no creds, expired, malformed) | `AuthInvalid` |
| 403 with body indicating insufficient scope | `InsufficientScope` |
| 403 with `X-RateLimit-Remaining: 0` | `RateLimited(reset_at)` |
| 404 on `/git/blobs` POST against valid repo | `RepoNotFoundOrUnauthorized` (GitHub masks both as 404) |

`AuthMissing` is returned synchronously, before any HTTP request, when
the configured `CredentialProvider` produces no token at all.

## Rate-limit posture

Successful responses expose `X-RateLimit-Remaining` and
`X-RateLimit-Reset` to the caller via the operation result. The store
itself does not auto-wait when limits are exhausted; it returns
`RateLimited` carrying the reset timestamp so observability tooling and
batch CLIs can decide what to do. A future `RateLimitPolicy.WaitUntilReset`
mode is filed as a separate ticket.

`If-None-Match` (ETag) is used on ref reads where supported by the
upstream; 304 responses do **not** count against the rate-limit
budget. See [Caching](../caching/) for details.

## Audit and observability

- Every request emits a structured event with method, path, status,
  rate-limit headers, and request ID. The Authorization header is
  always omitted.
- The store exposes an optional `on_request` hook for callers wiring
  the events into a metrics pipeline.
