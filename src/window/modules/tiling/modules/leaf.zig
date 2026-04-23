//! Binary space partitioning tiling layout
//! Recursively partitions the screen using a balanced binary tree.

const utils     = @import("utils");
const constants = @import("constants");

const tiling  = @import("tiling");
const layouts = @import("layouts");

/// Tile `windows` into a balanced BSP layout using the given screen area.
///
/// Strips the outer `gap_width` margin on all four sides, then hands off to
/// the recursive `tileRegion` splitter.  Mirrors the tileWithOffset signature
/// of every other layout module.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *tiling.State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    if (windows.len == 0) return;

    const m = state.margins();

    // Strip the outer gap on all four edges before entering the recursive splitter.
    // Each subsequent split inserts exactly one gap at its seam, so the total
    // padding between any two adjacent windows equals gap_width.
    tileRegion(
        ctx,
        windows,
        m,
        @as(i32, @intCast(m.gap)),
        @as(i32, @intCast(y_offset +| m.gap)),
        screen_w -| m.gap *| 2,
        screen_h -| m.gap *| 2,
    );
}

// Private helpers

/// Recursively assign each window in `windows` to a sub-rectangle of the
/// region described by (x, y, w, h).
fn tileRegion(
    ctx:     *const layouts.LayoutCtx,
    windows: []const u32,
    m:       utils.Margins,
    x: i32,
    y: i32,
    w: u16,
    h: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const b2: u16 = 2 *| m.border;

    // Leaf
    // Place the single window in this region
    if (n == 1) {
        layouts.configureWithHints(ctx, windows[0], .{
            .x      = x,
            .y      = y,
            .width  = if (w > b2) w - b2 else constants.MIN_WINDOW_DIM,
            .height = if (h > b2) h - b2 else constants.MIN_WINDOW_DIM,
        });
        return;
    }

    // Internal node
    // Split this region into two and recurse 
    const n_left: usize = n / 2;
    const gap = m.gap;

    if (w >= h) {
        // Vertical split (wide / square region) 
        const left_w: u16  = if (w > gap) (w - gap) / 2 else constants.MIN_WINDOW_DIM;
        const right_w: u16 = if (w > left_w +| gap) w - left_w - gap
                             else constants.MIN_WINDOW_DIM;
        const right_x: i32 = x + @as(i32, @intCast(left_w +| gap));

        tileRegion(ctx, windows[0..n_left], m, x,       y, left_w,  h);
        tileRegion(ctx, windows[n_left..],  m, right_x, y, right_w, h);
    } else {
        // Horizontal split (tall region) 
        const top_h: u16    = if (h > gap) (h - gap) / 2 else constants.MIN_WINDOW_DIM;
        const bottom_h: u16 = if (h > top_h +| gap) h - top_h - gap
                              else constants.MIN_WINDOW_DIM;
        const bottom_y: i32 = y + @as(i32, @intCast(top_h +| gap));

        tileRegion(ctx, windows[0..n_left], m, x, y,        w, top_h);
        tileRegion(ctx, windows[n_left..],  m, x, bottom_y, w, bottom_h);
    }
}
