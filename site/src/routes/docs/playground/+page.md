---
title: Playground Guide
order: 5
---

The [playground](/playground/) is the evaluator-first surface. It runs
entirely in your browser, fetches public GitHub data without auth, and
explains what Sideshowdb would do with that data.

This page describes what is and is not in scope, how to drive it, and
how the UI maps onto Sideshowdb concepts.

## What the Playground Does

1. Validates the user's `owner/repo` input before any network call.
2. Fetches public GitHub data directly from the browser.
3. Renders a focused explorer of the repository's refs.
4. Renders a Sideshowdb interpretation panel that explains what those
   refs would look like as a projection.

## What the Playground Does Not Do

The first release is intentionally narrow:

- **Public repos only.** No auth, no private data.
- **Read-only.** No write-back to GitHub or to a local Sideshowdb
  store.
- **Limited views.** A small number of focused inspection modes; not a
  generic Git object browser.

## Recommended Path

1. Open [Playground](/playground/).
2. Click the curated sample (`sideshowdb/sideshowdb` or
   `octocat/Hello-World`) to see the happy path first.
3. Once the sample renders, type your own `owner/repo` to compare.

## Input Rules

The repo input is parsed by
[`parseRepoInput`](https://github.com/sideshowdb/sideshowdb/blob/main/site/src/lib/playground/repo-input.ts)
before any fetch. Surrounding whitespace is trimmed. Anything that is
not exactly two non-empty `/`-separated segments is rejected with a
specific validation error.

Examples:

| Input | Result |
| ----- | ------ |
| `sideshowdb/sideshowdb` | accepted |
| `octocat/Hello-World` (with surrounding whitespace) | accepted (trimmed) |
| `octocat` | rejected — needs `owner/repo` |
| `a/b/c` | rejected — too many segments |
| empty string | rejected — needs `owner/repo` |

## Failure Modes

The playground maps known HTTP failures to plain-language messages:

| HTTP status | Meaning | What you'll see |
| ----------- | ------- | --------------- |
| 404 | repo missing or invisible | "not found" + sample-repo fallback |
| 403 | rate limit or access denied | "rate or access" message + retry guidance |
| anything else | unknown failure | generic load-failed message + sample-repo fallback |

## How the UI Maps to Sideshowdb

| UI panel | Sideshowdb concept | Reference |
| -------- | ------------------ | --------- |
| Source-data view (refs list) | Raw `RefStore` source | [`storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore) |
| Projection panel | Derived `DocumentStore` view | [`document.DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore) |
| Sample-repo fallback | Curated entry point so the blank-page case never happens | — |

For an end-to-end mapping of GitHub data to Sideshowdb concepts, see
the [Projection Walkthrough](/docs/projection-walkthrough/).

## Where to Look in the Reference

- [`sideshowdb.storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore)
- [`sideshowdb.document.DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore)
- [`sideshowdb.document.Identity`](/reference/api/index.html#sideshowdb.document.Identity)
- [`sideshowdb.document.deriveKey`](/reference/api/index.html#sideshowdb.document.deriveKey)
