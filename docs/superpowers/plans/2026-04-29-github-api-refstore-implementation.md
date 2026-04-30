# GitHub API RefStore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Project uses **beads (`bd`)** for issue tracking — never `TodoWrite`. Run `bd ready` to find claimable work and `bd update <id> --claim` before starting.

**Goal:** Land `GitHubApiRefStore` as the primary remote-backed `RefStore` for SideshowDB (browser, extension, native CLI, CI), implemented REST-first against the GitHub Git Database API. PUT ships first to flush authentication issues, then GET / LIST / DELETE / HISTORY. Ziggit (`src/core/storage/ziggit_pkg/`, `src/core/storage/ziggit_ref_store.zig`) is removed in parallel because the REST-first approach replaces every scenario it served.

**Architecture:** Pure-Zig protocol logic parameterized by an `HttpTransport` indirection. Native uses `std.http.Client` + `std.crypto.tls` (no link dependencies); WASM uses a `host_http_request` extern reached through `hostCapabilities.transport.http`. Credentials flow through a `CredentialProvider` indirection (auto / env / explicit / `gh auth token` / git helper / keychain / host capability). `PutResult.version` is the new commit SHA. Caching: ETag-validated ref tip cache plus SHA-keyed immutable caches for commits, trees, blobs.

**Tech Stack:** Zig 0.16 (`std.http`, `std.crypto.tls`, `std.json`), TypeScript bindings (`@sideshowdb/core`, `@sideshowdb/effect`), Cucumber acceptance suite (Bun + `@cucumber/cucumber`), beads (`bd`), Dolt-backed issue tracking.

**Spec & ADR references** — every task that mentions `GHAPI-NNN` traces back to the EARS spec; review the relevant entries in:

- EARS: [`docs/development/specs/2026-04-29-github-api-refstore-ears.md`](../../development/specs/2026-04-29-github-api-refstore-ears.md)
- Primary ADR: [`docs/design/adrs/2026-04-29-github-api-refstore.md`](../../design/adrs/2026-04-29-github-api-refstore.md)
- Deprecation ADR: [`docs/design/adrs/2026-04-29-deprecate-ziggit.md`](../../design/adrs/2026-04-29-deprecate-ziggit.md)
- On-site narrative: `site/src/routes/docs/design/{github-api-refstore,auth-model,caching,configuration,operations}/+page.md`

---

## File structure

**New files (Zig core):**

- `src/core/storage/http_transport.zig` — `HttpTransport` interface, `Method`, `Header`, `Response` types.
- `src/core/storage/std_http_transport.zig` — native `StdHttpTransport` over `std.http.Client`.
- `src/core/storage/host_http_transport.zig` — WASM `HostHttpTransport` over `host_http_request` extern.
- `src/core/storage/credential_provider.zig` — `CredentialProvider`, `Credential`, `CredentialSpec` union.
- `src/core/storage/credential_sources/explicit.zig`
- `src/core/storage/credential_sources/env.zig`
- `src/core/storage/credential_sources/gh_helper.zig`
- `src/core/storage/credential_sources/git_helper.zig`
- `src/core/storage/credential_sources/host_capability.zig` (WASM target)
- `src/core/storage/credential_sources/auto.zig` — priority walker.
- `src/core/storage/github_api_ref_store.zig` — main store.
- `src/core/storage/github_api/json.zig` — request/response JSON shapes.
- `src/core/storage/github_api/cache.zig` — ETag ref-tip cache + SHA-keyed object caches.
- `src/core/storage/github_api/pagination.zig` — `Link` header parsing.

**New files (tests):**

- `tests/http_transport_test.zig` — fake transport + native loopback.
- `tests/credential_provider_test.zig` — every variant.
- `tests/github_api_refstore_test.zig` — exhaustive unit tests with fake transport.
- `tests/github_api_cache_test.zig`
- `tests/github_live_test.zig` — opt-in, gated by `GITHUB_TEST_TOKEN`.

**New files (TS bindings):**

- `bindings/typescript/sideshowdb-core/src/refstore/github.ts` — public `RefStoreSpec` shape and helpers.
- `bindings/typescript/sideshowdb-core/src/transport/http.ts` — `createBrowserHttpTransport` (default `fetch`-based).
- `bindings/typescript/sideshowdb-core/src/credentials/host-capability.ts` — `createBrowserCredentialsResolver`.
- `bindings/typescript/sideshowdb-core/src/refstore/github.test.ts`
- `bindings/typescript/sideshowdb-core/src/transport/http.test.ts`

**New files (acceptance):**

- `acceptance/typescript/features/github-api-refstore.feature`
- `acceptance/typescript/features/github-api-auth.feature`
- `acceptance/typescript/src/steps/github-api.steps.ts`
- `acceptance/typescript/src/support/github-mock.ts`

**Modified files:**

- `src/core/storage.zig` — register `GitHubApiRefStore`; remove `ZiggitRefStore` declarations.
- `src/cli/app.zig` — add `--refstore github`, `--github-owner`, `--github-repo`, `--github-ref`, `--api-base`, `--credential-helper`.
- `bindings/typescript/sideshowdb-core/src/types.ts` — `RefStoreSpec`, `GitHubRefStoreSpec`, `HostHttpTransport`, `HostCredentialsResolver`.
- `bindings/typescript/sideshowdb-core/src/client.ts` — wire `refstore.kind === 'github'`.
- `bindings/typescript/sideshowdb-effect/src/index.ts` — Effect wrapper for the github refstore option.
- `build.zig` — register new test modules; remove `ziggit_ref_test_mod`.
- `tests/wasm_exports_test.zig` — add `host_http_request` import to test imports list.
- `acceptance/typescript/src/support/world.ts` — `githubMock` field on shared world.
- `docs/design/README.md` — index updates as ADRs are referenced.

**Deletions (ziggit removal):**

- `src/core/storage/ziggit_pkg/` (entire directory)
- `src/core/storage/ziggit_ref_store.zig`
- `tests/ziggit_ref_store_test.zig`

---

## Phase 0: Beads issue setup

### Task 0.1: File parent epic + sub-issues for this plan

**Files:** none (operates on `bd`).

