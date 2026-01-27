//! Atomic operation wrapper for window manager state changes
//! Provides transaction-based grouping of XCB and state operations for atomicity.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const common = @import("common");

const XcbOp = union(enum) {
    map: u32,
    unmap: u32,
    configure: struct { win: u32, rect: utils.Rect },
    set_border: struct { win: u32, color: u32 },
    set_focus: u32,
    raise: u32,
};

const StateOp = union(enum) {
    add_window: struct { ws: usize, win: u32 },
    remove_window: struct { ws: usize, win: u32 },
    add_tiled: u32,
    remove_tiled: u32,
    set_focused: ?u32,
};

pub const Transaction = struct {
    wm: *WM,
    xcb_ops: std.ArrayListUnmanaged(XcbOp) = .{},
    state_ops: std.ArrayListUnmanaged(StateOp) = .{},
    configured_rects: std.AutoHashMap(u32, utils.Rect),
    committed: bool = false,
    allocator: std.mem.Allocator,

    pub fn begin(wm: *WM) !Transaction {
        var tx = Transaction{
            .wm = wm,
            .xcb_ops = .{},
            .state_ops = .{},
            .configured_rects = std.AutoHashMap(u32, utils.Rect).init(wm.allocator),
            .committed = false,
            .allocator = wm.allocator,
        };

        try tx.xcb_ops.ensureTotalCapacity(wm.allocator, 32);
        try tx.state_ops.ensureTotalCapacity(wm.allocator, 16);
        try tx.configured_rects.ensureTotalCapacity(16);

        return tx;
    }

    pub fn deinit(self: *Transaction) void {
        self.xcb_ops.deinit(self.allocator);
        self.state_ops.deinit(self.allocator);
        self.configured_rects.deinit();
    }

    pub fn mapWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .map = win });
    }

    pub fn unmapWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .unmap = win });
    }

    pub fn configureWindow(self: *Transaction, win: u32, rect: utils.Rect) !void {
        try self.configured_rects.put(win, rect);
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .configure = .{ .win = win, .rect = rect } });
    }

    pub fn setBorder(self: *Transaction, win: u32, color: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .set_border = .{ .win = win, .color = color } });
    }

    pub fn setFocus(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .set_focus = win });
    }

    pub fn raiseWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .raise = win });
    }

    pub fn addWindowToWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .add_window = .{ .ws = ws, .win = win } });
    }

    pub fn removeWindowFromWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .remove_window = .{ .ws = ws, .win = win } });
    }

    pub fn addTiledWindow(self: *Transaction, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .add_tiled = win });
    }

    pub fn removeTiledWindow(self: *Transaction, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .remove_tiled = win });
    }

    pub fn updateFocus(self: *Transaction, win: ?u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .set_focused = win });
    }

    pub inline fn getConfiguredRect(self: *const Transaction, win: u32) ?utils.Rect {
        return self.configured_rects.get(win);
    }

    pub fn commit(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;

        // Execute XCB operations
        for (self.xcb_ops.items) |op| {
            switch (op) {
                .map => |win| _ = xcb.xcb_map_window(self.wm.conn, win),
                .unmap => |win| _ = xcb.xcb_unmap_window(self.wm.conn, win),
                .configure => |cfg| utils.configureWindow(self.wm.conn, cfg.win, cfg.rect),
                .set_border => |sb| common.setBorder(self.wm.conn, sb.win, sb.color),
                .set_focus => |win| _ = xcb.xcb_set_input_focus(
                    self.wm.conn,
                    xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                    win,
                    xcb.XCB_CURRENT_TIME,
                ),
                .raise => |win| _ = xcb.xcb_configure_window(
                    self.wm.conn,
                    win,
                    xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                    &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
                ),
            }
        }

        // Execute state operations
        for (self.state_ops.items) |op| {
            switch (op) {
                .add_window => |aw| {
                    const workspaces = @import("workspaces");
                    if (workspaces.getState()) |ws_state| {
                        if (aw.ws < ws_state.workspaces.len) {
                            ws_state.workspaces[aw.ws].add(aw.win) catch |err| {
                                std.log.err("[atomic] Failed to add window to workspace: {}", .{err});
                            };
                        }
                    }
                },
                .remove_window => |rw| {
                    const workspaces = @import("workspaces");
                    if (workspaces.getState()) |ws_state| {
                        if (rw.ws < ws_state.workspaces.len) {
                            _ = ws_state.workspaces[rw.ws].remove(rw.win);
                        }
                    }
                },
                .add_tiled => |win| {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        if (!t_state.tiled_set.contains(win)) {
                            t_state.tiled_windows.insert(t_state.allocator, 0, win) catch |err| {
                                std.log.err("[atomic] Failed to add tiled window: {}", .{err});
                                continue;
                            };
                            t_state.tiled_set.put(win, {}) catch |err| {
                                std.log.err("[atomic] Failed to add to tiled set: {}", .{err});
                                _ = t_state.tiled_windows.orderedRemove(0);
                            };
                        }
                    }
                },
                .remove_tiled => |win| {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        _ = t_state.tiled_set.remove(win);
                        for (t_state.tiled_windows.items, 0..) |w, i| {
                            if (w == win) {
                                _ = t_state.tiled_windows.orderedRemove(i);
                                break;
                            }
                        }
                    }
                },
                .set_focused => |win| {
                    self.wm.focused_window = win;
                },
            }
        }

        common.flush(self.wm.conn);
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;
        
        self.xcb_ops.clearRetainingCapacity();
        self.state_ops.clearRetainingCapacity();
        
        std.log.info("[atomic] Transaction rolled back", .{});
    }
};

