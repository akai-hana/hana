//! Core tiling system implementation - Optimized

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const workspaces = @import("workspaces");
const focus = @import("focus");
const atomic = @import("atomic");
const bar = @import("bar");

const master_layout = @import("master");
const monocle_layout = @import("monocle");
const grid_layout = @import("grid");

pub const Layout = enum { master, monocle, grid };

pub const State = struct {
    enabled: bool,
    layout: Layout,
    master_side: defs.MasterSide,
    master_width_factor: f32,
    master_count: usize,
    gaps: u16,
    border_width: u16,
    border_focused: u32,
    border_normal: u32,
    tiled_windows: std.ArrayList(u32),
    tiled_set: std.AutoHashMap(u32, void),
    window_borders: std.AutoHashMap(u32, u32),
    allocator: std.mem.Allocator,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[tiling] Failed to allocate state", .{});
        return;
    };

    s.* = .{
        .enabled = wm.config.tiling.enabled,
        .layout = parseLayout(wm.config.tiling.layout),
        .master_side = wm.config.tiling.master_side,
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count = wm.config.tiling.master_count,
        .gaps = wm.config.tiling.gaps,
        .border_width = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal = wm.config.tiling.border_normal,
        .tiled_windows = std.ArrayList(u32){},
        .tiled_set = std.AutoHashMap(u32, void).init(wm.allocator),
        .window_borders = std.AutoHashMap(u32, u32).init(wm.allocator),
        .allocator = wm.allocator,
    };

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        s.tiled_windows.deinit(s.allocator);
        s.tiled_set.deinit();
        s.window_borders.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

fn parseLayout(name: []const u8) Layout {
    const map = std.StaticStringMap(Layout).initComptime(.{
        .{ "master", .master },
        .{ "monocle", .monocle },
        .{ "grid", .grid },
    });
    return map.get(name) orelse .master;
}

pub fn notifyWindowMapped(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled or !workspaces.isOnCurrentWorkspace(win)) return;

    if (wm.fullscreen_window == win) {
        retileCurrentWorkspace(wm);
        return;
    }

    if (s.tiled_set.contains(win)) {
        retileCurrentWorkspace(wm);
        return;
    }

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add tiled window: {}", .{err});
        return;
    };
    s.tiled_set.put(win, {}) catch |err| {
        std.log.err("[tiling] Failed to add to tiled set: {}", .{err});
        _ = s.tiled_windows.orderedRemove(0);
        return;
    };

    utils.configureBorder(wm.conn, win, s.border_width, s.border_focused);
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, 
        &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});

    wm.focused_window = win;
    s.window_borders.put(win, s.border_focused) catch {};
    
    retileCurrentWorkspace(wm);
}

pub fn addWindowToTiling(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled or s.tiled_set.contains(win)) return;

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add window to tiling: {}", .{err});
        return;
    };
    s.tiled_set.put(win, {}) catch |err| {
        std.log.err("[tiling] Failed to add to tiled set: {}", .{err});
        _ = s.tiled_windows.orderedRemove(0);
        return;
    };

    const is_focused = wm.focused_window == win;
    const border_color = if (is_focused) s.border_focused else s.border_normal;
    
    utils.configureBorder(wm.conn, win, s.border_width, border_color);
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK,
        &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});

    s.window_borders.put(win, border_color) catch {};
}

pub fn notifyWindowDestroyed(wm: *WM, win: u32) void {
    const s = state orelse return;

    _ = s.window_borders.remove(win);
    _ = s.tiled_set.remove(win);

    for (s.tiled_windows.items, 0..) |w, i| {
        if (w == win) {
            _ = s.tiled_windows.orderedRemove(i);

            if (s.tiled_windows.items.len > 0 and wm.focused_window == win) {
                const next = s.tiled_windows.items[0];
                _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, next, xcb.XCB_CURRENT_TIME);
                wm.focused_window = next;
            }
            retileCurrentWorkspace(wm);
            return;
        }
    }
}

pub fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    if (old_focused) |old_win| {
        if (s.tiled_set.contains(old_win) and wm.fullscreen_window != old_win) {
            utils.setBorder(wm.conn, old_win, s.border_normal);
            s.window_borders.put(old_win, s.border_normal) catch {};
        }
    }

    if (new_focused) |new_win| {
        if (s.tiled_set.contains(new_win) and wm.fullscreen_window != new_win) {
            utils.setBorder(wm.conn, new_win, s.border_focused);
            s.window_borders.put(new_win, s.border_focused) catch {};
        }
    }
}

pub inline fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateWindowFocusFast(wm, old_focused, new_focused);
}

