// Monocle layout - all windows fullscreen, stacked
// Only the top window is visible
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
const TilingState = @import("tiling_types").TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;

    if (builtin.mode == .Debug) {
        std.debug.print("[monocle] Tiling {} windows fullscreen\n", .{windows.len});
    }

    // All windows fullscreen, stacked
    for (windows) |win| {
        configureWindow(wm, win,
            gap,
            gap,
            screen_w - 2 * gap - 2 * bw,
            screen_h - 2 * gap - 2 * bw);
    }

    // Raise last window to top
    if (windows.len > 0) {
        _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1],
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
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
