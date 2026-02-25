//! Title segment — shows the focused window title, or a split view for multiple windows.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const drawing    = @import("drawing");
const workspaces = @import("workspaces");
const utils      = @import("utils");
const minimize   = @import("minimize");
const tiling     = @import("tiling");

// Iter 3: collect atom state into a single struct with a single lazy-init call.
// Removes two separate nullable module-level vars and the duplicated ensureAtoms() call.
const Atoms = struct {
    net_wm_name: u32 = 0,
    utf8_string:  u32 = 0,
    initialized: bool = false,

    fn ensure(self: *Atoms) void {
        if (self.initialized) return;
        self.initialized = true;
        self.net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch 0;
        self.utf8_string  = utils.getAtomCached("UTF8_STRING")  catch 0;
    }

    /// Invalidates cached atoms (call on bar reload when atom cache is rebuilt).
    fn invalidate(self: *Atoms) void { self.initialized = false; }
};

var atoms: Atoms = .{};

const WindowInfo = struct {
    window:    u32,
    x:         i16,
    y:         i16,
    title:     []const u8,
    minimized: bool,
};

/// Fixed left indent independent of scaledSegmentPadding.
const TITLE_LEAD_PX: u16 = 4;

pub fn draw(
    dc:                   *drawing.DrawContext,
    config:               defs.BarConfig,
    height:               u16,
    start_x:              u16,
    width:                u16,
    wm:                   *defs.WM,
    cached_title:         *std.ArrayList(u8),
    cached_title_window:  *?u32,
    allocator:            std.mem.Allocator,
) !u16 {
    const ws_state     = workspaces.getState() orelse return start_x + width;
    const current_ws   = &ws_state.workspaces[ws_state.current];
    const window_count = current_ws.windows.count();

    if (window_count == 0) {
        dc.fillRect(start_x, 0, width, height, config.bg);
        return start_x + width;
    }

    const scaled_padding = config.scaledSegmentPadding(height);

    if (window_count == 1) {
        const single_win   = current_ws.windows.items()[0];
        const is_minimized = minimize.isMinimized(wm, single_win);
        const is_focused   = wm.focused_window != null;

        const accent = if (is_minimized)
            config.getTitleMinimizedAccent()
        else if (is_focused)
            config.getTitleAccent()
        else
            config.bg;
        dc.fillRect(start_x, 0, width, height, accent);

        if (is_minimized) {
            const title = getWindowTitle(wm.conn, single_win, allocator) catch null;
            defer if (title) |t| allocator.free(t);
            if (title) |t| {
                try dc.drawTextEllipsis(start_x + scaled_padding + TITLE_LEAD_PX, dc.baselineY(height),
                    t, width -| scaled_padding * 2 -| TITLE_LEAD_PX, config.fg);
            }
        } else {
            const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);
            if (title.len > 0) {
                try dc.drawTextEllipsis(start_x + scaled_padding + TITLE_LEAD_PX, dc.baselineY(height),
                    title, width -| scaled_padding * 2 -| TITLE_LEAD_PX,
                    if (is_focused) config.selected_fg else config.fg);
            }
        }
    } else {
        try drawSegmentedTitles(dc, config, height, start_x, width, wm, current_ws, allocator, scaled_padding);
    }

    return start_x + width;
}

