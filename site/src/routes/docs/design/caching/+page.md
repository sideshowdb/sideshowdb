---
title: Caching
order: 3
---

`GitHubApiRefStore` caches aggressively because git's content-addressed
model makes invalidation free. This page describes the cache layers, why
each exists, and how they interact with the rate-limit budget.

It is the caching companion to the
[GitHub API RefStore design](../github-api-refstore/).

## Why caching is cheap here

Every blob, tree, and commit on the upstream is keyed by a
**SHA-1 / SHA-256 content hash**. Once we have the SHA, the bytes never
change. We never need cache invalidation for those objects — only
eviction policies (size, age) and ref-tip freshness checks.

The only mutable handle is the **ref tip** (`PATCH /git/refs` advances
it). Everything else hangs off the tip and is immutable.

## Cache layers

```
+-------------------------------------------------------------+
|  ref tip cache  (mutable, ETag-validated)                   |
|    key: (repo, ref_name)                                    |
|    value: { commit_sha, etag }                              |
+----------------------------+--------------------------------+
                             v
+-------------------------------------------------------------+
|  commit cache (immutable, SHA-keyed)                        |
|    key: commit_sha                                          |
|    value: { tree_sha, parents, author, committer, ... }     |
+----------------------------+--------------------------------+
                             v
+-------------------------------------------------------------+
|  tree cache (immutable, SHA-keyed)                          |
|    key: tree_sha                                            |
|    value: [ { path, blob_sha, mode } ]                      |
+----------------------------+--------------------------------+
                             v
+-------------------------------------------------------------+
|  blob cache  (immutable, SHA-keyed)                         |
|    key: blob_sha                                            |
|    value: bytes                                             |
+-------------------------------------------------------------+
```

### Ref tip cache

The only layer that requires freshness checks. We use HTTP
**conditional requests**:

- The first read of `GET /git/refs/{ref}` records the response's
  `ETag`.
- Subsequent reads send `If-None-Match: <etag>`.
- A 304 response is **free of rate-limit cost** and serves the cached
  `commit_sha` for downstream walks.
- A 200 response carries a new `ETag`; older descendants are still
  valid (immutable), but the new tip points to a different commit.

### Commit, tree, blob caches

Pure SHA-indexed caches. Once written, never invalidated. Eviction is
LRU bounded by configurable max-bytes. Reads always check the
in-memory cache first; misses fall through to the upstream.

## Storage backends

Two cache backends ship out of the box:

1. **In-memory** (default) — fast, ephemeral, lost on process restart.
   Suitable for short-lived CLI invocations and the hot path inside a
   single browser session.
2. **IndexedDB-backed** (browser, opt-in) — persists across reloads in
   the web page or extension. Reuses the same IndexedDB host store
   plumbing the project already ships for primary persistence (see
   `sideshowdb-auk`); the cache is a separate object store inside the
   same database.

Backend choice is configured via `Config.refstore.github.cache`. See
[Configuration](../configuration/) for the field reference.

## Rate-limit interaction

GitHub's authenticated rate limit is 5,000 requests per hour. Caching
is the primary lever for staying inside it.

- A cold `get(key)` costs 4 requests: ref, commit, tree, blob.
- A warm `get(key)` against an unchanged tip costs **1 request** (304
  on the ref) when ETag is enabled.
- A warm `get(key)` after a tip update typically costs 1-3 requests
  depending on which descendants we already had cached.

Successful responses expose `X-RateLimit-Remaining` /
`X-RateLimit-Reset` to the caller via the operation result; observability
tools should record both as a leading indicator of budget pressure.

## Cache poisoning and integrity

Because keys are SHAs that the upstream produces, the cache cannot be
poisoned by adversarial input from the network in any meaningful way:
the SHA we store is the SHA the upstream returned, and we never
re-derive object identities from cached bytes.

Tokens never enter the cache. The cache stores blob bytes, tree
entries, commit metadata, and ref tips — all data the user already has
read access to.
