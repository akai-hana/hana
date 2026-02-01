///! Title segment

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const utils = @import("utils");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    wm: *defs.WM,
    cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator: std.mem.Allocator,
) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    const has_windows = ws_state.workspaces[ws_state.current].windows.items.len > 0;

    const is_focused = has_windows and wm.focused_window != null;
    const bg = if (is_focused and config.title_accent) config.getTitleAccent() else config.bg;
    const fg = if (is_focused and config.title_accent) config.selected_fg else config.fg;

    dc.fillRect(start_x, 0, width, height, bg);

    if (has_windows) {
        const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);

        if (title.len > 0) {
            try dc.drawTextEllipsis(
                start_x + config.padding,
                dc.baselineY(height),
                title,
                width - config.padding * 2,
                fg,
            );
        }
    }
    
    return start_x + width;
}

/// Fetch a single X property into cached_title, returning the slice on success or "" on failure.
fn fetchProperty(
    conn: *xcb.xcb_connection_t,
    win: u32,
    atom: u32,
    atom_type: u32,
    cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 256);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return "";
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) return "";

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    cached_title.clearRetainingCapacity();
    try cached_title.appendSlice(allocator, data[0..len]);
    cached_title_window.* = win;
    return cached_title.items;
}

fn getFocusedWindowTitle(
    wm: *defs.WM,
    cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };

    // Cache hit: same window, non-empty title already stored
    if (cached_title_window.* == win and cached_title.items.len > 0) {
        return cached_title.items;
    }

    // Try _NET_WM_NAME (UTF-8) first, fall back to WM_NAME (Latin-1)
    if (utils.getAtom(wm.conn, "_NET_WM_NAME")) |net_wm_name| {
        const utf8_atom = utils.getAtom(wm.conn, "UTF8_STRING") catch xcb.XCB_ATOM_STRING;
        const title = try fetchProperty(wm.conn, win, net_wm_name, utf8_atom, cached_title, cached_title_window, allocator);
        if (title.len > 0) return title;
    } else |_| {}

    return try fetchProperty(wm.conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, cached_title, cached_title_window, allocator);
}
