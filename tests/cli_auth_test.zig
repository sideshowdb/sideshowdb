//! Aggregated test entry point for the CLI auth subsystem.
//!
//! Drags in the auth modules so their inline `test` blocks run under
//! `zig build test`.

test {
    _ = @import("cli_auth_hosts_file");
    _ = @import("cli_auth_redact");
    _ = @import("cli_auth_secure_prompt");
}
