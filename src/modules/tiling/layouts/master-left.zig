// Master-left tiling layout (dwm-style)
// Master windows on the left, stack windows on the right
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
const TilingState = @import("tiling_types").TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // Determine how many windows in master vs stack
    const m_count = @min(state.master_count, n);
    const s_count = if (n > m_count) n - m_count else 0;

    if (builtin.mode == .Debug) {
        std.debug.print("[master-left] n={}, master_count={}, m_count={}, s_count={}, screen_w={}\n",
            .{n, state.master_count, m_count, s_count, screen_w});
    }

    // Calculate master column width
    const master_width: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Calculate stack column width
    const stack_width: u16 = if (s_count > 0) screen_w - master_width else 0;

    for (windows, 0..) |win, idx| {
        var x: u16 = 0;
        var y: u16 = 0;
        var w: u16 = 0;
        var h: u16 = 0;

        if (idx < m_count) {
            // MASTER COLUMN (left side)
            const row_height = screen_h / @as(u16, @intCast(m_count));
            const row = @as(u16, @intCast(idx));

            x = gap;
            y = gap + (row * row_height);
            w = if (master_width > 2 * gap + 2 * bw)
                master_width - 2 * gap - 2 * bw
            else 1;

            // For the last master window, fit exactly to screen bottom
            if (row == m_count - 1) {
                const available = screen_h - y - gap;
                h = if (available > 2 * bw) available - 2 * bw else 1;
            } else {
                h = if (row_height > 2 * gap + 2 * bw)
                    row_height - 2 * gap - 2 * bw
                else 1;
            }
        } else {
            // STACK COLUMN (right side)
            const stack_idx = idx - m_count;
            const row_height = screen_h / @as(u16, @intCast(s_count));
            const row = @as(u16, @intCast(stack_idx));

            x = master_width + gap;
            y = gap + (row * row_height);
            w = if (stack_width > 2 * gap + 2 * bw)
                stack_width - 2 * gap - 2 * bw
            else 1;

            // For the last stack window, fit exactly to screen bottom
            if (stack_idx == s_count - 1) {
                const available = screen_h - y - gap;
                h = if (available > 2 * bw) available - 2 * bw else 1;
            } else {
                h = if (row_height > 2 * gap + 2 * bw)
                    row_height - 2 * gap - 2 * bw
                else 1;
            }
        }

        configureWindow(wm, win, x, y, w, h);

        if (builtin.mode == .Debug) {
            std.debug.print("[master-left] Window {}: x={}, y={}, w={}, h={} (master={})\n",
                .{idx, x, y, w, h, idx < m_count});
        }
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