pub inline fn isWindowTiled(win: u32) bool {
    const s = state orelse return false;
    return s.enabled and s.tiled_set.contains(win);
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    const s = state orelse return;
    if (!s.enabled) return;

    var tx = atomic.Transaction.begin(wm) catch |err| {
        std.log.err("[tiling] Failed to begin retile transaction: {}", .{err});
        return;
    };
    defer tx.deinit();

    const ws_windows = workspaces.getCurrentWindowsView() orelse return;

    // Build visible windows list
    var visible = std.ArrayList(u32){};
    defer visible.deinit(s.allocator);
    visible.ensureTotalCapacity(s.allocator, s.tiled_windows.items.len) catch {};

    for (s.tiled_windows.items) |win| {
        if (wm.fullscreen_window == win) continue;
        
        for (ws_windows) |ws_win| {
            if (ws_win == win) {
                visible.append(s.allocator, win) catch continue;
                break;
            }
        }
    }

    if (visible.items.len == 0) {
        tx.commit() catch {};
        return;
    }

    const screen = wm.screen;

    // Apply layout
    switch (s.layout) {
        .master => master_layout.tile(&tx, s, visible.items, screen.width_in_pixels, screen.height_in_pixels),
        .monocle => monocle_layout.tile(&tx, s, visible.items, screen.width_in_pixels, screen.height_in_pixels),
        .grid => grid_layout.tile(&tx, s, visible.items, screen.width_in_pixels, screen.height_in_pixels),
    }

    // Set borders and save positions
    const focused = wm.focused_window;
    const ws = workspaces.getCurrentWorkspaceObject();

    for (visible.items) |win| {
        const color = if (focused != null and win == focused.?) s.border_focused else s.border_normal;

        tx.setBorder(win, color) catch |err| {
            std.log.err("[tiling] Failed to set border for window {}: {}", .{ win, err });
            continue;
        };

        s.window_borders.put(win, color) catch {};

        if (ws) |workspace| {
            if (tx.getConfiguredRect(win)) |rect| {
                workspace.saveWindowState(win, rect, color) catch {};
            }
        }
    }

    tx.commit() catch |err| {
        std.log.err("[tiling] Retile transaction failed: {}", .{err});
        tx.rollback() catch {};
    };
}

pub fn restoreWindowPositions(wm: *WM) bool {
    const s = state orelse return false;
    if (!s.enabled) return false;

    const ws = workspaces.getCurrentWorkspaceObject() orelse return false;
    const ws_windows = workspaces.getCurrentWindowsView() orelse return false;

    var tiled_count: usize = 0;
    var restored_count: usize = 0;

    for (ws_windows) |win| {
        if (wm.fullscreen_window == win) continue;
        if (!isWindowTiled(win)) continue;

        tiled_count += 1;

        if (ws.getWindowPosition(win)) |rect| {
            utils.configureWindow(wm.conn, win, rect);
            restored_count += 1;

            if (ws.getWindowBorder(win)) |border_color| {
                utils.setBorder(wm.conn, win, border_color);
                s.window_borders.put(win, border_color) catch {};
            }
        }
    }

    if (tiled_count > 0 and restored_count == tiled_count) {
        utils.flush(wm.conn);
        return true;
    }

    return false;
}

pub fn toggleLayout(wm: *WM) void {
    const s = state orelse return;
    s.layout = switch (s.layout) {
        .master => .monocle,
        .monocle => .grid,
        .grid => .master,
    };

    workspaces.clearAllPositions();
    retileCurrentWorkspace(wm);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @min(defs.MAX_MASTER_WIDTH, s.master_width_factor + 0.05);
    workspaces.clearAllPositions();
    retileCurrentWorkspace(wm);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @max(defs.MIN_MASTER_WIDTH, s.master_width_factor - 0.05);
    workspaces.clearAllPositions();
    retileCurrentWorkspace(wm);
}

pub fn increaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @min(s.tiled_windows.items.len, s.master_count + 1);
    workspaces.clearAllPositions();
    retileCurrentWorkspace(wm);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @max(1, s.master_count -| 1);
    workspaces.clearAllPositions();
    retileCurrentWorkspace(wm);
}

pub fn toggleTiling(wm: *WM) void {
    const s = state orelse return;
    s.enabled = !s.enabled;
    if (s.enabled) {
        retileCurrentWorkspace(wm);
    }
}

pub fn reloadConfig(wm: *WM) void {
    const s = state orelse return;

    s.enabled = wm.config.tiling.enabled;
    s.layout = parseLayout(wm.config.tiling.layout);
    s.master_side = wm.config.tiling.master_side;
    s.master_width_factor = wm.config.tiling.master_width_factor;
    s.master_count = wm.config.tiling.master_count;
    s.gaps = wm.config.tiling.gaps;
    s.border_width = wm.config.tiling.border_width;
    s.border_focused = wm.config.tiling.border_focused;
    s.border_normal = wm.config.tiling.border_normal;

    s.window_borders.clearRetainingCapacity();
    workspaces.clearAllPositions();

    if (s.enabled) retileCurrentWorkspace(wm);
}

pub inline fn getState() ?*State {
    return state;
}
