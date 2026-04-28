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

/// Subprocess-driven `RefStore` implementation that delegates every
/// operation to the user's `git` binary. Resolves to `void` on
/// freestanding targets (e.g. the wasm32 build) where subprocesses are
/// unavailable.
pub const SubprocessGitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/git_ref_store.zig").SubprocessGitRefStore,
};

/// In-process ziggit-backed `RefStore` implementation. Resolves to `void`
/// on freestanding targets (e.g. the wasm32 build) where the host
/// filesystem facilities the backend depends on are unavailable.
pub const ZiggitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/ziggit_ref_store.zig").ZiggitRefStore,
};

/// Default native `GitRefStore` alias. Currently resolves to
/// `SubprocessGitRefStore`; a follow-up task swaps this to the ziggit-backed
/// backend once the production port lands.
pub const GitRefStore = SubprocessGitRefStore;

test {
    _ = @import("storage/ref_store.zig");
    if (builtin.os.tag != .freestanding) {
        _ = @import("storage/git_ref_store.zig");
        _ = @import("storage/ziggit_ref_store.zig");
    }
}
