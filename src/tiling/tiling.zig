// Tiling window management — delegates to layout modules.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const focus      = @import("focus");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const Tracking   = @import("tracking").Tracking;
const debug      = @import("debug");
const dpi        = @import("dpi");

const master_layout    = @import("master");
const monocle_layout   = @import("monocle");
const grid_layout      = @import("grid");
const fibonacci_layout = @import("fibonacci");

const MAX_MASTER_WIDTH: f32 = 0.95;
const WINDOW_EVENT_MASK     = constants.EventMasks.MANAGED_WINDOW;
// Stack-local buffer size for per-retile workspace window list.
const MAX_WS_WINDOWS: usize = 128;

pub const Layout = enum { master, monocle, grid, fibonacci };

// ─── Focus ring ───────────────────────────────────────────────────────────────
// Fixed-capacity circular buffer of recently-focused window IDs.
// Newest entry is always at buffer[head].

const RING_CAP = 16;

const FocusRing = struct {
    buffer: [RING_CAP]u32 = [_]u32{0} ** RING_CAP,
    head:   u8            = 0,
    len:    u8            = 0,

    pub fn push(self: *FocusRing, win: u32) void {
        if (self.len > 0 and self.buffer[self.head] == win) return;

        // Remove any existing occurrence so the ring has no duplicates.
        var i: u8 = 1;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % RING_CAP;
            if (self.buffer[idx] == win) {
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    const cur  = (self.head + j)     % RING_CAP;
                    const next = (self.head + j + 1) % RING_CAP;
                    self.buffer[cur] = self.buffer[next];
                }
                self.len -= 1;
                break;
            }
        }

        self.head = if (self.head == 0) RING_CAP - 1 else self.head - 1;
        self.buffer[self.head] = win;
        if (self.len < RING_CAP) self.len += 1;
    }

    pub fn remove(self: *FocusRing, win: u32) void {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % RING_CAP;
            if (self.buffer[idx] != win) continue;
            var j = i;
            while (j + 1 < self.len) : (j += 1) {
                const cur  = (self.head + j)     % RING_CAP;
                const next = (self.head + j + 1) % RING_CAP;
                self.buffer[cur] = self.buffer[next];
            }
            self.len -= 1;
            return;
        }
    }

    pub fn iter(self: *const FocusRing) Iterator {
        return .{ .ring = &self.buffer, .head = self.head, .len = self.len, .pos = 0 };
    }

    const Iterator = struct {
        ring: *const [RING_CAP]u32,
        head: u8, len: u8, pos: u8,

        pub fn next(self: *Iterator) ?u32 {
            if (self.pos >= self.len) return null;
            const idx = (self.head + self.pos) % RING_CAP;
            self.pos += 1;
            return self.ring[idx];
        }
    };
};

// ─── State ────────────────────────────────────────────────────────────────────

pub const State = struct {
    enabled:          bool,
    layout:           Layout,
    master_side:      defs.MasterSide,
    master_width:     f32,
    master_count:     u8,
    gaps:             u16,
    border_width:     u16,
    border_focused:   u32,
    border_unfocused: u32,
    windows:          Tracking,
    dirty:            bool,
    geometry_cache:   std.AutoHashMap(u32, utils.Rect),
    focus_ring:       FocusRing,
    allocator:        std.mem.Allocator,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, wm: *const WM, win: u32) u32 {
        if (!self.windows.contains(win)) return self.border_unfocused;
        if (wm.fullscreen.isFullscreen(win)) return 0;
        return if (wm.focused_window == win) self.border_focused else self.border_unfocused;
    }

    pub inline fn markDirty(self: *State)     void { self.dirty = true;  }
    pub inline fn isDirty(self: *const State) bool { return self.dirty;  }
    pub inline fn clearDirty(self: *State)    void { self.dirty = false; }

    pub fn getGeometry(self: *State, conn: *xcb.xcb_connection_t, win: u32) ?utils.Rect {
        if (self.geometry_cache.get(win)) |rect| return rect;
        if (utils.getGeometry(conn, win)) |rect| {
            self.geometry_cache.put(win, rect) catch {};
            return rect;
        }
        return null;
    }

    pub inline fn invalidateGeometry(self: *State, win: u32) void {
        _ = self.geometry_cache.remove(win);
    }

    pub inline fn clearGeometryCache(self: *State) void {
        self.geometry_cache.clearRetainingCapacity();
    }

    pub fn deinit(self: *State) void {
        self.windows.deinit();
        self.geometry_cache.deinit();
    }
};

// ─── Module singleton ─────────────────────────────────────────────────────────

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state != null) &g_state.? else null; }

// ─── Config ───────────────────────────────────────────────────────────────────

