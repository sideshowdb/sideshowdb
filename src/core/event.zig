//! Placeholder event type. Real schema lands when the spec is implemented.

const std = @import("std");

/// Append-only domain event placeholder.
///
/// Schema firms up when the event store spec lands; today it carries the
/// minimum identity needed by the downstream wasm and CLI surfaces. The
/// struct stores raw slices and does not own any of them, so callers must
/// keep the underlying memory alive for the event's lifetime.
pub const Event = struct {
    event_id: []const u8,
    event_type: []const u8,
    aggregate_id: []const u8,
    timestamp_ms: i64,

    /// Build an `Event` from raw fields. No allocation; slices are stored
    /// by reference. `timestamp_ms` is wall-clock milliseconds since the
    /// Unix epoch.
    ///
    /// Example (from `test "Event init stores fields"`):
    /// ```
    /// const e = Event.init("evt-1", "Created", "agg-1", 42);
    /// ```
    pub fn init(
        event_id: []const u8,
        event_type: []const u8,
        aggregate_id: []const u8,
        timestamp_ms: i64,
    ) Event {
        return .{
            .event_id = event_id,
            .event_type = event_type,
            .aggregate_id = aggregate_id,
            .timestamp_ms = timestamp_ms,
        };
    }
};

test "Event init stores fields" {
    const e = Event.init("evt-1", "Created", "agg-1", 42);
    try std.testing.expectEqualStrings("evt-1", e.event_id);
    try std.testing.expectEqualStrings("Created", e.event_type);
    try std.testing.expectEqualStrings("agg-1", e.aggregate_id);
    try std.testing.expectEqual(@as(i64, 42), e.timestamp_ms);
}