- [x] Run `bd create --title="Epic: GitHubApiRefStore (REST-first remote RefStore)" --type=epic --priority=1 --description="Land GitHubApiRefStore per docs/superpowers/plans/2026-04-29-github-api-refstore-implementation.md and the EARS spec at docs/development/specs/2026-04-29-github-api-refstore-ears.md. Tracks all sub-deliverables." --acceptance="All EARS GHAPI-001..082 satisfied; acceptance suite green; ziggit removal landed; design site sub-pages live."` and capture the issue ID as `<EPIC>`.
- [x] Use `bd create` (in parallel batches of ≤4 to keep latency reasonable) to file each sub-issue listed below. Use `--type=feature` for code-shipping work and `--type=task` for housekeeping. Set priority `P1` for everything in Phase 1–6, `P2` for caching/rate-limit, `P3` for keychain helper, `P3` for IDB-backed caching, `P3` for live integration tests.
  - `feature: HttpTransport interface + StdHttpTransport (native) + HostHttpTransport (WASM)` (P1)
  - `feature: CredentialProvider + explicit/env/gh_helper/git_helper/host_capability sources + auto walker` (P1)
  - `feature: GitHubApiRefStore.put end-to-end (auth-flush)` (P1)
  - `feature: GitHubApiRefStore.get + version-pinned get` (P1)
  - `feature: GitHubApiRefStore.list` (P1)
  - `feature: GitHubApiRefStore.delete` (P1)
  - `feature: GitHubApiRefStore.history with Link pagination` (P2)
  - `feature: ETag ref tip cache + rate-limit header surface` (P2)
  - `feature: SHA-keyed in-memory caches for commit/tree/blob` (P2)
  - `task: Wire GitHubApiRefStore into native CLI (--refstore github + flags)` (P1)
  - `feature: TS bindings for refstore.kind=github + hostCapabilities.transport.http + hostCapabilities.credentials` (P1)
  - `feature: Cucumber mock GitHub server + github-api-refstore.feature + github-api-auth.feature` (P1)
  - `task: Opt-in live tests gated by GITHUB_TEST_TOKEN (zig build test:github-live)` (P3)
  - `task: Remove ziggit (src/core/storage/ziggit_pkg, ziggit_ref_store, tests, build wiring, --refstore ziggit flag)` (P1)
  - `feature: IDB-backed cache reuse via existing host store infrastructure (sideshowdb-auk)` (P3)
  - `task: Native keychain credential source (macOS/Linux/Windows)` (P3)
  - `feature: RateLimitPolicy.wait_until_reset` (P3)
  - `feature: Webhook-driven cache invalidation (future)` (P4)
  - `task: Wire wasmtime-driven Zig tests on wasm32-wasi target` (P3)
  - `feature: Libgit2RefStore (native-only fallback for non-API git remotes)` (P3)
  - `feature: GitLabApiRefStore (REST adapter)` (P3)
  - `feature: BitbucketApiRefStore (REST adapter)` (P3)
  - `feature: Smart-HTTP-v2 client in Zig` (P4)
- [x] For each sub-issue created above, add a dependency on `<EPIC>` via `bd dep add <EPIC> <SUB>` so the epic blocks until everything closes.
- [x] Add the in-plan dependency edges: every operation issue (`put`, `get`, `list`, `delete`, `history`, ETag cache, SHA cache, CLI wiring, TS bindings, acceptance) `bd dep add <op-issue> <transport-issue>` and `bd dep add <op-issue> <credential-issue>`. The acceptance issue depends on `put` and `get` minimum.
- [x] Commit and push the resulting `bd dolt push`. Capture all assigned issue IDs in a local note for the rest of the plan to reference.

### Task 0.2: Update notes on existing pending tickets

**Files:** none (operates on `bd`).

- [x] `bd update sideshowdb-auk --notes "REST pivot: see ADR docs/design/adrs/2026-04-29-github-api-refstore.md. IndexedDB host store remains the canonical browser-local persistence; cache reuse is filed as a follow-up under the new epic."`
- [x] `bd update sideshowdb-kcv --notes "REST pivot: GitHubApiRefStore is now the primary remote-backed RefStore. Reposition this RocksDB backend as a native high-throughput materialization store, not primary remote storage."`
- [x] `bd update sideshowdb-d10 --notes "Playground tour can demo GitHubApiRefStore with a public repo + read-only PAT once the GET path lands. Replace the MemoryRefStore-only walkthrough."`

### Task 0.3: Close ziggit-driven issues under the deprecation ADR

> **Order:** Run this only after Phase 14 (ziggit removal) lands so the close reasons are accurate.

**Files:** none.

- [ ] `bd close sideshowdb-an4 --reason "Closed under docs/design/adrs/2026-04-29-deprecate-ziggit.md. wasm32-wasi target retained as internal CI test artifact only; browser path delivered via GitHubApiRefStore (REST)."`
- [ ] `bd close sideshowdb-dgz --reason "Closed under docs/design/adrs/2026-04-29-deprecate-ziggit.md. Browser persistence delivered via REST-first GitHubApiRefStore + IndexedDB host store cache, not via ziggit-on-virtual-FS."`

---

## Phase 1: HttpTransport indirection

### Task 1.1: Define `HttpTransport` interface

**Files:**
- Create: `src/core/storage/http_transport.zig`
- Create: `tests/http_transport_test.zig`

- [x] Write `tests/http_transport_test.zig` first. Define `RecordingTransport` — a fake that captures the last `Request` it saw and returns a canned `Response`. Add a failing test `recording_transport_round_trip` that constructs a `RecordingTransport`, wraps it in `HttpTransport`, calls `transport.request(.GET, "https://example/x", &.{}, null, gpa)`, and asserts the captured method/url match and the response body equals the canned bytes.
- [x] Run `zig build test` and confirm the test fails with `error.AnalysisFail` or "import not found" on `http_transport.zig` — i.e. the module doesn't exist yet.
- [x] Create `src/core/storage/http_transport.zig` exporting:
  - `pub const Method = enum { GET, POST, PATCH, PUT, DELETE };`
  - `pub const Header = struct { name: []const u8, value: []const u8 };`
  - `pub const Response = struct { status: u16, headers: []Header, body: []u8, etag: ?[]const u8, rate_limit: RateLimitInfo };`
  - `pub const RateLimitInfo = struct { remaining: ?u32 = null, reset_unix: ?i64 = null };`
  - `pub const HttpTransport = struct { ctx: *anyopaque, request: *const fn (ctx: *anyopaque, method: Method, url: []const u8, headers: []const Header, body: ?[]const u8, gpa: std.mem.Allocator) anyerror!Response };`
- [x] Implement `RecordingTransport.init` and a `transport()` method returning `HttpTransport{ .ctx = self, .request = recordingRequest }`.
- [x] Re-run `zig build test`; expect it to pass.
- [x] `git add` the two new files; commit `feat(refstore): introduce HttpTransport interface`.

### Task 1.2: Implement `StdHttpTransport` (native)

**Files:**
- Create: `src/core/storage/std_http_transport.zig`
- Modify: `tests/http_transport_test.zig`

