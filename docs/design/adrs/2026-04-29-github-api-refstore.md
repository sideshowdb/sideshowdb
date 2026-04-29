# ADR — GitHub API RefStore as the primary remote-backed store

- **Date:** 2026-04-29
- **Status:** Accepted
- **Supersedes:** Earlier intent to grow `ZiggitRefStore` into a real
  in-process git client (issues `sideshowdb-an4`, `sideshowdb-dgz`).
- **Companion ADR:** `2026-04-29-deprecate-ziggit.md`.
- **EARS:** `docs/development/specs/2026-04-29-github-api-refstore-ears.md`.

## 1. Context

Sideshowdb's storage shape is a **single git ref** (or a small set of
section-scoped refs) carrying commits whose tree maps `key -> blob`.
Higher-level features — projections, event indexes, document views —
derive from those refs. The store does **not** need a working tree, a
clone, the commit graph walked from arbitrary points, packfiles, or
fetch/push protocol semantics for its day-to-day operations.

Until this ADR, the path toward "git in the browser" assumed we would
keep growing `ZiggitRefStore` (the in-process Zig git plumbing) and
either:

1. Run `ZiggitRefStore` against a virtual filesystem inside WASM
   (`sideshowdb-an4` Option C — wasm32-wasi + browser FS shim), or
2. Fork ziggit's `Platform.fs` to a JS-backed shim
   (`sideshowdb-dgz` Option B).

Both approaches required us to also ship a **smart-HTTP-v2** transport
in Zig — pkt-line framing, capability negotiation, want/have, packfile
streaming — because ziggit has no transport at all today. That is
months of from-scratch protocol work that we would then maintain
bug-for-bug-compatible with GitHub forever, all to deliver a
`key -> blob` store.

The metrics-platform usage scenario we explored during brainstorming
(GitHub + JIRA + Jenkins, with web page, Chrome extension, native CLI,
and CI workflow consumers) made one thing obvious: **GitHub already
exposes the exact operations we need as a JSON REST API**, the **GitHub
Git Database API**.

| `RefStore` op | GitHub Git DB API |
|---|---|
| `put(key, value)` | `POST /git/blobs` -> `POST /git/trees` -> `POST /git/commits` -> `PATCH /git/refs/{ref}` (or `POST /git/refs` on first write) |
| `get(key)` | `GET /git/refs/{ref}` -> `GET /git/commits/{sha}` -> `GET /git/trees/{sha}?recursive=1` -> `GET /git/blobs/{sha}` |
| `list()` | tree-recursive read |
| `delete(key)` | tree-omit + commit |
| `history(key)` | `GET /repos/{o}/{r}/commits?path={key}&sha={ref}` |

All requests are plain HTTPS, all responses JSON, auth is Bearer-token
with PATs. CORS is enabled for browser callers. Native and WASM can
share the entire protocol layer because the only thing that differs is
the bottom-of-the-stack transport.

This dramatically reduces scope. We can deliver remote-backed reads and
writes from browser, Chrome extension, CLI, and CI in a fraction of the
effort that smart-HTTP-v2 inside ziggit would require, and we can do it
without dragging in libgit2, Emscripten, or a virtual filesystem.

## 2. Options considered

### 2.1 Continue with `ZiggitRefStore` + WASI virtual FS (`sideshowdb-an4`)

**Pros.** Zero changes to existing ziggit users; same code path on
native and WASM in principle.

**Cons.** Months of net-new protocol code (smart-HTTP-v2, pack streaming,
ref discovery), a maintained virtual filesystem with IDB persistence
backing it, and the freestanding/WASI build-target proliferation we just
added. Buys us nothing the metrics scenario actually needs.

### 2.2 Bring in libgit2 (native + Emscripten in browser)

**Pros.** Full git semantics, transport solved, credential callbacks fit
PATs, mature ecosystem references (e.g. `wasm-git`).

**Cons.** Emscripten enters the browser toolchain, a multi-megabyte
WASM bundle becomes part of the browser story, and we add a C
dependency to the native build that we currently avoid. Still overkill
for `key -> blob` over a single ref.

