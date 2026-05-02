---
title: Getting Started
order: 1
---

SideshowDB is a Git-backed local-first database. Git is the source of
truth; local stores and projections are derived views.

This page walks from a clean install to a verifiable end-to-end example
that puts a document and reads it back through the CLI.

The native CLI builds and runs on macOS, Linux, and Windows on `amd64`
and `arm64`. The browser runtime ships as `wasm32-freestanding`.

## Installation

Install options — **Gradle-style wrapper scripts**, **GitHub Releases**,
[mise](https://mise.jdx.dev/), and source builds — are documented on the
[**Installation**](/docs/getting-started/installation/) child page tables
(pinning rules, **`SIDESHOWDB_HOME`** paths, toolchain matrix).

Once `sideshow` is discoverable (**`PATH`**, mise shim, **`./sideshowx`**,
etc.), jump into the guided example below.

To iterate on the Zig/Bun workspaces themselves, see **Build from source**
inside [Installation](/docs/getting-started/installation/).

## End-to-End Example: Put and Get a Document

The CLI stores documents in a Git ref using
[`DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore) on
top of [`GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore).
The example below creates a fresh repository, writes one document, then
reads it back. Document JSON is read from `STDIN`.

The example assumes the `sideshow` binary is on your `PATH` (true
after a release-binary install). For a source build, either run
`export PATH="$PWD/zig-out/bin:$PATH"` from the repo root or substitute
`./zig-out/bin/sideshow` for `sideshow` below.

```bash
# 1. Create a temporary repo for the demo.
mkdir -p /tmp/sideshowdb-demo
cd /tmp/sideshowdb-demo
git init -q
git commit -q --allow-empty -m "init"

# 2. Put a document. JSON comes in on STDIN; identity goes on flags.
echo '{"title":"Hello, sideshow"}' \
  | sideshow doc put --type issue --id doc-1

# 3. Read it back. Output is the stored envelope including a version id.
sideshow doc get --type issue --id doc-1
```

The returned envelope includes `namespace`, `type`, `id`, `version`, and
the original `data` payload — the on-disk shape produced by
[`document.deriveKey`](/reference/api/index.html#sideshowdb.document.deriveKey)
and the put pipeline.

To verify the round-trip, inspect the underlying ref directly:

```bash
git for-each-ref refs/sideshowdb/documents
git cat-file -p refs/sideshowdb/documents:default/issue/doc-1.json
```

The CLI writes to `refs/sideshowdb/documents` so document data cannot
collide with normal `refs/heads/*` work.

## Running the Test Suite

The test suite runs against a source checkout — follow **[Build from
source](/docs/getting-started/installation/#Build-from-source)** first.

```bash
zig build test            # core, integration, CLI, transport, git store
zig build js:test         # Bun workspace tests (bindings + site)
zig build js:check        # Bun workspace typechecks
zig build check:core-docs # public-API doc-comment lint
zig fmt --check .         # source formatting gate
```

CI runs the same gates, so a green local run is a strong signal that a
contribution is ready for review.

## Driving a Remote GitHub Repository

The local-git path above stays at home. To point the same `doc`
commands at a GitHub repository — collaborating across machines,
running from CI, or backing the browser playground — sign in once with
a Personal Access Token and select the GitHub backend:

```bash
# One-time: paste a PAT into a /dev/tty prompt (echo disabled).
sideshow gh auth login

# Or, in CI/headless contexts:
echo "$GITHUB_PAT" | sideshow gh auth login --with-token

# Drive doc commands against a GitHub-hosted ref.
sideshow \
  --refstore github \
  --repo octocat/sideshow-data \
  doc list
```

The token lands in `~/.config/sideshowdb/hosts.toml` with mode `0600`
and is never echoed, never written to argv, and never logged. The full
walkthrough — token scopes, JSON status output, sign-out, and the
security model — is in
[Authenticating to GitHub](/docs/authenticating-to-github/).

## Next Steps

- [Installation](/docs/getting-started/installation/) — release downloads,
  wrapper scripts (`sideshowx`), mise, **`SIDESHOWDB_HOME`** layout, and builds.
- [Authenticating to GitHub](/docs/authenticating-to-github/) — sign in
  once and use `--refstore github` from any machine or CI runner.
- [CLI Reference](/docs/cli/) — every current CLI command, subcommand,
  option, backend selector, and exit behavior.
- [Architecture](/docs/architecture/) — the model behind the CLI and
  WASM surfaces.
- [Concepts](/docs/concepts/) — events, refs, and derived views with
  links into the generated reference.
- [Projection Walkthrough](/docs/projection-walkthrough/) — apply the
  model to a real public repository.
- [Playground Guide](/docs/playground/) — how to use the in-browser
  evaluator experience.
