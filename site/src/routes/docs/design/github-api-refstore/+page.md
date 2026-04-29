---
title: GitHub API RefStore
order: 1
---

The **GitHub API RefStore** is the primary remote-backed `RefStore`
implementation. It speaks to the GitHub Git Database REST API and runs
identically on native (CLI, server, CI) and in the browser (web page,
Chrome extension), with only the bottom-of-the-stack HTTP transport
differing.

It replaces the earlier plan to grow `ZiggitRefStore` (vendored Zig git
plumbing) into a full in-browser git client. See the
[GitHub API RefStore ADR](https://github.com/sideshowdb/sideshowdb/blob/main/docs/design/adrs/2026-04-29-github-api-refstore.md)
and the
[ziggit deprecation ADR](https://github.com/sideshowdb/sideshowdb/blob/main/docs/design/adrs/2026-04-29-deprecate-ziggit.md)
for the deliberation that led here.

## Why REST over GitHub's Git Database API

SideshowDB's storage shape is **a single git ref carrying commits whose
trees map `key -> blob`**. GitHub already exposes every primitive that
shape needs as plain JSON over HTTPS:

| `RefStore` op | API calls |
| ---- | ---- |
| `put(key, value)` | `POST /git/blobs` -> `POST /git/trees` -> `POST /git/commits` -> `PATCH /git/refs/{ref}` (or `POST /git/refs` on first write) |
| `get(key)` | `GET /git/refs/{ref}` -> `GET /git/commits/{sha}` -> `GET /git/trees/{sha}?recursive=1` -> `GET /git/blobs/{sha}` |
| `get(key, version)` | `GET /git/commits/{version}` -> tree -> blob |
| `list()` | tree-recursive read |
| `delete(key)` | tree-omit + commit + ref update |
| `history(key)` | `GET /repos/{o}/{r}/commits?path={key}&sha={ref}` |

We do not need to implement the git wire protocol, parse pack files,
manage a virtual filesystem, or carry libgit2 — none of which contribute
to the metrics-platform scenarios we ship for first.

## Architecture

```
+------------------------------------------------------------+
|  Public TS API: loadSideshowDbClient                       |
+------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------+
|  sideshowdb.wasm  (single artifact, wasm32-freestanding)   |
|  - DocumentStore, RefStore APIs                            |
|  - MemoryRefStore                                          |
|  - IndexedDB host store (existing, sideshowdb-auk)         |
|  - GitHubApiRefStore                                       |
|      uses HttpTransport indirection                        |
+------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------+
|  hostCapabilities (browser/extension)                      |
|  - hostCapabilities.transport.http                         |
|       host-imported fetch capability                       |
|  - hostCapabilities.credentials                            |
|       PAT resolution from extension/page storage           |
|  - hostCapabilities.store                                  |
|       IndexedDB-backed local cache                         |
+------------------------------------------------------------+
```

Native uses `std.http.Client` directly — no host capabilities required,
no extra link dependencies. The same protocol logic runs in both worlds because
`GitHubApiRefStore` is parameterized by an `HttpTransport` interface.

## `HttpTransport` indirection

```zig
pub const HttpTransport = struct {
    request: *const fn (
        ctx: *anyopaque,
        method: Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        allocator: std.mem.Allocator,
    ) anyerror!Response,
    ctx: *anyopaque,
};
```

- `StdHttpTransport` (native) wraps `std.http.Client` with TLS supplied
  by `std.crypto.tls`.
- `HostHttpTransport` (WASM) calls a `host_http_request` extern reached
  through `hostCapabilities.transport.http`; the host JS does `fetch()`
  and returns the response bytes.

`GitHubApiRefStore` takes an `HttpTransport` at init. Tests inject a
recording fake; mock acceptance servers swap in a localhost mock; the
shape is identical everywhere.

## Versioning and concurrency

- `VersionId` is the **commit SHA** returned by the upstream — the same
  shape `SubprocessGitRefStore` already returns. No `RefStore` consumer
  has to change to read pinned versions.
- `PATCH /git/refs` with `force: false` is the fast-forward gate.
  Concurrent writers compete on it; the loser refreshes parent and
  retries up to `retry_concurrent_writes` times before returning
  `ConcurrentUpdate(other_sha)` so the caller can decide.

## Section namespacing

Callers needing more than one logical store in a repo configure
multiple `GitHubApiRefStore` instances against different ref names
(for example `refs/sideshowdb/<section>/documents` per project). Each
instance is independent on the wire and in the cache layer.

## Where this leaves other backends

| Backend | Role |
| ---- | ---- |
| `MemoryRefStore` | Volatile in-memory store; demos, tests, freestanding entrypoint |
| `IndexedDB host store` | Browser-local persistence and offline cache |
| `GitHubApiRefStore` | Primary remote-backed store, browser + native |
| `SubprocessGitRefStore` | Escape hatch behind `--refstore subprocess` for environments without API access |
| `Libgit2RefStore` (future) | Native-only, planned for non-API git remotes |
| `GitLabApiRefStore`, `BitbucketApiRefStore`, etc. (future) | Same shape as the GitHub adapter, different URL templates |

## Companion design pages

- [Auth model](../auth-model/) — credential sources, scopes, rate-limit posture.
- [Caching](../caching/) — SHA-keyed immutable caches, ETag handling, IDB-backed reuse.
- [Configuration](../configuration/) — every config field, CLI flags, TS bindings.
- [Operations](../operations/) — provisioning a repo, scopes a PAT needs, troubleshooting.