- [x] In the test file, add `std_http_transport_get_loopback`: spin up a `std.http.Server` on `127.0.0.1:0`, register a single handler that returns 200 with body `"ok"` and an `ETag: "\"abc\""` header, then call `StdHttpTransport.transport().request(.GET, …)` against that URL. Assert status 200, body `"ok"`, `response.etag == "\"abc\""`.
- [x] Add a second test `std_http_transport_post_with_body`: server echoes back the request body in the response; assert the echoed bytes round-trip.
- [x] Add a third test `std_http_transport_records_rate_limit_headers`: server returns a successful response with `X-RateLimit-Remaining: 4999` and `X-RateLimit-Reset: 1700000000`; assert `response.rate_limit.remaining == 4999` and `response.rate_limit.reset_unix == 1_700_000_000`.
- [x] Run `zig build test`; expect compile failure on missing module.
- [x] Implement `src/core/storage/std_http_transport.zig`:
  - Wraps `std.http.Client` with TLS via `std.crypto.tls`.
  - Builds the request from `HttpTransport.Method` + headers + body.
  - Reads the full response body into an allocator-owned slice.
  - Pulls `ETag`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` into the typed fields and leaves the rest in `headers`.
  - Returns errors as `error.TransportFailure`, `error.TlsFailure`, `error.InvalidResponse` etc. — typed for consumers to map.
- [x] Re-run `zig build test`; expect green.
- [x] Commit `feat(refstore): native StdHttpTransport over std.http.Client`.

### Task 1.3: Stub `HostHttpTransport` (WASM)

**Files:**
- Create: `src/core/storage/host_http_transport.zig`
- Modify: `src/wasm/root.zig`
- Modify: `tests/wasm_exports_test.zig`

- [x] Add a failing test `host_http_transport_calls_host_extern` to `tests/wasm_exports_test.zig`: instantiate the wasm module with a fake `host_http_request` import that records the arguments and returns a canned response, drive a no-op operation that goes through `HostHttpTransport`, and assert the import was called once with the right URL.
- [x] Run `zig build wasm test` and confirm the test fails because `host_http_request` is not yet declared.
- [x] In `src/wasm/root.zig`, declare the extern:
  - `extern "host" fn host_http_request(method: u32, url_ptr: [*]const u8, url_len: usize, headers_ptr: [*]const u8, headers_len: usize, body_ptr: [*]const u8, body_len: usize, response_buf_ptr: [*]u8, response_buf_capacity: usize, response_actual_len_out: *u32) i32;`
  - The host JS side will copy bytes into `response_buf` up to capacity and write the actual length to `response_actual_len_out`. Negative return = host-side error.
- [x] In `src/core/storage/host_http_transport.zig`, implement `HostHttpTransport` that:
  - Encodes method as `u32`, serializes headers as a length-prefixed packed buffer, body as raw bytes.
  - Allocates a 64 KiB response buffer (configurable later via the cache config) and grows on `error.ResponseTooLarge`.
  - Parses the returned bytes back into a `Response` matching the same shape `StdHttpTransport` returns (status, headers, body, ETag, RateLimitInfo).
- [x] Update `tests/wasm_exports_test.zig` so the new import is provided alongside the existing host store import; ensure the existing wasm tests still pass.
- [x] Run `zig build wasm test`; expect green.
- [x] Commit `feat(refstore): WASM HostHttpTransport via host_http_request extern`.

---

## Phase 2: CredentialProvider

### Task 2.1: `CredentialProvider` types + explicit source

**Files:**
- Create: `src/core/storage/credential_provider.zig`
- Create: `src/core/storage/credential_sources/explicit.zig`
- Create: `tests/credential_provider_test.zig`

- [x] In `tests/credential_provider_test.zig`, add `explicit_source_returns_token`: construct an `ExplicitSource{ .token = "tok-123" }`, call `provider.get(testing.allocator)`, assert the returned `Credential.bearer == "tok-123"`. Add `explicit_source_empty_token_is_invalid_config` that constructs with empty `""` and expects `error.InvalidConfig`.
- [x] Run `zig build test`; expect failure on missing module.
- [x] Implement `credential_provider.zig`:
  - `pub const Credential = union(enum) { bearer: []const u8, basic: BasicCreds, none: void };`
  - `pub const BasicCreds = struct { user: []const u8, password: []const u8 };`
  - `pub const CredentialProvider = struct { ctx: *anyopaque, get: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!Credential };`
  - `pub const CredentialSpec = union(enum) { auto: void, env: []const u8, explicit: []const u8, gh_helper: void, git_helper: void, keychain: KeychainConfig, host_capability: void };`
  - `pub fn fromSpec(spec: CredentialSpec, opts: SpecOptions) !CredentialProvider` — dispatches to the matching source module.
- [x] Implement `credential_sources/explicit.zig` returning `Credential{ .bearer = self.token }`.
- [x] Re-run `zig build test`; expect green.
- [x] Commit `feat(refstore): CredentialProvider + explicit source`.

### Task 2.2: Env source

**Files:**
- Create: `src/core/storage/credential_sources/env.zig`
- Modify: `tests/credential_provider_test.zig`

- [x] Add `env_source_reads_named_var`: set `setenv("SHEDB_TEST_TOKEN", "from-env")` for the test, construct `EnvSource{ .var_name = "SHEDB_TEST_TOKEN" }`, assert `Credential.bearer == "from-env"`. Add `env_source_missing_returns_helper_unavailable` for the unset case.
- [x] Implement `env.zig` using `std.process.getEnvVarOwned`. On `error.EnvironmentVariableNotFound`, return a typed `error.HelperUnavailable` so the auto walker can fall through.
- [x] Re-run `zig build test`; expect green.
- [x] Commit `feat(refstore): env credential source`.

### Task 2.3: `gh auth token` shell-out source

**Files:**
- Create: `src/core/storage/credential_sources/gh_helper.zig`
- Modify: `tests/credential_provider_test.zig`

- [x] Add `gh_helper_returns_token_when_gh_present` (skipped if `gh` is not on `PATH`): spawn `gh --version` to detect, run the source, assert a non-empty bearer is returned.
- [x] Add `gh_helper_unavailable_when_path_missing`: temporarily clear `PATH` for the test process; assert `error.HelperUnavailable`.
- [x] Add `gh_helper_returns_auth_invalid_when_logged_out`: stub `gh` resolution by passing `executable_name = "gh-test-stub"` referring to a script the test writes that exits non-zero; assert `error.AuthInvalid`.
- [x] Implement `gh_helper.zig` running `gh auth token` via `std.process.run` with a 5-second timeout. Trim trailing newline. Emit `error.HelperUnavailable` (not found, hostfs error) vs `error.AuthInvalid` (exit code non-zero) vs `error.TransportError` (timeout).
- [x] Run `zig build test`; expect green or skip when gh is absent.
- [x] Commit `feat(refstore): gh auth token credential source`.

### Task 2.4: `git credential fill` source

**Files:**
- Create: `src/core/storage/credential_sources/git_helper.zig`
- Modify: `tests/credential_provider_test.zig`

- [x] Add `git_helper_protocol_round_trip`: provide a stub `git` binary on the test PATH that responds to `git credential fill` per the documented protocol (`username=...` / `password=...` lines on stdout). Drive the source against it, assert the produced `Credential.basic` carries the expected values.
- [x] Implement `git_helper.zig`. Send `protocol=https\nhost=github.com\n\n` on stdin to `git credential fill`, parse `username=` / `password=` from stdout. Map exit code `0` with empty username to `error.HelperUnavailable`. Other failures map per Task 2.3.
- [x] Run `zig build test`; expect green.
- [x] Commit `feat(refstore): git credential helper source`.

### Task 2.5: `host_capability` source (WASM)

**Files:**
- Create: `src/core/storage/credential_sources/host_capability.zig`
- Modify: `src/wasm/root.zig`
- Modify: `tests/wasm_exports_test.zig`

- [x] Add a failing wasm test that imports `host_get_credential` returning `"from-host"` and asserts the source observes a matching bearer.
- [x] Declare extern in `src/wasm/root.zig`:
  - `extern "host" fn host_get_credential(provider_ptr: [*]const u8, provider_len: usize, scope_ptr: [*]const u8, scope_len: usize, out_buf_ptr: [*]u8, out_capacity: usize, out_actual_len: *u32) i32;`
- [x] Implement `host_capability.zig` calling the extern with `"github"` as provider, allocating the buffer, parsing the result.
- [x] Run `zig build wasm test`; expect green.
- [x] Commit `feat(refstore): WASM host_capability credential source`.

### Task 2.6: Auto walker

**Files:**
- Create: `src/core/storage/credential_sources/auto.zig`
- Modify: `tests/credential_provider_test.zig`

- [x] Add `auto_walker_picks_first_available`: stack mocks so explicit returns `HelperUnavailable`, env returns `HelperUnavailable`, gh returns success; assert auto picks gh's value.
- [x] Add `auto_walker_returns_auth_missing_when_all_sources_unavailable`: stack mocks where every source returns `HelperUnavailable`; assert `error.AuthMissing`.
- [x] Add `auto_walker_short_circuits_on_auth_invalid`: env returns invalid; assert auto returns `error.AuthInvalid` and does NOT fall through (do not silently swap a misconfigured token for a fallback).
- [x] Implement `auto.zig` walking the per-platform list described in `docs/design/adrs/2026-04-29-github-api-refstore.md` § 3 (native: explicit > env > gh > keychain > git; WASM: explicit > host_capability). On `HelperUnavailable` continue; on any other error, return immediately.
- [x] Run `zig build test`; expect green.
- [x] Commit `feat(refstore): auto credential source walker`.

---

## Phase 3: GitHubApiRefStore — PUT (auth-flushing first)

> Implementing PUT first surfaces every authentication failure mode immediately. Subsequent operations reuse the same plumbing.

### Task 3.1: Init + config validation

**Files:**
- Create: `src/core/storage/github_api_ref_store.zig`
- Create: `src/core/storage/github_api/json.zig`
- Create: `tests/github_api_refstore_test.zig`

- [x] Add `init_rejects_empty_owner` and `init_rejects_empty_repo`: assert `error.InvalidConfig` (covers GHAPI-002).
- [x] Add `init_default_ref_name`: assert `store.ref_name == "refs/sideshowdb/documents"` when omitted (GHAPI-003).
- [x] Add `init_records_owner_repo_ref`: assert that `store.owner == "sideshowdb"`, `store.repo == "metrics-store"`, `store.ref_name == "refs/sideshowdb/documents"` after explicit config.
- [x] Implement `GitHubApiRefStore.Options` mirroring the `GitHubConfig` block in `site/src/routes/docs/design/configuration/+page.md`. `init` validates and stashes inputs; no HTTP yet.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore init + config validation (GHAPI-001/002/003)`.

