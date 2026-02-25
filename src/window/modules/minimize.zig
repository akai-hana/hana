//! Window minimization: per-workspace ordered hide/restore.
//!
//! Minimized windows remain in their workspace's window list so the bar
//! keeps rendering them, but they are moved offscreen and removed from
//! tiling so remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   unminimize(.lifo): restore the most recently minimized window (stack pop)
//!   unminimize(.fifo): restore the least recently minimized window (queue dequeue)
//!   unminimizeAll:     restore every minimized window
//!
//! Fullscreen interaction: minimizing a fullscreen window tears down the
//! fullscreen state but saves the pre-fullscreen geometry. Restoring such
//! a window puts it back into fullscreen exactly as it was.

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

// MinimizeState is defined in defs.zig so WM can own it without circular imports.
// deinit is handled by WM.deinit; no module-level singleton is needed here.

/// Initialise the minimize subsystem and store state in wm.minimize.
/// Called by events.initModules before the event loop starts.
pub fn init(wm: *WM) void {
    const lists = wm.allocator.alloc(std.ArrayListUnmanaged(u32), wm.config.workspaces.count) catch {
        debug.err("minimize: failed to allocate per-workspace lists", .{});
        return;
    };
    for (lists) |*l| l.* = .{};

    var info_map = std.AutoHashMap(u32, ?defs.WindowGeometry).init(wm.allocator);
    info_map.ensureTotalCapacity(8) catch {};

    wm.minimize = defs.MinimizeState{
        .per_workspace  = lists,
        .minimized_info = info_map,
        .allocator      = wm.allocator,
    };
}

pub fn isMinimized(wm: *const WM, win: u32) bool {
    const s = wm.minimize orelse return false;
    return s.minimized_info.contains(win);
}

// Record win as minimized in the per-workspace list and the info map.
// saved_fs is non-null iff the window was fullscreen when minimized.
// Returns false on allocation failure; caller must roll back any side-effects.
fn trackMinimized(s: *defs.MinimizeState, ws_idx: u8, win: u32, saved_fs: ?defs.WindowGeometry) bool {
    s.per_workspace[ws_idx].append(s.allocator, win) catch return false;
    s.minimized_info.put(win, saved_fs) catch {
        _ = s.per_workspace[ws_idx].pop();
        return false;
    };
    return true;
}

// Move win offscreen using the same technique as workspace switching:
// no unmap/remap, so the compositor never frees the buffer.
inline fn hideWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_configure_window(
        wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

// Focus the best available non-minimized window on the current workspace,
// or clear focus if none exists. Used by the minimize path and window.zig.
pub fn focusBestAvailable(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    if (workspaces.firstNonMinimized(wm, ws.windows.items())) |win| {
        focus.setFocus(wm, win, .window_destroyed);
    } else {
        focus.clearFocus(wm);
    }
}

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    if (wm.minimize == null) return;
    const s = &wm.minimize.?;

    if (isMinimized(wm, win)) return;

    // Exit fullscreen if active, saving geometry for restoration.
    // Single map lookup covers both the "is fullscreen?" check and the ws lookup.
    var saved_fs: ?defs.WindowGeometry = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    // Track before entering the grab so we can abort cleanly on allocation
    // failure without having to handle a partial grab state.
    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        return;
    }

    // Wrap hide + focus + retile in a single grab so picom never composites
    // an intermediate state.
    _ = xcb.xcb_grab_server(wm.conn);
    hideWindow(wm, win);
    focusBestAvailable(wm);
    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores the bar and triggers a retile.
        // The minimized window is not in tiling so it gets no tile position.
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
    // Redraw inside the grab so the bar update is composited atomically with
    // the window hide; otherwise picom shows one stale frame first.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Bring win back onscreen and re-enter fullscreen if it was fullscreen when
