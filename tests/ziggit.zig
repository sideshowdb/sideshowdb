//! Standalone `zig test tests/ziggit_ref_store_test.zig` does not receive the
//! `build.zig` dependency graph, so this shim points directly at the fetched
//! `ziggit` source tree under local `zig-pkg/`.

const ziggit = @import("ziggit_pkg/ziggit.zig");

pub const Repository = ziggit.Repository;
