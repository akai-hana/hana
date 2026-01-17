//! Virtual desktop workspace management.
//!
//! Provides multiple independent workspaces (virtual desktops) where windows
//! can be organized. Each workspace maintains its own window list, and only
//! windows on the current workspace are visible.
//!
//! Features:
//! - Configurable number of workspaces (default: 9)
//! - Switch between workspaces
//! - Move windows between workspaces
//! - Windows persist when switching workspaces

const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const log = @import("logging");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;

/// A single workspace containing windows
pub const Workspace = struct {
    /// Workspace index (0-based)
    id: usize,

    /// Windows currently on this workspace
    windows: std.ArrayList(u32),

    /// Human-readable name
    name: []const u8,
};

/// Global workspace state
pub const WorkspaceState = struct {
    /// All available workspaces
    workspaces: []Workspace,

    /// Index of currently visible workspace
    current: usize,

    allocator: std.mem.Allocator,
};

var workspace_state: ?*WorkspaceState = null;

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(WorkspaceState) catch {
        std.log.err("Failed to allocate workspace state", .{});
        return;
    };

    state.allocator = wm.allocator;
    state.current = 0;

    // Initialize workspaces based on config
    const ws_count = wm.config.workspaces.count;
    state.workspaces = wm.allocator.alloc(Workspace, ws_count) catch {
        std.log.err("Failed to allocate workspaces", .{});
        wm.allocator.destroy(state);
        return;
    };

    for (state.workspaces, 0..) |*ws, i| {
        ws.* = .{
            .id = i,
            .windows = std.ArrayList(u32){},
            .name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?",
        };
    }

    workspace_state = state;

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Initialized {} workspaces", .{ws_count});
    }
}

pub fn deinit(wm: *WM) void {
    if (workspace_state) |state| {
        for (state.workspaces) |*ws| {
            ws.windows.deinit(wm.allocator);
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(state.workspaces);
        wm.allocator.destroy(state);
        workspace_state = null;
    }
}

/// Handle X11 events - we intercept MAP_REQUEST and DESTROY_NOTIFY
pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const state = workspace_state orelse return;
    
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => {
            const e: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            handleMapRequest(e, wm, state);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const e: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleDestroyNotify(e, wm, state);
        },
        else => {},
    }
}

/// Add window to current workspace when it's mapped
fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *WorkspaceState) void {
    _ = wm;
    const window_id = event.window;
    const ws = &state.workspaces[state.current];

    // Check if already exists
    for (ws.windows.items) |win| {
        if (win == window_id) return;
    }

    ws.windows.append(state.allocator, window_id) catch {
        std.log.err("[workspaces] Failed to add window {x}", .{window_id});
        return;
    };

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Added window {x} to workspace {}", .{window_id, state.current + 1});
    }
}

/// Remove window from all workspaces when it's destroyed
fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM, state: *WorkspaceState) void {
    _ = wm;
    const window_id = event.window;
    
    for (state.workspaces) |*ws| {
        for (ws.windows.items, 0..) |win, i| {
            if (win == window_id) {
                _ = ws.windows.orderedRemove(i);
                if (builtin.mode == .Debug) {
                    std.log.info("[workspaces] Removed window {x} from workspace {}", .{window_id, ws.id + 1});
                }
                return;
            }
        }
    }
}