/// Build a complete State from the current WM configuration.
fn buildState(wm: *WM) State {
    const screen_height = wm.screen.height_in_pixels;
    const border_width  = dpi.scaleBorderWidth(wm.config.tiling.border_width, wm.dpi_info.scale_factor, screen_height);
    const gaps          = dpi.scaleGaps(wm.config.tiling.gaps, wm.dpi_info.scale_factor, screen_height);

    const raw_mw = dpi.scaleMasterWidth(wm.config.tiling.master_width);
    const master_width: f32 = if (raw_mw < 0) blk: {
        const ratio = -raw_mw / @as(f32, @floatFromInt(wm.screen.width_in_pixels));
        break :blk @min(MAX_MASTER_WIDTH, @max(defs.MIN_MASTER_WIDTH, ratio));
    } else raw_mw;

    return .{
        .enabled          = wm.config.tiling.enabled,
        .layout           = std.meta.stringToEnum(Layout, wm.config.tiling.layout) orelse .master,
        .master_side      = wm.config.tiling.master_side,
        .master_width     = master_width,
        .master_count     = wm.config.tiling.master_count,
        .gaps             = gaps,
        .border_width     = border_width,
        .border_focused   = wm.config.tiling.border_focused,
        .border_unfocused = wm.config.tiling.border_unfocused,
        .windows          = Tracking.init(wm.allocator),
        .dirty            = false,
        .geometry_cache   = std.AutoHashMap(u32, utils.Rect).init(wm.allocator),
        .focus_ring       = .{},
        .allocator        = wm.allocator,
    };
}

pub fn init(wm: *WM) void {
    g_state = buildState(wm);
}

pub fn deinit(_: *WM) void {
    if (g_state) |*s| s.deinit();
    g_state = null;
}

pub fn reloadConfig(wm: *WM) void {
    const s = getState() orelse return;
    // Preserve runtime tracking; rebuild everything else from config.
    const saved_windows    = s.windows;
    const saved_focus_ring = s.focus_ring;
    const saved_geo_cache  = s.geometry_cache;
    g_state = buildState(wm);
    g_state.?.windows        = saved_windows;
    g_state.?.focus_ring     = saved_focus_ring;
    g_state.?.geometry_cache = saved_geo_cache;
    if (g_state.?.enabled) retileCurrentWorkspace(wm, true);
}

// ─── Window management ────────────────────────────────────────────────────────

pub fn addWindow(wm: *WM, window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState() orelse return;
    if (!s.enabled) return;

    s.windows.add(window_id) catch |err| { debug.logError(err, window_id); return; };
    s.markDirty();
    s.invalidateGeometry(window_id);

    const border_color = s.borderColor(wm, window_id);
    _ = xcb.xcb_change_window_attributes(wm.conn, window_id,
        xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_BORDER_PIXEL,
        &[_]u32{ WINDOW_EVENT_MASK, border_color });
    _ = xcb.xcb_configure_window(wm.conn, window_id,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{s.border_width});
    debug.info("Added window 0x{x} to tiling", .{window_id});
}

pub fn removeWindow(window_id: u32) void {
    const s = getState() orelse return;
    if (s.windows.remove(window_id)) {
        s.markDirty();
        s.invalidateGeometry(window_id);
        s.focus_ring.remove(window_id);
        debug.info("Removed window 0x{x} from tiling", .{window_id});
    }
}

pub inline fn isWindowTiled(window_id: u32) bool {
    const s = getState() orelse return false;
    return s.windows.contains(window_id);
}

// ─── Screen area ──────────────────────────────────────────────────────────────

fn calculateScreenArea(wm: *WM) utils.Rect {
    const bar_height: u16 = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bar_at_bottom   = wm.config.bar.vertical_position == .bottom;
    return .{
        .x      = 0,
        .y      = if (bar_at_bottom) 0 else @intCast(bar_height),
        .width  = wm.screen.width_in_pixels,
        .height = wm.screen.height_in_pixels - bar_height,
    };
}

// ─── Retiling ─────────────────────────────────────────────────────────────────

pub fn retileIfDirty(wm: *WM) void {
    const s = getState() orelse return;
    if (!s.enabled or !s.dirty) return;
    retile(wm, calculateScreenArea(wm));
    s.clearDirty();
}

pub fn retileCurrentWorkspace(wm: *WM, force: bool) void {
    const s = getState() orelse return;
    if (!s.enabled) return;
    if (force) { s.markDirty(); s.clearGeometryCache(); }
    retile(wm, calculateScreenArea(wm));
    s.clearDirty();
}

