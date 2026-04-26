//! WebAssembly browser client entry. Exposes a minimal C-ABI surface for
//! JavaScript to call via `WebAssembly.instantiate`.
//!
//! Full spec bindings ship in later work; this skeleton just proves the
//! build graph reaches `wasm32-freestanding` cleanly.

const std = @import("std");
const sideshowdb = @import("sideshowdb");

export fn sideshowdb_version_major() u32 {
    return @intCast(sideshowdb.version.major);
}

export fn sideshowdb_version_minor() u32 {
    return @intCast(sideshowdb.version.minor);
}

export fn sideshowdb_version_patch() u32 {
    return @intCast(sideshowdb.version.patch);
}

export fn sideshowdb_banner_ptr() [*]const u8 {
    return sideshowdb.banner.ptr;
}

export fn sideshowdb_banner_len() usize {
    return sideshowdb.banner.len;
}
