//! Storage subsystem — implementations of the `RefStore` abstraction.
//!
//! The `RefStore` interface is always available. Concrete implementations
//! that depend on host facilities (subprocesses, filesystem) are gated to
//! non-freestanding targets so the wasm32-freestanding build still compiles.

const builtin = @import("builtin");

pub const RefStore = @import("storage/ref_store.zig").RefStore;

pub const GitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/git_ref_store.zig").GitRefStore,
};

test {
    _ = @import("storage/ref_store.zig");
    if (builtin.os.tag != .freestanding) {
        _ = @import("storage/git_ref_store.zig");
    }
}
