//! Window minimization — per-workspace ordered hide/restore.
//!
//! Minimized windows remain in their workspace's window list so the bar's
//! title segment keeps rendering them (with a distinct configurable accent
//! colour), but they are moved off-screen and removed from the tiling layout
//! so the remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   · unminimize_lifo  — restore the most recently minimized window (stack pop)
//!   · unminimize_fifo  — restore the least recently minimized window (queue dequeue)
//!   · unminimize_all   — restore every minimized window
//!
//! Fullscreen interaction:
//!   Minimizing a fullscreen window tears down the fullscreen state (so the bar
//!   and sibling windows come back) but saves the pre-fullscreen geometry.
//!   Restoring such a window puts it back into fullscreen exactly as it was.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const focus      = @import("focus");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const fullscreen = @import("fullscreen");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");

// Types

/// Saved pre-fullscreen geometry for a window that was in fullscreen when
/// minimized.  Stored so we can reconstruct the fullscreen state faithfully
/// on restore without querying the window (which is off-screen at that point).
const SavedGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

pub const State = struct {
    /// Per-workspace insertion-ordered list of minimized window IDs.
    /// Windows are appended on minimize.
    /// LIFO restore = pop from tail; FIFO restore = remove from head.
    per_workspace:    std.AutoHashMap(u8, std.ArrayList(u32)),
    /// O(1) membership check — a window is minimized iff present here.
    minimized_set:    std.AutoHashMap(u32, void),
    /// Pre-fullscreen geometry for windows that were fullscreen when minimized.
    saved_fullscreen: std.AutoHashMap(u32, SavedGeometry),
    allocator:        std.mem.Allocator,
};

// Module singleton

var g_state: ?State = null;

pub fn getState() ?*State {
    return if (g_state != null) &g_state.? else null;
}

// Init / deinit

pub fn init(allocator: std.mem.Allocator) void {
    g_state = State{
        .per_workspace    = std.AutoHashMap(u8, std.ArrayList(u32)).init(allocator),
        .minimized_set    = std.AutoHashMap(u32, void).init(allocator),
        .saved_fullscreen = std.AutoHashMap(u32, SavedGeometry).init(allocator),
        .allocator        = allocator,
    };
}

pub fn deinit() void {
    if (g_state) |*s| {
        var it = s.per_workspace.valueIterator();
        while (it.next()) |list| list.deinit(s.allocator);
        s.per_workspace.deinit();
        s.minimized_set.deinit();
        s.saved_fullscreen.deinit();
    }
    g_state = null;
}

// Public queries

pub fn isMinimized(win: u32) bool {
    const s = g_state orelse return false;
    return s.minimized_set.contains(win);
}

// Internal helpers

/// Append `win` to the per-workspace ordered list and insert it into the fast
/// membership set.  Returns false on allocation failure (caller must rollback).
fn trackMinimized(s: *State, ws_idx: u8, win: u32) bool {
    const gop = s.per_workspace.getOrPut(ws_idx) catch return false;
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.append(s.allocator, win) catch return false;
    s.minimized_set.put(win, {}) catch {
        _ = gop.value_ptr.pop();
        return false;
    };
    return true;
}

/// Remove `win` from all tracking structures.  Safe to call even if the window
/// is not currently tracked (idempotent).
fn untrackMinimized(s: *State, win: u32) void {
    _ = s.minimized_set.remove(win);
    _ = s.saved_fullscreen.remove(win);
    // Linear scan is acceptable — lists are very small in practice.
    var it = s.per_workspace.valueIterator();
    while (it.next()) |list| {
        for (list.items, 0..) |w, i| {
            if (w != win) continue;
            _ = list.orderedRemove(i);
            return;
        }
    }
}

