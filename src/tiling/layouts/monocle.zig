//! Monocle layout: all windows fullscreen, stacked; only top window visible.

const defs      = @import("defs");
const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");

const tiling = @import("tiling");
const State  = tiling.State;
const xcb    = defs.xcb;

pub fn tileWithOffset(ctx: *const layouts.LayoutCtx, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    if (windows.len == 0) return;

    const margin = state.margins();
    const gap     = margin.gap;
    const border2 = margin.border * 2;

    // All windows share the same geometry but only the top one is visible.
    // Configure and raise only that one; the others are configured lazily
    // when brought to the top, keeping cost O(1).
    const top_win = windows[windows.len - 1];

    const gap2b = gap * 2 + border2;
    const rect: utils.Rect = switch (state.layout_variations.monocle) {
        .gapless => .{
            .x      = 0,
            .y      = @intCast(y_offset),
            .width  = if (screen_w > border2) screen_w - border2 else constants.MIN_WINDOW_DIM,
            .height = if (screen_h > border2) screen_h - border2 else constants.MIN_WINDOW_DIM,
        },
        .gaps => .{
            .x      = @intCast(gap),
            .y      = @intCast(y_offset +| gap),
            .width  = if (screen_w > gap2b) screen_w - gap2b else constants.MIN_WINDOW_DIM,
            .height = if (screen_h > gap2b) screen_h - gap2b else constants.MIN_WINDOW_DIM,
        },
    };

    layouts.configureSafe(ctx, top_win, rect);
    _ = xcb.xcb_configure_window(ctx.conn, top_win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Push every non-top window offscreen immediately so they never sit on top
    // of (or show through) the top window.  This mirrors what the workspace
    // switcher does in retileInactiveWorkspace — without it, background windows
    // remain at their last on-screen coordinates, which is visible through
    // transparent windows.
    //
    // We also zero each window's cached rect so restoreWorkspaceGeom does not
    // attempt to replay a stale on-screen position for them; it will instead
    // fall back to a full retile, which correctly repeats this offscreen push.
    for (windows[0 .. windows.len - 1]) |win| {
        _ = xcb.xcb_configure_window(ctx.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        if (ctx.cache) |cache| {
            if (cache.getPtr(win)) |wd| wd.rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
    }
}