fn retile(wm: *WM, screen: utils.Rect) void {
    const s = getState() orelse return;

    const current_ws = workspaces.getCurrentWorkspace() orelse return;
    if (wm.fullscreen.getForWorkspace(current_ws)) |_| return;

    // Collect windows for the current workspace into a stack-local buffer.
    var ws_buf: [MAX_WS_WINDOWS]u32 = undefined;
    var ws_count: usize = 0;
    for (s.windows.items()) |win| {
        if (ws_count >= MAX_WS_WINDOWS) break;
        if (workspaces.isOnCurrentWorkspace(win)) {
            ws_buf[ws_count] = win;
            ws_count += 1;
        }
    }
    const ws_windows = ws_buf[0..ws_count];
    if (ws_windows.len == 0) return;

    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(screen.y);
    switch (s.layout) {
        .master    => master_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .monocle   => monocle_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .grid      => grid_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .fibonacci => fibonacci_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
    }
    updateBorders(wm, ws_windows);
}

fn updateBorders(wm: *WM, ws_windows: []const u32) void {
    const s = getState() orelse return;
    for (ws_windows) |win| {
        const color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &color);
    }
}

// ─── Focus border updates ─────────────────────────────────────────────────────

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateBorderForFocusChange(wm, old_focused, new_focused);
    _ = xcb.xcb_flush(wm.conn);
}

pub fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateBorderForFocusChange(wm, old_focused, new_focused);
}

inline fn updateBorderForFocusChange(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = getState() orelse return;
    if (old_focused) |win| if (s.windows.contains(win)) {
        const color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &color);
    };
    if (new_focused) |win| if (s.windows.contains(win)) {
        const color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &color);
    };
}

// ─── Window reordering ────────────────────────────────────────────────────────

/// Move the window at `from_idx` to `to_idx` in tiling order.
fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    const current = s.windows.items();
    if (current.len == 0) return;

    var temp: [256]u32 = undefined;
    if (current.len > temp.len) {
        debug.warn("moveWindowToIndex: too many windows ({})", .{current.len});
        return;
    }

    const win = current[from_idx];
    var j: usize = 0;
    for (current, 0..) |w, i| {
        if (i == from_idx) continue;
        if (j == to_idx) { temp[j] = win; j += 1; }
        temp[j] = w;
        j += 1;
    }
    if (to_idx >= j) { temp[j] = win; j += 1; }
    s.windows.reorder(temp[0..j]);
}

pub fn swapWithMaster(wm: *WM) void {
    const s = getState() orelse return;
    const focused = wm.focused_window orelse return;
    if (!s.windows.contains(focused) or !workspaces.isOnCurrentWorkspace(focused)) return;

    const all = s.windows.items();
    if (all.len < 2) return;

    const focused_pos = findWindowIndex(all, focused) orelse return;

    // Find first window on current workspace — that's the effective master.
    var master_pos: usize = 0;
    var found_master = false;
    for (all, 0..) |win, i| {
        if (workspaces.isOnCurrentWorkspace(win)) { master_pos = i; found_master = true; break; }
    }
    if (!found_master) return;

    if (focused_pos == master_pos) {
        // Already master: swap with the next workspace window.
        for (all, 0..) |win, i| {
            if (i == master_pos or !workspaces.isOnCurrentWorkspace(win)) continue;
            moveWindowToIndex(s, i, master_pos);
            break;
        }
    } else {
        moveWindowToIndex(s, focused_pos, master_pos);
    }
    s.markDirty();
    retileCurrentWorkspace(wm, true);
}

pub fn promoteToMaster(wm: *WM) void {
    const s = getState() orelse return;
    const focused = wm.focused_window orelse return;
    if (!s.windows.contains(focused)) return;
    const idx = findWindowIndex(s.windows.items(), focused) orelse return;
    if (idx == 0) return;
    moveWindowToIndex(s, idx, 0);
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub fn moveToIndex(from_idx: usize) void {
    const s = getState() orelse return;
    moveWindowToIndex(s, from_idx, 0);
}

// ─── Layout and master controls ───────────────────────────────────────────────

pub fn toggleTiling(wm: *WM) void {
    const s = getState() orelse return;
    s.enabled = !s.enabled;
    if (s.enabled) retileCurrentWorkspace(wm, true);
    debug.info("Tiling {s}", .{if (s.enabled) "enabled" else "disabled"});
}

pub fn toggleLayout(wm: *WM) void {
    const s = getState() orelse return;
    s.layout = switch (s.layout) {
        .master    => .monocle,
        .monocle   => .grid,
        .grid      => .fibonacci,
        .fibonacci => .master,
    };
    s.markDirty();
    retileCurrentWorkspace(wm, false);
    debug.info("Layout: {s}", .{@tagName(s.layout)});
}

pub fn toggleLayoutReverse(wm: *WM) void {
    const s = getState() orelse return;
    s.layout = switch (s.layout) {
        .master    => .fibonacci,
        .fibonacci => .grid,
        .grid      => .monocle,
        .monocle   => .master,
    };
    s.markDirty();
    retileCurrentWorkspace(wm, false);
    debug.info("Layout (reverse): {s}", .{@tagName(s.layout)});
}

pub fn adjustMasterCount(wm: *WM, delta: i8) void {
    const s = getState() orelse return;
    const new: i16 = @as(i16, s.master_count) + delta;
    if (new < 0) return;
    s.master_count = @intCast(@min(new, 10));
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub inline fn increaseMasterCount(wm: *WM) void { adjustMasterCount(wm,  1); }
pub inline fn decreaseMasterCount(wm: *WM) void { adjustMasterCount(wm, -1); }

pub fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = getState() orelse return;
    s.master_width = @max(defs.MIN_MASTER_WIDTH, @min(MAX_MASTER_WIDTH, s.master_width + delta));
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub inline fn increaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm,  0.05); }
pub inline fn decreaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, -0.05); }