/// Move `win` off-screen using the same XConfigure technique as workspace
/// switching — no unmap/remap cycle, the compositor never frees the buffer.
fn hideWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_configure_window(
        wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

/// Focus the best available non-minimized window on the current workspace,
/// or clear focus if none exists.
fn refocusAfterMinimize(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    for (ws.windows.items()) |win| {
        if (!isMinimized(win)) {
            focus.setFocus(wm, win, .window_destroyed);
            return;
        }
    }
    focus.clearFocus(wm);
}

// Minimize

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window           orelse return;
    const s      = getState()                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return; // idempotent

    // Phase 1: exit fullscreen if active, saving geometry for restoration.
    const was_fullscreen = wm.fullscreen.isFullscreen(win);
    if (was_fullscreen) {
        if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
            if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
                s.saved_fullscreen.put(win, .{
                    .x            = info.saved_geometry.x,
                    .y            = info.saved_geometry.y,
                    .width        = info.saved_geometry.width,
                    .height       = info.saved_geometry.height,
                    .border_width = info.saved_geometry.border_width,
                }) catch |err| debug.warnOnErr(err, "minimize: save fullscreen geometry");

                wm.fullscreen.removeForWorkspace(fs_ws);
            }
        }
    }

    // Phase 2: remove from tiling (before retile so the layout excludes it).
    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    // Phase 3: move off-screen.
    hideWindow(wm, win);

    // Phase 4: track.  On failure, roll back tiling membership and abort.
    if (!trackMinimized(s, ws_idx, win)) {
        debug.err("minimize: allocation failure tracking window 0x{x} — rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        return;
    }

    // Phase 5: update focus (must precede retile so border colours are correct).
    refocusAfterMinimize(wm);

    // Phase 6: bring remaining windows back on-screen / retile.
    if (was_fullscreen) {
        // show_fullscreen restores the bar and, for tiled workspaces, retiles.
        // Window tracking was updated in Phase 4, so the minimized window will
        // not receive a tile position.
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }

    utils.flush(wm.conn);
    bar.markDirty();
}

// Restore helpers

/// Bring `win` back on-screen, re-add it to tiling, and re-enter fullscreen
/// if it was fullscreen when minimized.
fn restoreWindow(wm: *WM, win: u32) void {
    const s = getState() orelse return;

    // Fetch and remove any saved fullscreen geometry before untracking
    // (untrackMinimized also removes it from saved_fullscreen).
    const saved_fs_entry = s.saved_fullscreen.fetchRemove(win);
    untrackMinimized(s, win);

    if (saved_fs_entry) |entry| {
        const geom = entry.value;

        // Restore the pre-fullscreen geometry so enterFullscreenForWindow
        // reads accurate on-screen coordinates from xcb_get_geometry.
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                @bitCast(@as(i32, geom.x)),
                @bitCast(@as(i32, geom.y)),
                geom.width,
                geom.height,
                geom.border_width,
            },
        );
        utils.flush(wm.conn);

        // Re-enter fullscreen — this saves the geometry above, covers the
        // screen, hides the bar, and pushes sibling windows off-screen.
        wm.focused_window = win;
        fullscreen.enterFullscreenForWindow(wm, win);
        // enterFullscreenForWindow handles its own flush and bar state.
        bar.markDirty();
        return;
    }

    // Non-fullscreen restore.
    if (wm.config.tiling.enabled) {
        tiling.addWindow(wm, win);
        tiling.retileCurrentWorkspace(wm);
    } else {
        // Floating mode: place at a sensible on-screen position.
        const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
        const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ x, y },
        );
    }

    focus.setFocus(wm, win, .window_spawn);
    utils.flush(wm.conn);
    bar.markDirty();
}

/// Return the ordered minimized list for the current workspace, or null if
/// there are no minimized windows on it.
fn currentWorkspaceList() ?*std.ArrayList(u32) {
    const s      = getState()                  orelse return null;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return null;
    const list   = s.per_workspace.getPtr(ws_idx)  orelse return null;
    return if (list.items.len > 0) list else null;
}

// Public unminimize API

/// Restore the most recently minimized window on the current workspace (LIFO).
pub fn unminimizeLifo(wm: *WM) void {
    const list = currentWorkspaceList() orelse return;
    const win  = list.pop() orelse return; // guarded by currentWorkspaceList len > 0 check
    restoreWindow(wm, win);
}

/// Restore the least recently minimized window on the current workspace (FIFO).
pub fn unminimizeFifo(wm: *WM) void {
    const list = currentWorkspaceList() orelse return;
    const win  = list.orderedRemove(0); // head = first appended
    restoreWindow(wm, win);
}

/// Restore every minimized window on the current workspace.
pub fn unminimizeAll(wm: *WM) void {
    const s      = getState()                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = s.per_workspace.getPtr(ws_idx)  orelse return;
    if (list.items.len == 0) return;

    // Snapshot before iterating — restoreWindow modifies the list via
    // untrackMinimized, so we must not iterate it directly.
    var snapshot: std.ArrayList(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.appendSlice(s.allocator, list.items) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed");
        return;
    };

    for (snapshot.items) |win| restoreWindow(wm, win);
}

// Lifecycle hooks

/// Called by window.zig on unmap/destroy to keep state coherent.
/// No-op when the window was not minimized.
pub fn forceUntrack(win: u32) void {
    const s = getState() orelse return;
    if (!s.minimized_set.contains(win)) return;
    untrackMinimized(s, win);
}
