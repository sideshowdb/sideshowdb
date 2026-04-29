---
title: Projection Walkthrough
order: 5
---

This walkthrough takes a real public GitHub repository and maps it onto
Sideshowdb concepts step by step. The goal is to make the model concrete
before you reach for the playground or the CLI.

We use [`octocat/Hello-World`](https://github.com/octocat/Hello-World)
because it is small, public, stable, and unauthenticated.

## Step 1 — Pick a Section

Sideshowdb keeps every kind of derived state in its own ref:

```text
refs/sideshowdb/<section-name>
```

For this walkthrough we treat each repository as its own document
addressable by `(namespace = "github", doc_type = "repo", id =
"<owner>/<name>")`. The CLI's current document slice already uses
`refs/sideshowdb/documents`, so we'll reuse that section.

The interface boundary is
[`storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore). On a
local checkout we satisfy it with
[`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore);
in the browser playground we satisfy it with public GitHub fetches plus
a thin in-memory shim.

## Step 2 — Fetch the Source Data

The browser playground hits two public endpoints:

```text
GET https://api.github.com/repos/octocat/Hello-World
GET https://api.github.com/repos/octocat/Hello-World/git/matching-refs/heads
```

The first response describes the repository (full name, default branch,
description). The second enumerates branch refs.

Excerpt of the second response:

```json
[
  {
    "ref": "refs/heads/master",
    "object": { "sha": "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d" }
  },
  {
    "ref": "refs/heads/octocat-patch-1",
    "object": { "sha": "b1b3f9723831141a31a1a7252a213e216ea76e56" }
  }
]
```

This is the raw "source data" view — what GitHub itself sees.

## Step 3 — Identify

Map the repository to a Sideshowdb
[`Identity`](/reference/api/index.html#sideshowdb.document.Identity):

```text
namespace = "github"
doc_type  = "repo"
id        = "octocat/Hello-World"
```

The canonical key produced by
[`document.deriveKey`](/reference/api/index.html#sideshowdb.document.deriveKey)
is therefore:

```text
github/repo/octocat/Hello-World.json
```

Every byte of derived state for this repo lives under that key in the
Sideshowdb ref tree.

## Step 4 — Project

Building the projection is the core idea. The reducer takes the GitHub
source data and emits one document envelope. A minimal projection might
produce:

```json
{
  "namespace": "github",
  "type": "repo",
  "id": "octocat/Hello-World",
  "version": "<commit-sha-on-the-sideshowdb-ref>",
  "data": {
    "fullName": "octocat/Hello-World",
    "defaultBranch": "master",
    "branches": [
      { "name": "refs/heads/master",         "sha": "7fd1a60b..." },
      { "name": "refs/heads/octocat-patch-1","sha": "b1b3f972..." }
    ]
  }
}
```

In the browser playground today, this projection is built in-memory by
TypeScript code and rendered in the projection panel. In a fuller
implementation, the same shape would be persisted to
`refs/sideshowdb/documents` via
[`DocumentStore.put`](/reference/api/index.html#sideshowdb.document.DocumentStore.put)
on the local clone.

## Step 5 — Read Back

Reading the projection back is symmetric:

```bash
sideshowdb doc get \
  --namespace github \
  --type repo \
  --id octocat/Hello-World
```

That call fans out through the CLI to
[`DocumentStore.get`](/reference/api/index.html#sideshowdb.document.DocumentStore.get),
through
[`storage.RefStore.get`](/reference/api/index.html#sideshowdb.storage.RefStore.get),
and ultimately to `git cat-file -p <ref>:github/repo/octocat/Hello-World.json`.

If you supply `--version <sha>` the read pins to a historical commit on
the section ref. Without `--version` the read uses the current tip.

## Step 6 — Iterate Without Fear

Because the projection is derived state, you can:

- Delete the local clone — re-`git fetch` rebuilds the section.
- Change the reducer — re-run projection, get a new commit on the
  section ref, old shapes still exist in history.
- Branch and merge — Sideshowdb refs branch/merge like any other Git
  ref.

The source-of-truth invariant ("Git holds canonical state, projections
never write back") makes this safe. Reducers are free to evolve without
risking the upstream repository.

## Mapping Cheat Sheet

| GitHub concept | Sideshowdb concept | Reference |
| -------------- | ------------------ | --------- |
| Repository | Document identified by `(namespace, doc_type, id)` | [`document.Identity`](/reference/api/index.html#sideshowdb.document.Identity) |
| Branch ref + commit SHA | Source data fed into a reducer | [`storage.RefStore.get`](/reference/api/index.html#sideshowdb.storage.RefStore.get) |
| Result of running reducer | Document envelope (`namespace`, `type`, `id`, `version`, `data`) | [`document.DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore) |
| Projection storage | Sideshowdb ref tree under `refs/sideshowdb/<section>` | [`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore) |
| Committing the projection | A new commit on the section ref returning a `VersionId` | [`storage.RefStore.VersionId`](/reference/api/index.html#sideshowdb.storage.RefStore.VersionId) |

## Try It in the Playground

The playground performs steps 1, 2, and a simplified step 4 in your
browser. See the [Playground Guide](/docs/playground/) for the
evaluator-first walkthrough and how to enter your own `owner/repo`.
