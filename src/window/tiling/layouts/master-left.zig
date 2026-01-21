//! Master-left layout: master area on left, stack on right with wrapping.
//!
//! Normal:              With wrapping (when any windows clip at the bottom):
//! ┌──────────┬──────┐  ┌──────────┬───┬───┐
//! │          │  S1  │  │          │S1 │S4 │
//! │          ├──────┤  │          ├───┴───┤
//! │  Master  │  S2  │  │  Master  │  S2   │
//! │          ├──────┤  │          ├───────┤
//! │          │  S3  │  │          │  S3   │
//! └──────────┴──────┘  └──────────┴───────┘


const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const utils = @import("utils");
const WM = defs.WM;

// Import the State type from tiling module
const tiling = @import("tiling");
const State = tiling.State;

/// Calculate how many windows can fit at full height vs need wrapping
fn calcProgressiveLayout(s_count: u16, screen_h: u16, gap: u16, bw: u16) struct {
    /// Windows that fit in first column at full height
    first_col: u16,
    /// Windows that need to wrap (share space in additional columns)
    wrapped: u16,
    /// How many columns the wrapped windows need
    wrap_cols: u16,
} {
    if (s_count == 0) return .{ .first_col = 0, .wrapped = 0, .wrap_cols = 0 };

    const space_per_window: u32 = utils.MIN_WINDOW_DIM + 2 * @as(u32, bw) + @as(u32, gap);
    const available: u32 = @as(u32, screen_h) - @as(u32, gap);
    const max_fit: u16 = @intCast(@max(1, available / space_per_window));

    if (s_count <= max_fit) {
        // All windows fit in one column
        return .{ .first_col = s_count, .wrapped = 0, .wrap_cols = 0 };
    }

    // Some windows fit at full height, rest need wrapping
    const first_col = max_fit;
    const wrapped = s_count - first_col;

    // Wrapped windows share columns (2 per column to avoid clipping)
    const wrap_cols: u16 = @intCast((wrapped + 1) / 2);

    return .{ .first_col = first_col, .wrapped = wrapped, .wrap_cols = wrap_cols };
}

pub fn tile(wm: *WM, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();
    const m_count: u16 = @intCast(@min(state.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    if (log.isDebug()) {
        std.log.debug("[layout:master_left] Tiling {} windows (master={}, stack={})", .{n, m_count, s_count});
    }

    const master_w: u16 = if (s_count == 0)
        screen_w
    else
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Calculate progressive wrapping layout
    const layout = calcProgressiveLayout(s_count, screen_h, m.gap, m.border);

    if (log.isDebug() and s_count > 0) {
        std.log.debug("[layout:master_left] Progressive: {} full-height, {} wrapped in {} cols", .{
            layout.first_col, layout.wrapped, layout.wrap_cols
        });
    }

    // Calculate widths for stack columns
    const stack_w = screen_w - master_w;
    const first_col_width = if (layout.wrap_cols == 0)
        stack_w  // No wrapping, first column gets full width
    else
        (stack_w * 2) / 3;  // With wrapping, first column gets 2/3, wrapped columns share 1/3

    const wrap_col_width = if (layout.wrap_cols > 0)
        (stack_w - first_col_width) / layout.wrap_cols
    else
        0;

    const m_layout = utils.calcColumnLayout(screen_h, m_count, m);
    const first_col_layout = if (layout.first_col > 0)
        utils.calcColumnLayout(screen_h, layout.first_col, m)
    else
        @TypeOf(m_layout){ .item_h = 0, .spacing = 0 };

    // Layout for wrapped windows (2 per column)
    const wrap_layout = if (layout.wrapped > 0)
        utils.calcColumnLayout(screen_h, 2, m)
    else
        @TypeOf(m_layout){ .item_h = 0, .spacing = 0 };

    for (windows, 0..) |win, i| {
        const rect = if (i < m_count) blk: {
            // Master area
            const row: u16 = @intCast(i);
            break :blk utils.Rect{
                .x = @intCast(m.gap),
                .y = @intCast(m.gap + row * m_layout.spacing),
                .width = if (master_w > m.total()) master_w - m.total() else utils.MIN_WINDOW_DIM,
                .height = m_layout.item_h,
            };
        } else blk: {
            const stack_idx = i - m_count;

            if (stack_idx < layout.first_col) {
                // First column: full-height windows
                break :blk utils.Rect{
                    .x = @intCast(master_w),
                    .y = @intCast(m.gap + stack_idx * first_col_layout.spacing),
                    .width = if (first_col_width > m.gap + 2 * m.border)
                        @max(utils.MIN_WINDOW_DIM, first_col_width - m.gap - 2 * m.border)
                    else
                        utils.MIN_WINDOW_DIM,
                    .height = first_col_layout.item_h,
                };
            } else {
                // Wrapped windows: 2 per column
                const wrap_idx = stack_idx - layout.first_col;
                const col: u16 = @intCast(wrap_idx / 2);
                const row: u16 = @intCast(wrap_idx % 2);

                break :blk utils.Rect{
                    .x = @intCast(master_w + first_col_width + col * wrap_col_width),
                    .y = @intCast(m.gap + row * wrap_layout.spacing),
                    .width = if (wrap_col_width > m.gap + 2 * m.border)
                        @max(utils.MIN_WINDOW_DIM, wrap_col_width - m.gap - 2 * m.border)
                    else
                        utils.MIN_WINDOW_DIM,
                    .height = wrap_layout.item_h,
                };
            }
        };

        utils.configureWindow(wm.conn, win, rect);

        if (log.isDebug() and i >= m_count) {
            const stack_idx = i - m_count;
            if (stack_idx < layout.first_col) {
                std.log.debug("[layout:master_left] Win {} -> stack[{}] full-height at {}x{}+{}+{}", .{
                    i, stack_idx, rect.width, rect.height, rect.x, rect.y
                });
            } else {
                const wrap_idx = stack_idx - layout.first_col;
                const col = wrap_idx / 2;
                const row = wrap_idx % 2;
                std.log.debug("[layout:master_left] Win {} -> stack[{}] wrapped col={} row={} at {}x{}+{}+{}", .{
                    i, stack_idx, col, row, rect.width, rect.height, rect.x, rect.y
                });
            }
        }
    }
}
