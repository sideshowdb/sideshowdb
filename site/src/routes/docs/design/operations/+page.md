---
title: Operations
order: 5
---

This page covers the operator-side concerns of running a SideshowDB
deployment whose primary `RefStore` is `GitHubApiRefStore`:
provisioning a backing repository, choosing PAT scopes, verifying
health, and troubleshooting.

It is the operations companion to the
[GitHub API RefStore design](../github-api-refstore/).

## Provisioning a backing repository

`GitHubApiRefStore` does not require a working tree, a `main` branch,
or any commits in the default branch. It writes to a configured ref
(default `refs/sideshowdb/documents`).

1. **Create the repo.** A regular empty GitHub repository is enough.
   Public is fine if the data is non-sensitive; private otherwise.
2. **Reserve a ref name** distinct from `refs/heads/*` and
   `refs/tags/*` so collaborators cannot accidentally fast-forward it
   with normal `git push`. The default `refs/sideshowdb/documents`
   places the ref under a SideshowDB-owned namespace.
3. **(Optional) Document the ref** in the repo's `README.md` so future
   maintainers know what is writing to it.

The first `put` on a fresh repo creates the ref via `POST /git/refs`.
There is no manual bootstrap.

## Picking a token

| Caller | Recommended token |
| ---- | ---- |
| GitHub Actions workflow on the same repo | the workflow's `secrets.GITHUB_TOKEN`, scope `contents: write` |
| Developer CLI (machine-local) | `gh auth login` then rely on `gh auth token` shell-out |
| Long-running CI (different repo) | Fine-grained PAT, repository-scoped, `Contents: read` or `read+write` |
| Browser web page | Fine-grained PAT pasted into UI; never embedded in JS bundle |
| Chrome extension | Fine-grained PAT stored in `chrome.storage.local` after first launch; surfaced via `hostCapabilities.credentials` |

Avoid classic PATs with `repo` scope unless fine-grained PATs cannot be
used; classic `repo` grants more than `GitHubApiRefStore` ever needs.

## Verifying health

```
sideshowdb doc list \
  --refstore github \
  --github-owner sideshowdb \
  --github-repo metrics-store
```

Expected outcomes:

| Result | Meaning |
| ---- | ---- |
| Empty list, exit 0 | Auth ok, repo exists, no documents yet |
| Non-empty list, exit 0 | Healthy |
| `AuthMissing` | No credential source resolved a token |
| `AuthInvalid` | Token rejected as 401 |
| `InsufficientScope` | Token authenticated but lacks `contents` access |
| `RepoNotFoundOrUnauthorized` | Repo does not exist or token cannot see it (GitHub masks the difference) |
| `RateLimited` | Hit the per-hour budget; `X-RateLimit-Reset` is in the error |

## Troubleshooting

### `AuthInvalid` immediately after issuing a new token

GitHub fine-grained PATs may take up to a minute to propagate. Retry
after a short wait. If the error persists, confirm the PAT was issued
against the correct organization and that the listed repository
includes the target repo (fine-grained PATs are repo-scoped).

### `InsufficientScope` on `put` from a token that worked for `get`

Read paths require `contents: read`; write paths require
`contents: write`. Check the PAT's repository permissions.

### `RateLimited` errors during a CI metrics push

5,000 requests per hour is per-token. Either:

- Cache aggressively at the caller (keep `etag` for the ref between
  invocations).
- Batch many puts behind a single CI aggregator that holds one token
  and serializes writes.
- File a future enhancement ticket to enable the
  `RateLimitPolicy.wait_until_reset` mode.

### `ConcurrentUpdate` after retries exhausted

Two writers are racing on the same ref. Increase
`retry_concurrent_writes`, or partition the writers across distinct
ref names (one ref per logical store) so they no longer contend.

### Pure-Zig TLS fails behind a corporate MITM proxy

`std.http.Client` validates TLS using its own bundled trust roots.
Corporate proxies that present a custom CA fail validation. Either:

- Provide a custom `--ca-bundle` (filed as a configuration enhancement
  ticket) and point it at the corporate trust store.
- Fall back to `--refstore subprocess`, which uses the system git
  binary and the system trust store.

## Capacity planning

- Single blob size: GitHub allows up to **100 MB**, but values larger
  than ~10 MB are an anti-pattern for a key/value store. SideshowDB
  surfaces `ValueTooLarge` for oversized inputs.
- Repo-scoped object count grows linearly with `put`/`delete`; GitHub
  has no hard cap, but UI tools may slow on multi-million-object
  repos. History compaction is filed as a future enhancement and is
  out of scope for v1.
- One reference per logical store keeps blast radius small: revoking
  a writer's PAT or rotating a ref affects only that namespace.
