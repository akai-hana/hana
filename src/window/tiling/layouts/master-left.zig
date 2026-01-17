// Master-left tiling layout - optimized and simplified

const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const log = @import("logging");
const WM = defs.WM;
const types = @import("types");
const TilingState = types.TilingState;

fn calcColumnHeight(screen_h: u16, count: u16, gap: u16, bw: u16) struct { win_h: u16, total_gap: u32 } {
    const gap32: u32 = gap;
    const bw32: u32 = bw;
    const count32: u32 = count;

    const outer_gaps = 2 * gap32;
    const borders = count32 * 2 * bw32;
    const inner_gaps = if (count > 1) (count32 - 1) * gap32 else 0;
    const total_overhead = outer_gaps + borders + inner_gaps;

    const available = if (screen_h > total_overhead)
        @as(u32, screen_h) - total_overhead
    else
        count32 * 10; // Fallback minimum

    return .{
        .win_h = @intCast(available / count32),
        .total_gap = gap32,
    };
}

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    if (builtin.mode == .Debug) {
        log.debugLayoutMasterLeft(n, state.master_count, m_count, s_count, screen_w);
    }

    const master_width: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Pre-calculate column dimensions
    const master_dims = calcColumnHeight(screen_h, m_count, gap, bw);
    const stack_dims = if (s_count > 0) 
        calcColumnHeight(screen_h, s_count, gap, bw) 
    else 
        @TypeOf(master_dims){ .win_h = 0, .total_gap = 0 };

    for (windows, 0..) |win, idx| {
        var x: u16 = undefined;
        var y: u16 = undefined;
        var w: u16 = undefined;
        var h: u16 = undefined;

        if (idx < m_count) {
            // Master area: gap on left and right within master region
            const row: u16 = @intCast(idx);
            x = gap;
            y = @intCast(gap + row * (master_dims.win_h + 2 * bw + gap));
            w = if (master_width > 2 * gap + 2 * bw) 
                master_width - 2 * gap - 2 * bw 
            else 
                1;
            h = master_dims.win_h;
        } else {
            // Stack area: starts at master boundary, gap only on right
            const row: u16 = @intCast(idx - m_count);
            const stack_width = screen_w - master_width;
            x = master_width;
            y = @intCast(gap + row * (stack_dims.win_h + 2 * bw + gap));
            w = if (stack_width > gap + 2 * bw) 
                stack_width - gap - 2 * bw 
            else 
                1;
            h = stack_dims.win_h;
        }

        types.configureWindow(wm, win, x, y, w, h);

        if (builtin.mode == .Debug) {
            log.debugLayoutWindowGeometry(idx, x, y, w, h, idx < m_count);
        }
    }
}
