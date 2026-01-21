//! Master-left layout: master area on left, stack on right.
//!
//! Normal (all fit):        With wrapping (progressive pairing):
//! ┌──────────┬──────┐      ┌──────────┬───┬───┐
//! │          │  S1  │      │          │S1 │S4 │  <- First row pair
//! │          ├──────┤      │          ├───┼───┤
//! │  Master  │  S2  │      │  Master  │S2 │S5 │  <- Second row pair
//! │          ├──────┤      │          ├───┼───┤
//! │          │  S3  │      │          │S3 │S6 │  <- Third row pair
//! └──────────┴──────┘      └──────────┴───┴───┘

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

    // Calculate how many windows can fit at full height in the stack area
    const stack_w = screen_w - master_w;
    const space_per_window: u32 = utils.MIN_WINDOW_DIM + 2 * @as(u32, m.border) + @as(u32, m.gap);
    const available: u32 = @as(u32, screen_h) - @as(u32, m.gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (s_count <= max_fit) {
        // All windows fit - single column at full width
        const s_layout = utils.calcColumnLayout(screen_h, s_count, m);

        for (windows[m_count..], 0..) |win, i| {
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

            if (log.isDebug()) {
                std.log.debug("[layout:master_left] Stack[{}] full-width", .{i});
            }
        }
    } else {
        // Overflow: pair windows as needed
        // First max_fit windows go in left column
        // Overflow windows pair with them on the right
        const overflow_count: u16 = s_count - max_fit;
        const half_stack_w = stack_w / 2;

        if (log.isDebug()) {
            std.log.debug("[layout:master_left] Overflow pairing: {} base, {} overflow",
                .{max_fit, overflow_count});
        }

        const base_layout = utils.calcColumnLayout(screen_h, max_fit, m);

        // Tile all windows
        for (windows[m_count..], 0..) |win, i| {
            const idx: u16 = @intCast(i);
            
            if (idx < max_fit) {
                // First max_fit windows - check if they have a pair
                const has_pair = idx < overflow_count;
                const row: u16 = idx;

                utils.configureWindow(wm.conn, win, .{
                    .x = @intCast(master_w),
                    .y = @intCast(m.gap + row * base_layout.spacing),
                    .width = if (has_pair) blk: {
                        break :blk if (half_stack_w > m.gap + 2 * m.border)
                            @max(utils.MIN_WINDOW_DIM, half_stack_w - m.gap - 2 * m.border)
                        else
                            utils.MIN_WINDOW_DIM;
                    } else blk: {
                        break :blk if (stack_w > m.gap + 2 * m.border)
                            @max(utils.MIN_WINDOW_DIM, stack_w - m.gap - 2 * m.border)
                        else
                            utils.MIN_WINDOW_DIM;
                    },
                    .height = base_layout.item_h,
                });

                if (log.isDebug()) {
                    const width_type = if (has_pair) "half" else "full";
                    std.log.debug("[layout:master_left] Stack[{}] left, row {} ({})", .{i, row, width_type});
                }
            } else {
                // Overflow windows - pair with earlier windows
                const pair_idx = idx - max_fit;
                const row: u16 = pair_idx;

                utils.configureWindow(wm.conn, win, .{
                    .x = @intCast(master_w + half_stack_w),
                    .y = @intCast(m.gap + row * base_layout.spacing),
                    .width = if (half_stack_w > m.gap + 2 * m.border)
                        @max(utils.MIN_WINDOW_DIM, half_stack_w - m.gap - 2 * m.border)
                    else
                        utils.MIN_WINDOW_DIM,
                    .height = base_layout.item_h,
                });

                if (log.isDebug()) {
                    std.log.debug("[layout:master_left] Stack[{}] right, row {} (paired)", .{i, row});
                }
            }
        }
    }
}