### 2.3 GitHub Git Database REST API (this ADR)

**Pros.**

- No git protocol implementation required.
- No extra toolchain (no Emscripten, no libgit2 link).
- Single artifact in browser: `sideshowdb.wasm` (`wasm32-freestanding`)
  stays small and unchanged.
- Pure-Zig HTTPS via `std.http.Client` covers native end-to-end with no
  external link dependencies.
- Same protocol logic on native and WASM; only the bottom transport
  differs.
- Auth maps cleanly to PAT / fine-grained PAT / GitHub App token via the
  standard `Authorization: Bearer` flow.

**Cons.**

- Provider-specific. GitLab, Bitbucket, Gitea need their own adapters
  (similar but distinct REST surfaces). Tracked as future tickets.
- Plain git remotes that publish no JSON API (self-hosted cgit, raw
  `git://`) cannot be reached at all; those use cases stay on
  `SubprocessGitRefStore` or wait for a future `Libgit2RefStore`.
- Per-blob HTTP requests cost more bandwidth than a single packfile
  fetch. Negligible for metric-sized payloads (KB to low-MB) and
  mitigated by SHA-keyed caches.
- Browser writes require online connectivity. CLI on developer machines
  can buffer offline writes via a local cache RefStore, then sync when
  online.

## 3. Decision

Adopt **2.3**. Ship `GitHubApiRefStore` as the primary remote-backed
`RefStore`, retire ziggit, and treat libgit2 as an optional native-only
backend that may land later if we encounter a non-API git host that
matters.

Concretely:

- **Public `RefStore` contract is unchanged.** `VersionId` remains a
  commit SHA, matching `SubprocessGitRefStore`.
- **`HttpTransport` indirection** is introduced so the same protocol
  code runs over `std.http.Client` on native and over a host-imported
  `host_http_request` extern in WASM. The host extern is reached via
  `hostCapabilities` (the option container introduced in
  `2026-04-29-host-capabilities-store-api.md`); the wired-through name
  is `hostCapabilities.transport.http`.
- **`CredentialProvider` indirection** abstracts the token source. Native
  defaults walk: explicit option > `GITHUB_TOKEN` env > `gh auth token`
  shell-out > keychain helper (behind `--credential-helper system`) > `git
  credential fill` (behind `--credential-helper git`). Browser defaults
  walk: explicit option > `hostCapabilities.credentials`.
- **First operation delivered is `put`** because it touches every auth
  failure mode early.
- **Subprocess backend is retained** behind `--refstore subprocess` per
  the existing escape-hatch decision.
- **Section namespacing** (multiple refs in one repo, scoped per logical
  store) is the recommended pattern for callers that need more than one
  store; we do not add a multi-ref `GitHubApiRefStore` instance.
- **Compaction strategy** is deliberately deferred; the ADR notes this
  as an explicit non-goal for v1.
- **Webhook-driven cache invalidation** is filed as a future
  enhancement, not in scope.

## 4. Consequences

- **`docs/development/specs/2026-04-29-github-api-refstore-ears.md`** is
  the normative requirement set; every EARS line maps to at least one
  unit test and at least one Cucumber acceptance scenario.
- **Site design hub** gains five sub-pages explaining the design,
  authentication, caching, configuration, and operations, linked from
  the existing design hub at `/docs/design/`.
- **Browser bundle** stays at the existing `sideshowdb.wasm` size; no
  emscripten artifact ships.
- **Native** binary picks up `std.http`-based HTTPS, with no new link
  dependency.
- **Acceptance suite** gains a small in-memory mock GitHub server so
  scenarios can run hermetically; opt-in live tests run against real
  GitHub gated by `GITHUB_TEST_TOKEN`.
- **Existing pending tickets** for ziggit-based options (`sideshowdb-an4`,
  `sideshowdb-dgz`) close under this ADR; tickets sensitive to the host
  store rename land aligned with `2026-04-29-host-capabilities-store-api.md`.
- **Future providers** reuse the same `HttpTransport` and credential
  provider — only the URL templates and JSON shapes change.