fn drawSegmentedTitles(
    dc:             *drawing.DrawContext,
    config:         defs.BarConfig,
    height:         u16,
    start_x:        u16,
    width:          u16,
    wm:             *defs.WM,
    workspace:      anytype,
    allocator:      std.mem.Allocator,
    scaled_padding: u16,
) !void {
    const win_items = workspace.windows.items();
    if (win_items.len == 0) return;

    const MAX_WINS: usize = 128;
    const n_wins = @min(win_items.len, MAX_WINS);

    atoms.ensure();
    const net_atom = atoms.net_wm_name;
    // Iter 2: compute utf_type once rather than inline in two phases.
    const utf_type = if (atoms.utf8_string != 0) atoms.utf8_string else xcb.XCB_ATOM_STRING;

    // Phase 1: fire all _NET_WM_NAME cookies without waiting.
    var net_cookies: [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    if (net_atom != 0) {
        for (win_items[0..n_wins], 0..) |win, i| {
            net_cookies[i] = xcb.xcb_get_property(wm.conn, 0, win, net_atom, utf_type, 0, 8192);
        }
    }

    // Phase 2: collect _NET_WM_NAME replies; queue WM_NAME fallbacks.
    var titles:     [MAX_WINS]?[]const u8                   = @splat(null);
    var fb_cookies: [MAX_WINS]xcb.xcb_get_property_cookie_t = undefined;
    var needs_fb:   [MAX_WINS]bool                          = @splat(false);

    for (win_items[0..n_wins], 0..) |win, i| {
        got: {
            if (net_atom != 0) {
                const r = xcb.xcb_get_property_reply(wm.conn, net_cookies[i], null) orelse break :got;
                defer std.c.free(r);
                const len = xcb.xcb_get_property_value_length(r);
                if (len > 0) {
                    const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
                    titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
                    break :got;
                }
            }
            fb_cookies[i] = xcb.xcb_get_property(
                wm.conn, 0, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 8192);
            needs_fb[i] = true;
        }
    }

    // Phase 3: collect WM_NAME fallback replies.
    for (0..n_wins) |i| {
        if (!needs_fb[i]) continue;
        const r = xcb.xcb_get_property_reply(wm.conn, fb_cookies[i], null) orelse continue;
        defer std.c.free(r);
        const len = xcb.xcb_get_property_value_length(r);
        if (len > 0) {
            const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
            titles[i] = try allocator.dupe(u8, ptr[0..@intCast(len)]);
        }
    }
    defer for (titles[0..n_wins]) |t| if (t) |s| allocator.free(s);

    // Build WindowInfo list on the stack (~4 KB for MAX_WINS=128).
    var infos_buf: [MAX_WINS]WindowInfo = undefined;
    var n_infos: usize = 0;

    for (win_items[0..n_wins], 0..) |win, i| {
        const is_min   = minimize.isMinimized(wm, win);
        const geom: utils.Rect = if (!is_min) blk: {
            if (tiling.getCachedGeom(win)) |rect| break :blk rect;
            break :blk utils.getGeometry(wm.conn, win) orelse continue;
        } else .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };

        infos_buf[n_infos] = .{
            .window    = win,
            .x         = geom.x,
            .y         = geom.y,
            .title     = titles[i] orelse "",
            .minimized = is_min,
        };
        n_infos += 1;
    }

    if (n_infos == 0) return;

    const window_infos = infos_buf[0..n_infos];
    std.mem.sort(WindowInfo, window_infos, {}, compareWindows);

    const num_windows:   u32 = @intCast(window_infos.len);
    const segment_width: u16 = @intCast(@divFloor(@as(u32, width), num_windows));
    if (segment_width == 0) return;

    for (window_infos, 0..) |info, i| {
        const segment_x      = start_x + @as(u16, @intCast(@as(u32, @intCast(i)) * segment_width));
        const is_focused_win = wm.focused_window == info.window;

        const accent = if (is_focused_win)  config.getTitleAccent()
            else if (info.minimized)         config.getTitleMinimizedAccent()
            else                             config.getTitleUnfocusedAccent();

        dc.fillRect(segment_x, 0, segment_width, height, accent);

        if (info.title.len > 0 and segment_width > scaled_padding * 2) {
            try dc.drawTextEllipsis(
                segment_x + scaled_padding + TITLE_LEAD_PX,
                dc.baselineY(height),
                info.title,
                segment_width -| scaled_padding * 2 -| TITLE_LEAD_PX,
                if (is_focused_win) config.selected_fg else config.fg,
            );
        }
    }
}

fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

fn fetchProperty(conn: *xcb.xcb_connection_t, win: u32, atom: u32, atom_type: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, win, atom, atom_type, 0, 8192);
    const reply  = xcb.xcb_get_property_reply(conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    const len = xcb.xcb_get_property_value_length(reply);
    if (len <= 0) return null;
    const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    return try allocator.dupe(u8, value[0..@intCast(len)]);
}

fn getWindowTitle(conn: *xcb.xcb_connection_t, window: u32, allocator: std.mem.Allocator) !?[]const u8 {
    atoms.ensure();
    if (atoms.net_wm_name != 0) {
        const utf_type = if (atoms.utf8_string != 0) atoms.utf8_string else xcb.XCB_ATOM_STRING;
        if (try fetchProperty(conn, window, atoms.net_wm_name, utf_type, allocator)) |t| return t;
    }
    return try fetchProperty(conn, window, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, allocator);
}

fn getFocusedWindowTitle(
    wm:                  *defs.WM,
    cached_title:        *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator:           std.mem.Allocator,
) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };

    if (cached_title_window.* == win and cached_title.items.len > 0) return cached_title.items;

    atoms.ensure();
    const utf_type = if (atoms.utf8_string != 0) atoms.utf8_string else xcb.XCB_ATOM_STRING;

    if (atoms.net_wm_name != 0) {
        const title = try utils.fetchPropertyToBuffer(wm.conn, win, atoms.net_wm_name, utf_type, cached_title, allocator);
        if (title.len > 0) { cached_title_window.* = win; return title; }
    }

    const title = try utils.fetchPropertyToBuffer(wm.conn, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, cached_title, allocator);
    if (title.len > 0) cached_title_window.* = win;
    return title;
}