### Task 3.2: PUT — fail-fast `AuthMissing`

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `put_returns_auth_missing_when_provider_yields_none`: drive a store wired to a credential provider that returns `Credential.none`. Call `put("k", "v")`. Assert `error.AuthMissing`. Confirm the recording transport was NOT called (zero requests). Covers GHAPI-010.
- [x] Implement `put` as a stub that resolves credentials first; on `none` or `error.AuthMissing` from the provider, return immediately without touching the transport.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore.put short-circuits on missing creds (GHAPI-010)`.

### Task 3.3: PUT — happy path on existing ref

**Files:** Modify `github_api_ref_store.zig`, `github_api/json.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `put_happy_path_existing_ref`: queue four canned responses on the recording transport — get-ref → 200 with commit SHA `aaa…`, get-commit → 200 with tree SHA `bbb…`, post-blob → 201 with new blob SHA `ccc…`, post-tree → 201 with new tree SHA `ddd…`, post-commit → 201 with new commit SHA `eee…`, patch-ref → 200. Call `put("doc-1", "value-1")`. Assert returned `PutResult.version == "eee…"`. Assert exact request sequence via the recorder, including:
  - `GET https://api.github.com/repos/sideshowdb/metrics-store/git/ref/refs/sideshowdb/documents`
  - `GET …/git/commits/aaa…`
  - `POST …/git/blobs` body `{"content":"<base64 of value-1>","encoding":"base64"}`
  - `POST …/git/trees` body `{"base_tree":"bbb…","tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"ccc…"}]}`
  - `POST …/git/commits` body containing `parents:["aaa…"]`, `tree:"ddd…"`, message starting with `put doc-1`.
  - `PATCH …/git/refs/refs/sideshowdb/documents` body `{"sha":"eee…","force":false}`.
- [x] Implement the JSON shapes in `github_api/json.zig`: `GetRefResponse`, `GetCommitResponse`, `CreateBlobRequest`, `CreateBlobResponse`, `CreateTreeRequest`, `CreateTreeResponse`, `CreateCommitRequest`, `CreateCommitResponse`, `UpdateRefRequest`. Use `std.json` with strict types so test assertions can serialize/deserialize predictably.
- [x] Implement the put-existing-ref path in `github_api_ref_store.zig` performing exactly the six requests above. Always send `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `Authorization: Bearer <token>`, `User-Agent: <configured>`.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore.put happy path (GHAPI-020/024)`.

