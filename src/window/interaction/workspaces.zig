//! Workspace management - FIXED: instant switching

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const bar = @import("bar");
const batch = @import("batch");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    window_set: std.AutoHashMap(u32, void),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = std.ArrayList(u32){},
            .window_set = std.AutoHashMap(u32, void).init(allocator),
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit(self.allocator);
        self.window_set.deinit();
    }

    pub inline fn contains(self: *const Workspace, win: u32) bool {
        return self.window_set.contains(win);
    }

    pub fn add(self: *Workspace, win: u32) !void {
        if (!self.contains(win)) {
            try self.windows.append(self.allocator, win);
            try self.window_set.put(win, {});
        }
    }

    pub fn remove(self: *Workspace, win: u32) bool {
        if (!self.window_set.remove(win)) return false;

        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                _ = self.windows.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: usize,
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,
    wm: *WM,
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[workspaces] Failed to allocate state", .{});
        return;
    };
    s.allocator = wm.allocator;
    s.current = 0;
    s.window_to_workspace = std.AutoHashMap(u32, usize).init(wm.allocator);
    s.wm = wm;

    const count = wm.config.workspaces.count;
    s.workspaces = wm.allocator.alloc(Workspace, count) catch {
        std.log.err("[workspaces] Failed to allocate workspaces", .{});
        wm.allocator.destroy(s);
        return;
    };

    for (s.workspaces, 0..) |*ws, i| {
        const name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?";
        ws.* = Workspace.init(wm.allocator, i, name) catch {
            std.log.err("[workspaces] Failed to init workspace {}", .{i});
            for (s.workspaces[0..i]) |*prev_ws| {
                prev_ws.deinit();
                wm.allocator.free(prev_ws.name);
            }
            wm.allocator.free(s.workspaces);
            wm.allocator.destroy(s);
            return;
        };
    }

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        for (s.workspaces) |*ws| {
            ws.deinit();
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

pub fn addWindowToCurrentWorkspace(_: *WM, win: u32) void {
    const s = state orelse return;
    if (@import("bar").isBarWindow(win)) return;

    const ws = &s.workspaces[s.current];
    ws.add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window {}: {}", .{ win, err });
        return;
    };
    s.window_to_workspace.put(win, s.current) catch {};
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;

    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {}", .{target_ws});
        return;
    }

    const from_ws = s.window_to_workspace.get(win) orelse blk: {
        for (s.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                s.window_to_workspace.put(win, i) catch {};
                break :blk i;
            }
        } else {
            s.workspaces[target_ws].add(win) catch {};
            s.window_to_workspace.put(win, target_ws) catch {};
            return;
        }
    };

    if (from_ws == target_ws) return;

    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch {};
    s.window_to_workspace.put(win, target_ws) catch {};

    if (from_ws == s.current) {
        const screen = wm.screen;
        const off_screen_x: i16 = @intCast(screen.width_in_pixels * 2);

        var b = batch.Batch.begin(wm) catch {
            _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, off_screen_x))});
            utils.flush(wm.conn);
            return;
        };
        defer b.deinit();

        const rect = utils.Rect{
            .x = off_screen_x,
            .y = 0,
            .width = 100,
            .height = 100,
        };
        b.configure(win, rect) catch {};
        b.execute();

        if (wm.focused_window == win) {
            utils.clearFocus(wm);
        }
    } else if (target_ws == s.current) {
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    }
}

// FIXED: Immediately retile after workspace switch, no waiting for debounce
pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    const old_ws = s.current;
    s.current = ws_id;

    var b = batch.Batch.begin(wm) catch {
        switchToSlow(wm, old_ws, ws_id);
        return;
    };
    defer b.deinit();

    const screen = wm.screen;
    const off_screen_x: i16 = @intCast(screen.width_in_pixels * 2);

    // Hide old workspace windows
    for (s.workspaces[old_ws].windows.items) |win| {
        const rect = utils.Rect{
            .x = off_screen_x,
            .y = 0,
            .width = 100,
            .height = 100,
        };
        b.configure(win, rect) catch continue;
    }

    // Set focus
    if (s.workspaces[ws_id].windows.items.len > 0) {
        const win = s.workspaces[ws_id].windows.items[0];
        b.setFocus(win) catch {};
        wm.focused_window = win;
    } else {
        b.setFocus(wm.root) catch {};
        wm.focused_window = null;
    }

    b.execute();

    // FIXED: Immediately retile the new workspace, don't wait for dirty flag
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        tiling_mod.retileCurrentWorkspace(wm);
    }

    @import("bar").markDirty();
}

fn switchToSlow(wm: *WM, old_ws: usize, ws_id: usize) void {
    const s = state orelse return;
    const conn = wm.conn;
    const screen = wm.screen;
    const off_screen_x: i32 = screen.width_in_pixels * 2;

    for (s.workspaces[old_ws].windows.items) |win| {
        _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(off_screen_x)});
    }

    if (s.workspaces[ws_id].windows.items.len > 0) {
        const win = s.workspaces[ws_id].windows.items[0];
        _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        wm.focused_window = win;
    } else {
        _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
        wm.focused_window = null;
    }

    _ = xcb.xcb_flush(conn);

    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        tiling_mod.retileCurrentWorkspace(wm);
    }

    @import("bar").markDirty();
}

pub fn getCurrentWindowsView() ?[]const u32 {
    const s = state orelse return null;
    return s.workspaces[s.current].windows.items;
}

pub fn getCurrentWorkspace() ?usize {
    const s = state orelse return null;
    return s.current;
}

pub fn isOnCurrentWorkspace(win: u32) bool {
    const s = state orelse return false;
    return s.workspaces[s.current].contains(win);
}

pub inline fn getState() ?*State {
    return state;
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = state orelse return null;
    return &s.workspaces[s.current];
}
