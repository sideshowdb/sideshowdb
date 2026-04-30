//! Storage subsystem — implementations of the `RefStore` abstraction.
//!
//! The `RefStore` interface is always available. Concrete implementations
//! that depend on host facilities (subprocesses, filesystem) are gated to
//! non-freestanding targets so the wasm32-freestanding build still compiles.

const builtin = @import("builtin");

/// Section-scoped key/value `RefStore` interface backed by a single git ref.
/// Re-exported from `storage/ref_store.zig`; see that module for the full
/// contract.
pub const RefStore = @import("storage/ref_store.zig").RefStore;

/// In-process, in-memory `RefStore` implementation. Available on every
/// target — including `wasm32-freestanding` — because it depends only on
/// the allocator and standard collection types. Volatile: data is lost when
/// the store is dropped.
pub const MemoryRefStore = @import("storage/memory_ref_store.zig").MemoryRefStore;

/// Composite `RefStore` that fronts a canonical `RefStore` with one or
/// more cache `RefStore`s. Every successful `put`/`delete` blocks until
/// canonical accepts. Available on every target because it composes
/// existing `RefStore` views and depends only on the allocator. See
/// `docs/development/specs/write-through-store-spec.md` for the
/// contract and `docs/development/decisions/2026-04-29-caching-model.md`
/// for the deliberation that produced this primitive.
pub const WriteThroughRefStore = @import("storage/write_through_ref_store.zig").WriteThroughRefStore;

/// Subprocess-driven `RefStore` implementation that delegates every
/// operation to the user's `git` binary. Resolves to `void` on
/// freestanding targets (e.g. the wasm32 build) where subprocesses are
/// unavailable.
pub const SubprocessGitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/git_ref_store.zig").SubprocessGitRefStore,
};

/// Native `std.http.Client` transport. Unavailable on `wasm32-freestanding`.
pub const StdHttpTransport = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/std_http_transport.zig").StdHttpTransport,
};

/// WASM host-driven `HttpTransport` using `sideshowdb_host_http_request`.
pub const HostHttpTransport = switch (builtin.os.tag) {
    .freestanding, .wasi => @import("storage/host_http_transport.zig").HostHttpTransport,
    else => void,
};

/// Default native `GitRefStore` alias. Resolves to
/// `SubprocessGitRefStore`; callers that need an alternate backend should
/// request it explicitly.
pub const GitRefStore = SubprocessGitRefStore;

test {
    _ = @import("storage/ref_store.zig");
    _ = @import("storage/memory_ref_store.zig");
    _ = @import("storage/write_through_ref_store.zig");
    _ = @import("storage/http_transport.zig");
    if (builtin.os.tag == .freestanding or builtin.os.tag == .wasi) {
        _ = @import("storage/host_http_transport.zig");
    }
    if (builtin.os.tag != .freestanding) {
        _ = @import("storage/git_ref_store.zig");
        _ = @import("storage/std_http_transport.zig");
    }
}
