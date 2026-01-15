// Grid layout - windows arranged in a grid pattern
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
const TilingState = @import("tiling_types").TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;
    const n = windows.len;

    // Calculate grid dimensions
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(n))));
    const cols = @as(u16, @intFromFloat(cols_f));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));

    if (builtin.mode == .Debug) {
        std.debug.print("[grid] Tiling {} windows in {}x{} grid\n", .{n, cols, rows});
    }

    const cell_w = screen_w / cols;
    const cell_h = screen_h / rows;

    for (windows, 0..) |win, idx| {
        const col = @as(u16, @intCast(idx % cols));
        const row = @as(u16, @intCast(idx / cols));

        const x = gap + (col * cell_w);
        const y = gap + (row * cell_h);
        const w = if (cell_w > 2 * gap + 2 * bw)
            cell_w - 2 * gap - 2 * bw
        else 1;
        const h = if (cell_h > 2 * gap + 2 * bw)
            cell_h - 2 * gap - 2 * bw
        else 1;

        configureWindow(wm, win, x, y, w, h);
    }
}

fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    const values = [_]u32{
        x,
        y,
        @max(1, width),
        @max(1, height),
    };

    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}