// ─── Focus cycling ────────────────────────────────────────────────────────────

inline fn switchFocus(wm: *WM, s: *State, from: ?u32, to: u32) void {
    std.debug.assert(to != 0 and wm.hasWindow(to));
    focus.setFocus(wm, to, .tiling_operation);
    wm.focused_window = to;
    s.focus_ring.push(to);
    updateWindowFocus(wm, from, to);
}

fn filterWorkspaceWindows(s: *State, buf: []u32) usize {
    var n: usize = 0;
    for (s.windows.items()) |win| {
        if (n >= buf.len) break;
        if (workspaces.isOnCurrentWorkspace(win)) { buf[n] = win; n += 1; }
    }
    return n;
}

inline fn getMasterCount(s: *const State, window_count: usize) u8 {
    return @min(s.master_count, @as(u8, @intCast(window_count)));
}

inline fn findWindowIndex(windows: []const u32, target: u32) ?usize {
    return std.mem.indexOfScalar(u32, windows, target);
}

/// Focus the most-recently-focused other window (alt+tab).
pub fn focusPrevious(wm: *WM) void {
    const s   = getState() orelse return;
    const cur = wm.focused_window orelse return;

    var it = s.focus_ring.iter();
    while (it.next()) |win| {
        if (win == cur) continue;
        if (workspaces.isOnCurrentWorkspace(win) and s.windows.contains(win)) {
            switchFocus(wm, s, cur, win);
            return;
        }
    }

    // Fallback: nothing useful in history — find a neighbour in tiling order.
    const all = s.windows.items();
    if (all.len < 2) return;
    const idx = findWindowIndex(all, cur) orelse return;
    const mc  = getMasterCount(s, all.len);
    if (idx < mc and all.len > mc) {
        switchFocus(wm, s, cur, all[mc]);
    } else if (idx >= mc) {
        switchFocus(wm, s, cur, all[if (idx + 1 < all.len) idx + 1 else 0]);
    }
}

/// Focus the second-most-recently-focused window (shift+alt+tab).
pub fn focusSecondLast(wm: *WM) void {
    const s   = getState() orelse return;
    const cur = wm.focused_window;
    if (s.windows.count() < 2) return;

    var found = false;
    var it = s.focus_ring.iter();
    while (it.next()) |win| {
        if (win == cur.?) { found = true; continue; }
        if (found and workspaces.isOnCurrentWorkspace(win) and s.windows.contains(win)) {
            switchFocus(wm, s, cur, win);
            return;
        }
    }

    // Fallback: carousel within workspace windows.
    var buf: [64]u32 = undefined;
    const ws_count = filterWorkspaceWindows(s, &buf);
    if (ws_count < 2) return;
    const ws_wins = buf[0..ws_count];

    if (ws_count == 2) {
        const other = if (ws_wins[0] == cur.?) ws_wins[1] else ws_wins[0];
        switchFocus(wm, s, cur, other);
        return;
    }

    const mc  = getMasterCount(s, ws_count);
    const idx = if (cur) |c| findWindowIndex(ws_wins, c) orelse 0 else 0;

    if (idx < mc) {
        const next = if (mc == 1) ws_count - 1 else (if (idx + 1 < mc) idx + 1 else 0);
        switchFocus(wm, s, cur, ws_wins[next]);
    } else {
        const slave_count = ws_count - mc;
        const si          = idx - mc;
        const next_si     = if (si + 1 < slave_count) si + 1 else 0;
        switchFocus(wm, s, cur, ws_wins[mc + next_si]);
    }
}

pub inline fn invalidateWindowGeometry(win: u32) void {
    const s = getState() orelse return;
    s.invalidateGeometry(win);
}
