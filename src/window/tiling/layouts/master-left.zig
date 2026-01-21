//! Master-left layout

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const utils = @import("utils");
const WM = defs.WM;

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(wm: *WM, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    if (log.isDebug()) {
        std.log.debug("[layout:master_left] Tiling {} windows (master={}, stack={})", .{n, m_count, s_count});
    }

    // Calculate master width
    const master_w: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Tile master area
    const m_layout = utils.calcColumnLayout(screen_h, m_count, m);
    for (windows[0..m_count], 0..) |win, i| {
        const row: u16 = @intCast(i);
        utils.configureWindow(wm.conn, win, .{
            .x = @intCast(m.gap),
            .y = @intCast(m.gap + row * m_layout.spacing),
            .width = if (master_w > m.total()) master_w - m.total() else utils.MIN_WINDOW_DIM,
            .height = m_layout.item_h,
        });
    }

    if (s_count == 0) return;

    const stack_w = screen_w - master_w;
    const stack_windows = windows[m_count..];

    // Calculate how many windows fit at full height in the stack
    const space_per_window: u32 = utils.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, screen_h) - @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (s_count <= max_fit) {
        // All windows fit - single column at full width
        const s_layout = utils.calcColumnLayout(screen_h, s_count, m);

        for (stack_windows, 0..) |win, i| {
            const row: u16 = @intCast(i);
            utils.configureWindow(wm.conn, win, .{
                .x = @intCast(master_w),
                .y = @intCast(m.gap + row * s_layout.spacing),
                .width = if (stack_w > m.gap + 2 * m.border)
                    @max(utils.MIN_WINDOW_DIM, stack_w - m.gap - 2 * m.border)
                else
                    utils.MIN_WINDOW_DIM,
                .height = s_layout.item_h,
            });
        }
    } else {
        // Overflow: progressively split rows as needed
        // Calculate layout for rows
        const s_layout = utils.calcColumnLayout(screen_h, max_fit, m);

        if (log.isDebug()) {
            std.log.debug("[layout:master_left] Overflow mode: max_fit={}", .{max_fit});
        }

        // Tile stack windows row by row
        // Each row can have multiple columns: windows at indices i, i+max_fit, i+2*max_fit, etc.
        var row: u16 = 0;
        while (row < max_fit) : (row += 1) {
            // Count how many windows are in this row
            var cols_in_row: u16 = 0;
            var win_idx = row;
            while (win_idx < s_count) : (win_idx += max_fit) {
                cols_in_row += 1;
            }

            if (cols_in_row == 0) break; // No more windows

            const row_col_w = stack_w / cols_in_row;
            const y_pos = m.gap + row * s_layout.spacing;

            if (log.isDebug()) {
                std.log.debug("[layout:master_left] Row {} has {} columns", .{row, cols_in_row});
            }

            // Place all windows in this row
            var col: u16 = 0;
            win_idx = row;
            while (win_idx < s_count) : (win_idx += max_fit) {
                const win = stack_windows[win_idx];
                
                utils.configureWindow(wm.conn, win, .{
                    .x = @intCast(master_w + col * row_col_w),
                    .y = @intCast(y_pos),
                    .width = if (row_col_w > m.gap + 2 * m.border)
                        @max(utils.MIN_WINDOW_DIM, row_col_w - m.gap - 2 * m.border)
                    else
                        utils.MIN_WINDOW_DIM,
                    .height = s_layout.item_h,
                });

                if (log.isDebug()) {
                    std.log.debug("[layout:master_left] Window idx={} -> row={} col={}", .{win_idx, row, col});
                }

                col += 1;
            }
        }
    }
}