### Task 3.4: PUT — first-write path (`POST /git/refs`)

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `put_first_write_creates_ref`: queue get-ref → 404, post-blob → 201, post-tree → 201 with `tree[0]` only (no `base_tree`), post-commit → 201 with `parents: []`, post-ref → 201 (note: `POST /git/refs`, body `{"ref":"refs/sideshowdb/documents","sha":"…"}`). Assert returned `PutResult.version` equals the new commit SHA.
- [x] Implement the branching: when `GET /git/ref/{ref}` returns 404, skip the get-commit step, omit `base_tree`, send empty `parents`, `POST /git/refs` instead of `PATCH`.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore.put first-write path (GHAPI-021)`.

### Task 3.5: PUT — error mapping + bounded retry

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add a test per error class. Each test drives the recording transport to return the listed status, asserts the mapped error and (where applicable) the absence of follow-up requests. Use real GitHub error response bodies:
  - `put_401_returns_auth_invalid` (GHAPI-011).
  - `put_403_insufficient_scope` — body `{"message":"Resource not accessible by personal access token"}` (GHAPI-012).
  - `put_403_rate_limited` — `X-RateLimit-Remaining: 0`, `X-RateLimit-Reset: 1700000000` (GHAPI-070).
  - `put_5xx_returns_upstream_unavailable` — first 503, second attempt also 503; assert exactly two attempts (one bounded retry per GHAPI-080).
  - `put_value_too_large_pre_check` — value > 100 MB; assert `error.ValueTooLarge` and zero requests (GHAPI-023).
  - `put_concurrent_update_retries_then_succeeds`: get-ref → 200 (parent X), …, patch-ref → 422 "not a fast-forward", get-ref → 200 (parent Y), …, patch-ref → 200. Assert success (GHAPI-022).
  - `put_concurrent_update_exhausts_retries`: 422 four times in a row (default retry budget = 3 + initial = 4 attempts). Assert `error.ConcurrentUpdate` carrying the last observed parent SHA (GHAPI-022 boundary).
  - `put_transport_error_returns_transport_error` — fake transport throws `error.TransportFailure` (GHAPI-081).
  - `put_4xx_other_returns_invalid_request` — 422 with body that is not "not a fast-forward" returns `error.InvalidRequest` carrying the body for diagnostics.
- [x] Implement the dispatch in a `mapGitHubError` helper inside `github_api_ref_store.zig`.
- [x] Implement `retry_concurrent_writes` budget logic with exponential backoff capped at 1 second.
- [x] Surface `RateLimitInfo` from every successful response on `RefStore.PutResult` (GHAPI-071) and make `put` return that result directly.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore.put error mapping + retry (GHAPI-011/012/022/023/070/080/081)`.

### Task 3.6: Wire PUT into `RefStore` vtable + `storage.zig` registry

**Files:**
- Modify: `src/core/storage.zig`
- Modify: `src/core/storage/github_api_ref_store.zig`

- [x] Add `pub fn refStore(self: *GitHubApiRefStore) RefStore` returning the vtable. Initially only `put` is wired; other methods return `error.NotImplemented`.
- [x] In `src/core/storage.zig`, export `pub const GitHubApiRefStore = @import("storage/github_api_ref_store.zig").GitHubApiRefStore;`.
- [x] Add a top-level test inside the storage `test {}` block to import the new module so it compiles on every test run.
- [x] Run `zig build test`; expect green.
- [x] Commit `feat(refstore): expose GitHubApiRefStore from src/core/storage`.

---

## Phase 4: GitHubApiRefStore — GET

### Task 4.1: GET (latest tip)

**Files:** Modify `github_api_ref_store.zig`, `github_api/json.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `get_returns_blob_bytes_for_known_key`: queue get-ref → 200 commit `aaa`, get-commit → 200 tree `bbb`, get-tree-recursive → 200 with entry `{path:"doc-1",sha:"ccc",type:"blob",mode:"100644"}`, get-blob → 200 `{content: base64("hello"), encoding: "base64"}`. Assert returned bytes == `"hello"` (GHAPI-030).
- [x] Implement the four-call walk + base64 decode.
- [x] Add `get_returns_null_when_key_absent` covering GHAPI-031.
- [x] Add `get_returns_null_when_ref_missing` (treated like empty store for `get`; not `RefNotFound`).
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.get (GHAPI-030/031)`.

### Task 4.2: GET with `version`

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `get_with_known_version_returns_historical_blob`: skip get-ref, jump straight to `GET /git/commits/{version}` → tree → blob. Assert bytes match (GHAPI-032).
- [x] Add `get_with_unknown_version_returns_null`: get-commit → 404; assert `null` (GHAPI-033).
- [x] Implement the version-pinned branch.
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.get version-pinned (GHAPI-032/033)`.

---

## Phase 5: GitHubApiRefStore — LIST

### Task 5.1: LIST against existing ref

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `list_returns_all_blob_entries_in_path_order`: queue ref → commit → tree-recursive returning three blob entries in arbitrary order; assert `list()` returns them sorted by path (GHAPI-040).
- [x] Implement `list` reusing the get-tree-recursive call. Filter out non-blob entries (subtrees with `type: "tree"` are not user keys).
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.list (GHAPI-040)`.

### Task 5.2: LIST when ref is missing

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `list_returns_empty_when_ref_missing`: get-ref → 404; assert `result.entries.len == 0` and **not** `error.RefNotFound` (GHAPI-041).
- [x] Adjust `list` to treat 404 on the ref read as the empty-store signal.
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.list empty for missing ref (GHAPI-041)`.

---

## Phase 6: GitHubApiRefStore — DELETE

### Task 6.1: DELETE present key

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `delete_known_key_advances_ref`: queue ref/commit/tree-recursive showing `doc-1` and `doc-2`. Then post-tree (with `doc-1` omitted), post-commit, patch-ref. Call `delete("doc-1")`. Assert returned delete result version equals the new commit SHA. Assert the `POST /git/trees` body sends `tree: [{path:"doc-2",…}]` and **does not** mention `doc-1` (GHAPI-050).
- [x] Implement the tree-omit + commit + ref update path. Reuse the existing `commitAndUpdateRef` helper introduced in Phase 3.
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.delete present key (GHAPI-050)`.

### Task 6.2: DELETE absent key

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `delete_absent_key_returns_null_no_commit`: tree contains only `doc-2`; assert `delete("doc-1")` returns null and the recorder shows zero subsequent requests beyond the read path (GHAPI-051).
- [x] Implement the early-return when the key is absent from the resolved tree.
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.delete absent key returns null (GHAPI-051)`.

---

## Phase 7: GitHubApiRefStore — HISTORY

### Task 7.1: HISTORY single page

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `history_returns_commits_touching_key`: queue `GET /repos/{o}/{r}/commits?path=doc-1&sha=refs/sideshowdb/documents` → 200 with three commit objects; for each commit fetch tree to recover the blob SHA. Assert the returned versions are in chronological put order, each carrying `(VersionId, blob_sha)` (GHAPI-060).
- [x] Implement the per-commit tree resolution (small reuse from Phase 4) to recover the blob SHA at that commit.
- [x] Run tests; expect green.
- [ ] Commit `feat(refstore): GitHubApiRefStore.history single page (GHAPI-060)`.

### Task 7.2: HISTORY paginated

**Files:** Create `src/core/storage/github_api/pagination.zig`. Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `history_follows_link_rel_next`: response includes header `Link: <https://api.github.com/repos/o/r/commits?page=2>; rel="next"`. Drive a two-page response set; assert the second `GET` was issued and merged.
- [x] Add `history_respects_history_limit`: `history_limit = 2`, three commits returned in the first page; assert exactly two are returned and the second `GET` is NOT issued.
- [x] Implement `pagination.zig` with `parseLinkHeader(header: []const u8) ?LinkRels` returning `.next`, `.prev`, etc.
- [x] Implement the loop in `history` honoring `history_limit` (GHAPI-061).
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): GitHubApiRefStore.history pagination (GHAPI-061)` (landed with read-path work).

---

## Phase 8: ETag ref tip cache + rate-limit surface

### Task 8.1: ETag-validated ref tip cache

**Files:** Create `src/core/storage/github_api/cache.zig`. Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`. Create `tests/github_api_cache_test.zig`.