/// Switch to a different workspace
pub fn switchTo(wm: *WM, workspace_id: usize) void {
    const state = workspace_state orelse return;

    if (workspace_id >= state.workspaces.len) {
        std.log.warn("[workspaces] Invalid workspace ID: {}", .{workspace_id});
        return;
    }
    
    if (workspace_id == state.current) {
        if (builtin.mode == .Debug) {
            std.log.info("[workspaces] Already on workspace {}", .{workspace_id + 1});
        }
        return;
    }

    const old_workspace = state.current;
    const old_ws = &state.workspaces[old_workspace];
    const new_ws = &state.workspaces[workspace_id];

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Switching from workspace {} ({} windows) to workspace {} ({} windows)", 
            .{old_workspace + 1, old_ws.windows.items.len, workspace_id + 1, new_ws.windows.items.len});
    }

    // Hide all windows on current workspace
    for (old_ws.windows.items) |win| {
        _ = xcb.xcb_unmap_window(wm.conn, win);
        if (builtin.mode == .Debug) {
            std.log.info("[workspaces]   Hiding window {x}", .{win});
        }
    }

    // Switch to new workspace
    state.current = workspace_id;

    // Show all windows on new workspace
    for (new_ws.windows.items) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
        if (builtin.mode == .Debug) {
            std.log.info("[workspaces]   Showing window {x}", .{win});
        }
    }

    // Focus first window if any exist, otherwise clear focus
    if (new_ws.windows.items.len > 0) {
        const first_window = new_ws.windows.items[0];
        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            first_window,
            xcb.XCB_CURRENT_TIME
        );
        _ = xcb.xcb_configure_window(wm.conn, first_window, 
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        wm.focused_window = first_window;
        
        // Notify tiling system about focus change
        tiling.updateWindowFocus(wm, first_window);
    } else {
        wm.focused_window = null;
    }

    _ = xcb.xcb_flush(wm.conn);
    
    // Retile the new workspace
    tiling.retileCurrentWorkspace(wm);

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Now on workspace {}", .{workspace_id + 1});
    }
}

/// Move focused window to another workspace
pub fn moveWindowTo(wm: *WM, target_workspace: usize) void {
    const state = workspace_state orelse return;
    const focused = wm.focused_window orelse {
        std.log.warn("[workspaces] No focused window to move", .{});
        return;
    };

    if (target_workspace >= state.workspaces.len) {
        std.log.warn("[workspaces] Invalid workspace ID: {}", .{target_workspace});
        return;
    }
    
    if (target_workspace == state.current) {
        if (builtin.mode == .Debug) {
            std.log.info("[workspaces] Window already on workspace {}", .{target_workspace + 1});
        }
        return;
    }

    const current_ws = &state.workspaces[state.current];
    const target_ws = &state.workspaces[target_workspace];

    // Remove from current workspace
    var found = false;
    for (current_ws.windows.items, 0..) |win, i| {
        if (win == focused) {
            _ = current_ws.windows.orderedRemove(i);
            found = true;
            break;
        }
    }

    if (!found) {
        std.log.warn("[workspaces] Window {x} not found in current workspace", .{focused});
        return;
    }

    // Add to target workspace
    target_ws.windows.append(wm.allocator, focused) catch {
        std.log.err("[workspaces] Failed to add window to workspace {}", .{target_workspace});
        return;
    };

    // Hide the window since it's no longer on current workspace
    _ = xcb.xcb_unmap_window(wm.conn, focused);

    // Focus next window in current workspace
    if (current_ws.windows.items.len > 0) {
        const next_window = current_ws.windows.items[0];
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, next_window, xcb.XCB_CURRENT_TIME);
        _ = xcb.xcb_configure_window(wm.conn, next_window, 
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        wm.focused_window = next_window;
        tiling.updateWindowFocus(wm, next_window);
    } else {
        wm.focused_window = null;
    }

    _ = xcb.xcb_flush(wm.conn);
    
    // Retile the current workspace after removing a window
    tiling.retileCurrentWorkspace(wm);

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Moved window {x} to workspace {}", .{focused, target_workspace + 1});
    }
}

/// Get current workspace's window list
pub fn getCurrentWindows() ?[]const u32 {
    const state = workspace_state orelse return null;
    return state.workspaces[state.current].windows.items;
}

/// Get current workspace ID
pub fn getCurrentWorkspace() ?usize {
    const state = workspace_state orelse return null;
    return state.current;
}

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
};