pub fn atomicMapWindow(wm: *WM, win: u32, workspace: usize) !void {
    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    try tx.addWindowToWorkspace(workspace, win);
    try tx.mapWindow(win);

    if (wm.config.tiling.enabled) {
        try tx.addTiledWindow(win);
    }

    try tx.commit();
}

pub fn atomicDestroyWindow(wm: *WM, win: u32) !void {
    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const was_focused = wm.focused_window == win;

    try tx.removeTiledWindow(win);

    const workspaces = @import("workspaces");
    if (workspaces.getState()) |ws_state| {
        if (ws_state.window_to_workspace.get(win)) |ws_idx| {
            try tx.removeWindowFromWorkspace(ws_idx, win);
        }
    }

    if (was_focused) {
        try tx.updateFocus(null);
        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                try tx.setFocus(ws_windows[0]);
                try tx.updateFocus(ws_windows[0]);
            }
        }
    }

    try tx.commit();
}

pub fn atomicMoveWindow(wm: *WM, win: u32, from_ws: usize, to_ws: usize) !void {
    if (from_ws == to_ws) return;

    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const is_focused = wm.focused_window == win;

    try tx.removeWindowFromWorkspace(from_ws, win);
    try tx.addWindowToWorkspace(to_ws, win);

    const workspaces = @import("workspaces");
    if (workspaces.getCurrentWorkspace()) |current| {
        if (from_ws == current and to_ws != current) {
            try tx.unmapWindow(win);

            if (is_focused) {
                try tx.updateFocus(null);
                if (workspaces.getCurrentWindowsView()) |ws_windows| {
                    if (ws_windows.len > 0) {
                        try tx.setFocus(ws_windows[0]);
                        try tx.updateFocus(ws_windows[0]);
                    }
                }
            }
        } else if (from_ws != current and to_ws == current) {
            try tx.mapWindow(win);

            if (wm.config.tiling.enabled) {
                try tx.setFocus(win);
                try tx.updateFocus(win);
            }
        }
    }

    try tx.commit();
}

pub fn atomicSwitchWorkspace(wm: *WM, from: usize, to: usize) !void {
    if (from == to) return;

    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const workspaces = @import("workspaces");

    if (workspaces.getState()) |ws_state| {
        // Unmap old workspace windows first
        for (ws_state.workspaces[from].windows.items) |win| {
            try tx.unmapWindow(win);
        }

        // Map new workspace windows
        for (ws_state.workspaces[to].windows.items) |win| {
            try tx.mapWindow(win);
        }

        if (wm.fullscreen_window) |fs_win| {
            const fs_on_from = for (ws_state.workspaces[from].windows.items) |win| {
                if (win == fs_win) break true;
            } else false;

            const fs_on_to = for (ws_state.workspaces[to].windows.items) |win| {
                if (win == fs_win) break true;
            } else false;

            if (fs_on_from and !fs_on_to) {
                try tx.unmapWindow(fs_win);
            }

            if (fs_on_to and !fs_on_from) {
                try tx.mapWindow(fs_win);
                try tx.raiseWindow(fs_win);
            }
        }

        if (ws_state.workspaces[to].windows.items.len > 0) {
            const win = ws_state.workspaces[to].windows.items[0];
            try tx.setFocus(win);
            try tx.updateFocus(win);
        } else {
            try tx.updateFocus(null);
        }
    }

    try tx.commit();
}
