//! Monocle layout - All windows fullscreen, stacked

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const batch = @import("batch");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    tileWithOffset(b, state, windows, screen_w, screen_h, 0);
}

pub fn tileWithOffset(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    _ = state;
    if (windows.len == 0) return;

    const rect = utils.Rect{
        .x = 0,
        .y = @intCast(y_offset),
        .width = screen_w,
        .height = screen_h,
    };

    // Configure all windows to fullscreen
    for (windows) |win| {
        b.configure(win, rect) catch |err| {
            std.log.err("[monocle] Failed to configure window {x}: {}", .{ win, err });
        };
    }

    // Raise the last window (most recently focused in tiled_windows order)
    const top_win = windows[windows.len - 1];
    b.raise(top_win) catch |err| {
        std.log.err("[monocle] Failed to raise window {x}: {}", .{ top_win, err });
    };
}
