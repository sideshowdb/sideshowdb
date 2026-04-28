//! Test-local storage shim for standalone `zig test tests/git_ref_store_test.zig`.
//!
//! The standalone Zig test runner treats `tests/` as the module root, so it
//! cannot import `../src/...` directly. This shim mirrors the storage exports
//! needed by the Task 1 backend parity tests without relying on build.zig
//! module aliases or filesystem symlinks.

const builtin = @import("builtin");

pub const RefStore = @import("storage/ref_store.zig").RefStore;

pub const GitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/git_ref_store.zig").GitRefStore,
};