// minimized. The caller is responsible for removing win from the ordered
// per-workspace list; this function only handles the info map and X11 state.
fn restoreWindow(wm: *WM, win: u32) void {
    if (wm.minimize == null) return;
    const s = &wm.minimize.?;

    const entry = s.minimized_info.fetchRemove(win) orelse return;
    const saved_fs = entry.value;

    if (saved_fs) |geom| {
        // Pass saved geometry directly to enterFullscreenWithSavedGeom so the
        // window goes from offscreen to fullscreen in a single atomic grab with
        // no intermediate compositor frame at the small saved size.
        wm.focused_window = win;
        fullscreen.enterFullscreenWithSavedGeom(wm, win, geom);
        bar.markDirty();
        return;
    }

    // Non-fullscreen: wrap addWindow + retile + focus in a single grab so picom
    // never composites a frame where the window has appeared but neighbours have
    // not yet been repositioned.
    _ = xcb.xcb_grab_server(wm.conn);

    if (wm.config.tiling.enabled) {
        tiling.addWindow(wm, win);
        tiling.retileCurrentWorkspace(wm);
    } else {
        const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
        const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ x, y },
        );
    }

    // .window_spawn skips the isWindowMapped round-trip, keeping the grab
    // scope free of avoidable blocking calls.
    focus.setFocus(wm, win, .window_spawn);
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

pub const RestoreOrder = enum { lifo, fifo };

/// Restore one minimized window from the current workspace.
/// .lifo pops the most recently minimized (stack); .fifo takes the oldest (queue).
pub fn unminimize(wm: *WM, order: RestoreOrder) void {
    if (wm.minimize == null) return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &wm.minimize.?.per_workspace[ws_idx];
    const win = switch (order) {
        .lifo => list.pop() orelse return,
        .fifo => if (list.items.len > 0) list.orderedRemove(0) else return,
    };
    restoreWindow(wm, win);
}

// Restore every minimized window on the current workspace.
pub fn unminimizeAll(wm: *WM) void {
    if (wm.minimize == null) return;
    const s      = &wm.minimize.?;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;

    // Snapshot then clear the ordered list before iterating.
    var snapshot: std.ArrayListUnmanaged(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.appendSlice(s.allocator, list.items) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed");
        return;
    };
    list.clearRetainingCapacity();

    // If any window was fullscreen when minimized, fall back to per-window
    // restoreWindow. Re-entering fullscreen involves its own grab + bar hide +
    // sibling offscreen, and this case is rare enough that N separate grabs is fine.
    for (snapshot.items) |w| {
        if (s.minimized_info.get(w).? != null) {
            for (snapshot.items) |win| restoreWindow(wm, win);
            return;
        }
    }

    // Common case: no fullscreen windows. Batch all additions, retile, focus,
    // and bar redraw into a single grab so picom composites exactly one frame
    // with all windows at their correct positions.
    _ = xcb.xcb_grab_server(wm.conn);

    // tiling.enabled is loop-invariant: hoist the branch and x/y outside.
    if (wm.config.tiling.enabled) {
        for (snapshot.items) |win| {
            _ = s.minimized_info.fetchRemove(win);
            tiling.addWindow(wm, win);
        }
        tiling.retileCurrentWorkspace(wm);
    } else {
        const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
        const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
        for (snapshot.items) |win| {
            _ = s.minimized_info.fetchRemove(win);
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ x, y });
        }
    }

    // Focus the most-recently-minimized window (last in snapshot).
    // .window_spawn skips the isWindowMapped round-trip inside the grab.
    focus.setFocus(wm, snapshot.items[snapshot.items.len - 1], .window_spawn);

    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Called by window.zig on unmap/destroy to keep state coherent. No-op if not minimized.
pub fn forceUntrack(wm: *WM, win: u32) void {
    if (wm.minimize == null) return;
    const s = &wm.minimize.?;
    if (s.minimized_info.fetchRemove(win) == null) return;
    for (s.per_workspace) |*list| {
        for (list.items, 0..) |w, i| {
            if (w != win) continue;
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(wm: *WM, win: u32, old_ws: u8, new_ws: u8) void {
    if (wm.minimize == null) return;
    const s = &wm.minimize.?;
    if (!s.minimized_info.contains(win)) return;
    if (old_ws >= s.per_workspace.len or new_ws >= s.per_workspace.len) return;

    const old_list = &s.per_workspace[old_ws];
    for (old_list.items, 0..) |w, i| {
        if (w != win) continue;
        _ = old_list.orderedRemove(i);
        break;
    }

    s.per_workspace[new_ws].append(s.allocator, win) catch |err| {
        debug.warnOnErr(err, "minimize.moveToWorkspace: failed to append");
    };
}