- [x] Add `cache_test_etag_round_trip` in `github_api_cache_test.zig`: insert a ref tip with ETag, lookup returns same; lookup with `If-None-Match` header passes through; on 304, cache returns the cached commit SHA.
- [x] Add an integration test in `github_api_refstore_test.zig` named `get_warm_cache_serves_304`: first `get` returns ETag; second `get` queues a 304 from the upstream; assert the second call issues exactly one HTTP request (the conditional ref read) and reuses cached commit/tree/blob SHAs from local memory.
- [x] Implement `RefTipCache` keyed by `(owner, repo, ref_name)` storing `{commit_sha, etag}`. Expose `lookup(...) ?Entry`, `record(...)`, `invalidate(...)`.
- [x] Wire `If-None-Match` into the get-ref request when an entry exists; on 304, reuse the cached commit SHA. On 200, update.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): ETag-validated ref tip cache (GHAPI-034)` (landed in `56fec88`).

### Task 8.2: Rate-limit headers on every result

**Files:** Modify `github_api_ref_store.zig`, `RefStore` result types in `src/core/storage/ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Add `put_carries_rate_limit_headers`: queue a successful put sequence with `X-RateLimit-Remaining: 4500` and `X-RateLimit-Reset: 1700000000`. Assert `PutResult.rate_limit` carries the values (GHAPI-071).
- [x] Extend `RefStore.ReadResult` with optional `rate_limit` (GitHub `get` merges the last successful GitHub response). `MemoryRefStore` / `SubprocessGitRefStore` leave it unset (`null`). List/delete/history still use the existing `RefStore` vtable shapes; follow-up can widen those when needed.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): expose rate-limit info on remote results (GHAPI-071)` (landed in `56fec88`).

---

## Phase 9: SHA-keyed in-memory caches

### Task 9.1: LRU bounded cache for commits, trees, blobs

**Files:** Modify `src/core/storage/github_api/cache.zig`, `tests/github_api_cache_test.zig`.

- [x] Add `cache_test_blob_lru_eviction` (in `cache.zig`): insert N+1 entries with a max-N-byte budget, assert oldest evicted.
- [x] Integration: `get_reuses_cached_tree_and_blob_after_tip_commit_changes` in `github_api_refstore_test.zig` — second `get` after tip change reuses cached tree/blob when SHAs unchanged.
- [x] Implement SHA-keyed JSON body caches for commits/trees/blobs (`ShaBodyLruCache` + `ObjectBodyCache` in `cache.zig`), bounded by bytes per kind.
- [x] Run tests; expect green.
- [x] Extra coverage: `history_with_read_caching_matches_uncached_results`, `delete_known_key_with_read_caching_same_request_count` (see test comment: `delete` uses `smp_allocator`, so `deinitCaches` must match), `cache_test_put_replace_updates_body`, `cache_test_oversized_entry_stored_alone`.

### Task 9.2: Wire caches into get/list/history

**Files:** Modify `github_api_ref_store.zig`, `tests/github_api_refstore_test.zig`.

- [x] Wire object caches into `get`, `list`, `history`, and read-side `delete` behind `Options.enable_read_caching` (default `false` in tests to avoid leaks; opt-in tests pass `true` and call `deinitCaches`). `Options.object_cache_max_bytes_per_kind` bounds each LRU.
- [x] Run tests; expect green.
- [x] Commit `feat(refstore): Phase 9 SHA-keyed LRU object caches and read-path wiring`.

---

## Phase 10: Native CLI wiring

### Task 10.1: `--refstore github` flag + GitHub-specific flags

**Files:**
- Modify: `src/cli/app.zig`
- Modify: `tests/cli_test.zig`

- [ ] Add CLI tests: `cli_refstore_github_requires_owner_repo` (asserts a clear error when one is omitted), `cli_refstore_github_uses_default_ref`, `cli_refstore_github_accepts_custom_api_base`.
- [ ] Add `--refstore github`, `--github-owner`, `--github-repo`, `--github-ref`, `--api-base` flags; reject any token-on-CLI value (per security guidance in `site/src/routes/docs/design/configuration/+page.md`).
- [ ] Run tests; expect green.
- [ ] Commit `feat(cli): --refstore github + flags`.

### Task 10.2: `--credential-helper` flag

**Files:**
- Modify: `src/cli/app.zig`
- Modify: `tests/cli_test.zig`

- [ ] Add `cli_credential_helper_default_walks_auto_list`, `cli_credential_helper_env_only`, `cli_credential_helper_gh_when_present` (skip if gh missing), `cli_credential_helper_system_invokes_keychain` (skipped until keychain ticket lands).
- [ ] Implement the flag with values `auto|env|explicit|gh|system|git`. Keychain (`system`) currently delegates to a stub that returns `error.HelperUnavailable` until the keychain ticket lands; document this.
- [ ] Run tests; expect green.
- [ ] Commit `feat(cli): --credential-helper selector`.

### Task 10.3: End-to-end CLI happy path against mock server

**Files:**
- Modify: `tests/cli_test.zig`

- [ ] Add `cli_doc_put_then_list_against_mock_github`: spin up an in-process Zig mock GitHub server (a small `std.http.Server` + a state map) and run `sideshowdb doc put / list / get / delete / history` end-to-end against it, asserting outputs and exit codes per the existing CLI conventions (already covered in `tests/cli_test.zig`).
- [ ] Run tests; expect green.
- [ ] Commit `test(cli): GitHub mock end-to-end happy path`.

---

## Phase 11: TypeScript bindings

### Task 11.1: Types for `refstore.kind = 'github'`

**Files:**
- Modify: `bindings/typescript/sideshowdb-core/src/types.ts`
- Modify: `bindings/typescript/sideshowdb-core/src/client.test.ts`

- [ ] Add `RefStoreSpec`, `GitHubRefStoreSpec`, `MemoryRefStoreSpec`, `IndexedDbRefStoreSpec`, `SubprocessRefStoreSpec` discriminated union; `HostHttpTransport`, `HostCredentialsResolver` capability types.
- [ ] Add unit test: importing `loadSideshowDbClient` accepts an options object with `refstore: { kind: 'github', owner: 'o', repo: 'r' }` without a TypeScript error (compile-only, asserts via `expectTypeOf` from `expect-type` or equivalent). Confirm the fixture file fails to compile when `owner` is omitted.
- [ ] Run `bun test`; expect green.
- [ ] Commit `feat(ts): GitHub refstore option types`.

### Task 11.2: Browser default HTTP transport + credentials resolver

**Files:**
- Create: `bindings/typescript/sideshowdb-core/src/transport/http.ts`
- Create: `bindings/typescript/sideshowdb-core/src/credentials/host-capability.ts`
- Create: matching `*.test.ts` files

- [ ] Add tests: `createBrowserHttpTransport_round_trips_through_fetch` (uses a fake fetch to assert headers + body marshaling), `createBrowserHttpTransport_passes_through_status_and_etag`, `createBrowserCredentialsResolver_invokes_provider_callback`.
- [ ] Implement the helpers. They serialize headers/body into the buffer layout the WASM `host_http_request` extern expects (matching Task 1.3).
- [ ] Run `bun test`; expect green.
- [ ] Commit `feat(ts): browser HTTP transport + credentials resolver`.

### Task 11.3: Wire `refstore.kind = 'github'` into `loadSideshowDbClient`

**Files:**
- Modify: `bindings/typescript/sideshowdb-core/src/client.ts`
- Modify: `bindings/typescript/sideshowdb-core/src/client.test.ts`

- [ ] Add `loadSideshowDbClient_with_github_refstore_uses_host_transport`: stub `host_http_request` import to record requests; load the WASM module with `refstore: { kind: 'github', ... }`; call `client.put('k', value)`; assert the recorded HTTP requests match the expected GitHub Git DB sequence.
- [ ] Implement: when `options.refstore?.kind === 'github'`, instantiate the WASM module with `host_http_request` + `host_get_credential` imports wired to `hostCapabilities.transport.http` and `hostCapabilities.credentials`.
- [ ] Run `bun test`; expect green.
- [ ] Commit `feat(ts): wire refstore.kind=github through loadSideshowDbClient`.

### Task 11.4: Effect wrapper

**Files:**
- Modify: `bindings/typescript/sideshowdb-effect/src/index.ts`
- Modify: `bindings/typescript/sideshowdb-effect/src/index.test.ts`

- [ ] Add a `createGitHubRefStoreClientEffect({...}) -> Effect<...>` per the project's existing Effect pattern (mirror `createIndexedDbHostStoreEffect`).
- [ ] Add tests covering the success and runtime-load failure paths in the Effect channel.
- [ ] Run `bun test`; expect green.
- [ ] Commit `feat(effect): GitHub refstore Effect wrapper`.

---

## Phase 12: Acceptance suite

### Task 12.1: Mock GitHub server for acceptance

**Files:**
- Create: `acceptance/typescript/src/support/github-mock.ts`
- Modify: `acceptance/typescript/src/support/world.ts`
- Modify: `acceptance/typescript/src/support/hooks.ts`

- [ ] Add `github_mock_smoke_test` (a TypeScript unit test under `acceptance/typescript/src/support/`) that boots the mock, performs the full GHAPI sequence, and asserts the responses match real GitHub shapes for the recorded fixtures.
- [ ] Implement `GitHubMock` exposing methods: `serve(port?: number) -> Promise<{ url: string }>`, `injectFailure({ status, after_n_requests, body })`, `state(): { refs, commits, trees, blobs }`. Use `node:http` (Bun-compatible) for the listener.
- [ ] Add `githubMock` field on the shared World; spin up in `BeforeAll`, tear down in `AfterAll`.
- [ ] Run the acceptance smoke test; expect green.
- [ ] Commit `test(acceptance): mock GitHub server scaffolding`.

### Task 12.2: `github-api-refstore.feature` — PUT scenarios first

**Files:**
- Create: `acceptance/typescript/features/github-api-refstore.feature`
- Create: `acceptance/typescript/src/steps/github-api.steps.ts`

- [ ] Author the feature file leading with PUT scenarios mapped to GHAPI-020 / 021 / 022 / 023 / 024. Each scenario includes a comment block listing the EARS IDs it covers per CLAUDE.md acceptance-test-coverage rules.
- [ ] Implement just enough steps to run the PUT scenarios. Reuse existing `the CLI command succeeds` style step phrasing; introduce new GitHub-specific steps only where needed (e.g. "Given the mock GitHub repo has ref \"refs/sideshowdb/documents\" pointing at commit \"<sha>\"").
- [ ] Run `zig build js:acceptance`; expect green for the new scenarios.
- [ ] Commit `test(acceptance): GitHub API RefStore PUT scenarios`.

### Task 12.3: GET / LIST / DELETE / HISTORY scenarios

**Files:** Modify `github-api-refstore.feature`, `github-api.steps.ts`.

- [ ] Add scenarios for GHAPI-030..034, 040..041, 050..051, 060..061. Add EARS-ID comment blocks.
- [ ] Add steps as needed.
- [ ] Run `zig build js:acceptance`; expect green.
- [ ] Commit `test(acceptance): GitHub API RefStore GET/LIST/DELETE/HISTORY scenarios`.

### Task 12.4: `github-api-auth.feature` scenarios

**Files:**
- Create: `acceptance/typescript/features/github-api-auth.feature`

- [ ] Add scenarios for GHAPI-010..014 (auth source resolution) and GHAPI-070..071 (rate-limit surface). Include both negative and positive paths per CLAUDE.md TDD bar.
- [ ] Wire mock-server failure injection (`injectFailure({ status: 401 })`, etc.) through the steps.
- [ ] Run `zig build js:acceptance`; expect green.
- [ ] Commit `test(acceptance): GitHub API auth scenarios`.

---

## Phase 13: Live integration tests (opt-in)

### Task 13.1: `zig build test:github-live`

**Files:**
- Create: `tests/github_live_test.zig`
- Modify: `build.zig`

- [ ] Add a step `test:github-live` that runs `tests/github_live_test.zig`. Skip via `error.SkipZigTest` when `GITHUB_TEST_TOKEN` and `GITHUB_TEST_REPO` env vars are absent.
- [ ] The test performs put/get/list/delete/history against the configured scratch repo, then deletes the test ref to leave the repo clean.
- [ ] Document the contract in the **Operations** site page under a "Live integration tests" section.
- [ ] Run `zig build test:github-live` locally with a real token to confirm the suite runs green; commit untouched if no token is configured.
- [ ] Commit `test(refstore): opt-in live GitHub integration suite`.

---

## Phase 14: Ziggit removal

> Can land in parallel with any phase after Phase 3.6 ships; nothing in the GitHub API path depends on ziggit.

### Task 14.1: Drop ziggit storage modules

**Files:**
- Delete: `src/core/storage/ziggit_pkg/` (entire tree)
- Delete: `src/core/storage/ziggit_ref_store.zig`
- Delete: `tests/ziggit_ref_store_test.zig`

- [ ] `git rm -r src/core/storage/ziggit_pkg`
- [ ] `git rm src/core/storage/ziggit_ref_store.zig tests/ziggit_ref_store_test.zig`
- [ ] Confirm no remaining references via `grep -rn ziggit src tests build.zig` — expected: zero matches.
- [ ] Do not commit yet; the build will be broken until Tasks 14.2–14.3 land.

### Task 14.2: Update `src/core/storage.zig`

**Files:**
- Modify: `src/core/storage.zig`

- [ ] Remove the `ZiggitRefStore` declaration including the `freestanding` switch.
- [ ] Remove the `pub const GitRefStore = ZiggitRefStore;` alias entirely (no replacement). Callers reference the concrete store they want.
- [ ] Remove the corresponding `_ = @import("storage/ziggit_ref_store.zig");` line in the test block.

### Task 14.3: Update `build.zig`

**Files:**
- Modify: `build.zig`

- [ ] Remove the `ziggit_ref_test_mod`, `ziggit_ref_tests`, `run_ziggit_ref_tests` block in `buildTests`.
- [ ] Remove `test_step.dependOn(&run_ziggit_ref_tests.step);`.
- [ ] Run `zig build test`; expect green.
- [ ] Commit (Tasks 14.1–14.3 land in one commit) `chore(storage): remove ziggit per docs/design/adrs/2026-04-29-deprecate-ziggit.md`.

### Task 14.4: Drop `--refstore ziggit` from CLI

**Files:**
- Modify: `src/cli/app.zig`
- Modify: `tests/cli_test.zig`

- [ ] Remove the `ziggit` value from the `--refstore` enum and any docs/help-text references.
- [ ] Update CLI tests that referenced ziggit; replace expectations with `github` or `subprocess` as appropriate.
- [ ] Run `zig build test`; expect green.
- [ ] Commit `chore(cli): drop --refstore ziggit value`.

### Task 14.5: Sweep documentation

**Files:**
- Modify: any `docs/` and `site/` markdown referencing ziggit (use `grep -rn ziggit docs site CLAUDE.md AGENTS.md README.md` to find them).
- Modify: any `bindings/typescript/**/README.md` referencing ziggit.

- [ ] Replace remaining mentions with the new design references (`docs/design/adrs/2026-04-29-deprecate-ziggit.md` and the GitHub API RefStore design pages).
- [ ] Run `grep -rn ziggit . --exclude-dir=.git --exclude-dir=node_modules` to confirm only the deprecation ADR mentions ziggit.
- [ ] Commit `docs: sweep residual ziggit references`.

### Task 14.6: Close superseded beads issues

**Files:** none.

- [ ] Run `bd close sideshowdb-an4 sideshowdb-dgz --reason "Closed under docs/design/adrs/2026-04-29-deprecate-ziggit.md"`.
- [ ] Run `bd dolt push`.

---

## Phase 15: Final verification + handoff

### Task 15.1: Local verification

**Files:** none.

- [ ] Run `zig build test`; expect green.
- [ ] Run `zig build wasm`; expect `zig-out/wasm/sideshowdb.wasm` artifact.
- [ ] Run `zig build wasm-wasi`; expect `zig-out/wasm/sideshowdb-wasi.wasm` artifact (kept as CI-only).
- [ ] Run `zig build js:check`; expect green.
- [ ] Run `zig build js:test`; expect green.
- [ ] Run `zig build js:acceptance`; expect green for all new scenarios.
- [ ] Run `zig build site`; expect a successful build of the docs site including the five new design pages.
- [ ] If `GITHUB_TEST_TOKEN` is set locally, run `zig build test:github-live`; expect green.

### Task 15.2: Verifier pass + reviewer pass

**Files:** none.

- [ ] Dispatch `oh-my-claudecode:verifier` against the branch with the spec + plan as inputs; capture findings.
- [ ] Dispatch `oh-my-claudecode:code-reviewer` (model=opus) for the high-leverage areas: `github_api_ref_store.zig`, the credential sources, and the acceptance mock. Capture findings.
- [ ] Address findings or file follow-up tickets via `bd create`. Do **not** self-approve.

### Task 15.3: Session close per CLAUDE.md

**Files:** none.

- [ ] Confirm `git status` is clean.
- [ ] `git pull --rebase`
- [ ] `bd dolt push`
- [ ] `git push`
- [ ] Confirm `git status` shows "up to date with origin".

---

## Coverage map (every EARS line lands here)

| EARS | Task |
| ---- | ---- |
| GHAPI-001 | Task 3.1 (init records owner/repo/ref) |
| GHAPI-002 | Task 3.1 (init rejects empty owner/repo) |
| GHAPI-003 | Task 3.1 (default ref name) |
| GHAPI-010 | Task 3.2 (auth missing fail-fast) |
| GHAPI-011 | Task 3.5 (401 -> AuthInvalid) |
| GHAPI-012 | Task 3.5 (403 -> InsufficientScope) |
| GHAPI-013 | Task 3.5 + Task 11.3 (token never logged) |
| GHAPI-014 | Task 2.3 / 2.6 (gh helper unavailable signal) |
| GHAPI-020 | Task 3.3 (put happy path) |
| GHAPI-021 | Task 3.4 (first-write path) |
| GHAPI-022 | Task 3.5 (concurrent update retry) |
| GHAPI-023 | Task 3.5 (ValueTooLarge precheck) |
| GHAPI-024 | Task 3.3 (commit/tree SHA on result) |
| GHAPI-030 | Task 4.1 (get latest tip) |
| GHAPI-031 | Task 4.1 (absent key returns null) |
| GHAPI-032 | Task 4.2 (version-pinned get) |
| GHAPI-033 | Task 4.2 (unknown version returns null) |
| GHAPI-034 | Task 8.1 (304 reuse) |
| GHAPI-040 | Task 5.1 (list) |
| GHAPI-041 | Task 5.2 (list returns empty when ref missing) |
| GHAPI-050 | Task 6.1 (delete present key) |
| GHAPI-051 | Task 6.2 (delete absent key) |
| GHAPI-060 | Task 7.1 (history single page) |
| GHAPI-061 | Task 7.2 (history pagination + history_limit) |
| GHAPI-070 | Task 3.5 (rate-limited) |
| GHAPI-071 | Task 8.2 (rate-limit info on result) |
| GHAPI-080 | Task 3.5 (5xx -> UpstreamUnavailable, bounded retry) |
| GHAPI-081 | Task 3.5 (transport error) |
| GHAPI-082 | Task 4.1 / 5.1 (Corrupt on stale 404) — covered in get/list 404-on-known-SHA tests added in those tasks |

Cucumber acceptance scenarios for every line above land in Task 12.2–12.4 per CLAUDE.md acceptance-test-coverage requirement.
