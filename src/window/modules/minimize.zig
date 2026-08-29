//! Window minimization, model-backed queries.
//! Minimize state lives in the model; this module exposes read-side helpers for the bar and focus/fullscreen predicates.

const std = @import("std");
const pipeline = @import("pipeline");

pub fn init() anyerror!void {}

pub fn deinit() void {}

/// True when `win` currently holds a minimized record in the model.
pub fn isMinimized(win: u32) bool {
    return @import("model").isMinimized(pipeline.model(), win);
}

/// Fills `set` with every currently minimized window ID, replacing any prior contents.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
pub fn collectMinimizedIntoSet(
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    return @import("model").collectMinimizedIntoSet(pipeline.model(), set, allocator);
}

/// This module's window sub-system contribution: lifecycle only, since
/// minimized state lives in the model.
pub const module: @import("plugin").WindowModule = .{
    .init = init,
    .deinit = deinit,
};
