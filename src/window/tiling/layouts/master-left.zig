// Master-left tiling layout (dwm-style)
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const log = @import("logging");
const WM = defs.WM;
const types = @import("types");
const TilingState = types.TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;
    const m_count = @min(state.master_count, n);
    const s_count = if (n > m_count) n - m_count else 0;

    if (builtin.mode == .Debug) {
        log.debugLayoutMasterLeft(n, state.master_count, m_count, s_count, screen_w);
    }

    const master_width: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);
    const stack_width: u16 = if (s_count > 0) screen_w - master_width else 0;

    for (windows, 0..) |win, idx| {
        var x: u16 = 0;
        var y: u16 = 0;
        var w: u16 = 0;
        var h: u16 = 0;

        if (idx < m_count) {
            // MASTER AREA
            const row: u16 = @intCast(idx);
            const m_count_u16: u16 = @intCast(m_count);

            // Calculate available vertical space:
            // Total space minus outer gaps (top + bottom) minus borders for all windows
            const total_outer_gaps: u32 = 2 * @as(u32, gap);
            const total_borders: u32 = @as(u32, m_count_u16) * 2 * @as(u32, bw);
            
            // Space between windows: (m_count - 1) gaps
            const total_inner_gaps: u32 = if (m_count_u16 > 1) 
                (@as(u32, m_count_u16) - 1) * @as(u32, gap)
            else 
                0;

            const available_height: u32 = if (screen_h > total_outer_gaps + total_borders + total_inner_gaps)
                @as(u32, screen_h) - total_outer_gaps - total_borders - total_inner_gaps
            else
                @as(u32, m_count_u16) * 10; // Fallback minimum

            const win_height: u16 = @intCast(available_height / @as(u32, m_count_u16));

            x = gap;
            // Position: outer_gap + (row * (window_height + borders + gap_between))
            y = @intCast(@as(u32, gap) + @as(u32, row) * (@as(u32, win_height) + 2 * @as(u32, bw) + @as(u32, gap)));
            w = types.calcWindowDimension(master_width, gap, bw);
            h = @max(1, win_height);
        } else {
            // STACK AREA
            const stack_idx = idx - m_count;
            const row: u16 = @intCast(stack_idx);
            const s_count_u16: u16 = @intCast(s_count);

            // Same calculation as master
            const total_outer_gaps: u32 = 2 * @as(u32, gap);
            const total_borders: u32 = @as(u32, s_count_u16) * 2 * @as(u32, bw);
            
            const total_inner_gaps: u32 = if (s_count_u16 > 1)
                (@as(u32, s_count_u16) - 1) * @as(u32, gap)
            else
                0;

            const available_height: u32 = if (screen_h > total_outer_gaps + total_borders + total_inner_gaps)
                @as(u32, screen_h) - total_outer_gaps - total_borders - total_inner_gaps
            else
                @as(u32, s_count_u16) * 10;

            const win_height: u16 = @intCast(available_height / @as(u32, s_count_u16));

            x = master_width + gap;
            y = @intCast(@as(u32, gap) + @as(u32, row) * (@as(u32, win_height) + 2 * @as(u32, bw) + @as(u32, gap)));
            w = types.calcWindowDimension(stack_width, gap, bw);
            h = @max(1, win_height);
        }

        types.configureWindow(wm, win, x, y, w, h);
        if (builtin.mode == .Debug) {
            log.debugLayoutWindowGeometry(idx, x, y, w, h, idx < m_count);
        }
    }
}
