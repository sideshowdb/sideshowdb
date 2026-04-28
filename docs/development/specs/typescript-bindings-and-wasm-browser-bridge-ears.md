# TypeScript Bindings And WASM Browser Bridge EARS

- When the repo's JavaScript and TypeScript projects are installed, the repo
  shall provide a top-level Bun workspace that includes `site`,
  `bindings/typescript/sideshowdb-core`, and
  `bindings/typescript/sideshowdb-effect`.
- When a browser consumer uses the core TypeScript binding package, the package
  shall expose first-class document `put`, `get`, `list`, `history`, and
  `delete` operations backed by the shipped `sideshowdb.wasm` artifact.
- When the core TypeScript binding invokes a WASM document operation, the
  binding shall manage request-buffer writes and result-buffer reads internally
  rather than requiring application code to manipulate raw guest memory.
- When a WASM-backed `get` request does not resolve a document, the TypeScript
  binding shall report a distinct not-found outcome rather than a generic
  operational failure.
- If the WASM runtime cannot be loaded, then the TypeScript binding shall
  report a runtime-load failure with explicit error signaling.
- If the host bridge required by the WASM module is unavailable or incomplete,
  then the TypeScript binding shall report a host-bridge failure with explicit
  error signaling.
- When the docs site uses browser-side Sideshowdb bindings, the site shall
  consume the public `bindings/typescript/sideshowdb-core` package rather than
  treating a site-local WASM wrapper as the canonical client.
- When repo-wide JS/TS build tasks run, the repo shall keep `build.zig` as the
  top-level orchestrator for those tasks.
- Where the Effect binding package is provided, the repo shall expose the same
  document operation capabilities through an Effect-native API without changing
  the underlying request/response contract.
