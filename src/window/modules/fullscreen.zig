// Fullscreen management

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

inline fn borderColor(wm: *WM, win: u32) u32 {
    return if (wm.focused_window == win) wm.config.tiling.border_focused
           else                          wm.config.tiling.border_unfocused;
}

// Fetch the current geometry of `win`. Falls back to a centered quarter-screen
// default if the reply fails or the window is currently offscreen.
fn fetchWindowGeom(wm: *WM, win: u32) defs.WindowGeometry {
    const def_x: i16 = @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)),  4);
    const def_y: i16 = @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4);
    const def_w: u16 = @divTrunc(wm.screen.width_in_pixels,  2);
    const def_h: u16 = @divTrunc(wm.screen.height_in_pixels, 2);

    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return .{ .x = def_x, .y = def_y, .width = def_w, .height = def_h, .border_width = 0 };
    defer std.c.free(reply);

    const is_offscreen =
        reply.*.x < constants.OFFSCREEN_THRESHOLD_MIN or
        reply.*.x > constants.OFFSCREEN_THRESHOLD_MAX or
        reply.*.y < constants.OFFSCREEN_THRESHOLD_MIN or
        reply.*.y > constants.OFFSCREEN_THRESHOLD_MAX;

    return .{
        .x            = if (is_offscreen) def_x else reply.*.x,
        .y            = if (is_offscreen) def_y else reply.*.y,
        .width        = if (is_offscreen) def_w else reply.*.width,
        .height       = if (is_offscreen) def_h else reply.*.height,
        .border_width = reply.*.border_width,
    };
}

// Atomic commit helpers: only queue XCB requests, never grab or flush.
// The caller owns the grab/ungrab/flush envelope so that paired
// exit+enter transitions can share a single grab with no intermediate frame.

// Queue all XCB commands to enter fullscreen for `win` on `ws`.
// `geom` must be pre-fetched outside the grab via fetchWindowGeom.
fn enterFullscreenCommit(wm: *WM, win: u32, ws: u8, geom: defs.WindowGeometry) void {
    wm.fullscreen.setForWorkspace(ws, .{
        .window         = win,
        .saved_geometry = geom,
    }) catch {
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };

    // Push siblings offscreen and evict their geometry cache entries.
    // Without eviction, the next retile would find cache hits for the stored
    // tiled rects and skip configure_window, leaving siblings stuck offscreen.
    if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
        for (ws_obj.windows.items()) |other_win| {
            if (other_win == win) continue;
            _ = xcb.xcb_configure_window(wm.conn, other_win,
                xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(other_win);
        }
    }

    // Hide bar; fullscreen state is recorded above so any retile triggered
    // inside setBarState returns early without fighting us.
    bar.setBarState(wm, .hide_fullscreen);

    // Expand to cover the full screen with no border, then raise above floats.
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &[_]u32{
            0, 0,
            @intCast(wm.screen.width_in_pixels),
            @intCast(wm.screen.height_in_pixels),
            0,
        });
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Evict the fullscreen window itself; its cache still holds the pre-fullscreen
    // tiled rect. On exit retile would compute the same rect, get a hit, and skip
    // configure_window, leaving the window stuck at fullscreen dimensions.
    tiling.invalidateGeomCache(win);
}

// Queue all XCB commands to exit fullscreen for `win` on `ws`.
// Clears fullscreen state before triggering any retile so retile's early-return
// guard does not abort the run.
fn exitFullscreenCommit(wm: *WM, win: u32, ws: u8) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    // Clear before calling setBarState so the retile it triggers does not see
    // an active fullscreen and bail.
    wm.fullscreen.removeForWorkspace(ws);

    // Show bar; for tiled workspaces this also retiles, repositioning all
    // windows (including `win`) back to their correct tiled geometry.
    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        // retile above already sent the correct geometry for `win`.
        // Restore border width and colour separately: the Rect that retile
        // sends does not include BORDER_WIDTH, so it remains 0 until here.
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});
    } else {
        // Floating: restore saved geometry and border explicitly.
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                @bitCast(@as(i32, saved.x)),
                @bitCast(@as(i32, saved.y)),
                saved.width,
                saved.height,
                saved.border_width,
            });
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});

        // Bring non-minimized siblings back to a visible position.
        if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
            const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
            const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
            for (ws_obj.windows.items()) |other_win| {
                if (other_win == win) continue;
                if (minimize.isMinimized(other_win)) continue;
                _ = xcb.xcb_configure_window(wm.conn, other_win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ x, y });
            }
        }
    }
}

// Shared grab-owning wrapper for all enter paths.
// Any blocking round-trips (fetchWindowGeom) must happen before calling this.
fn enterFullscreen(wm: *WM, win: u32, ws: u8, geom: defs.WindowGeometry) void {
    _ = xcb.xcb_grab_server(wm.conn);
    enterFullscreenCommit(wm, win, ws, geom);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

fn exitFullscreen(wm: *WM, win: u32, ws: u8) void {
    _ = xcb.xcb_grab_server(wm.conn);
    exitFullscreenCommit(wm, win, ws);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Public API

// Enter fullscreen for a specific window on the current workspace.
// Used by the minimize module when restoring a window that was fullscreen.
// Caller is responsible for setting wm.focused_window before calling.
pub fn enterFullscreenForWindow(wm: *WM, win: u32) void {
    const ws = workspaces.getCurrentWorkspace() orelse return;
    enterFullscreen(wm, win, ws, fetchWindowGeom(wm, win));
}

// Enter fullscreen using geometry already known to the caller.
// Used by the minimize module to restore a fullscreen-minimized window:
// the saved geometry avoids the xcb_get_geometry round-trip, and the window
// goes directly from offscreen to fullscreen in a single atomic grab with
// no intermediate compositor frame.
pub fn enterFullscreenWithSavedGeom(wm: *WM, win: u32, geom: defs.WindowGeometry) void {
    const ws = workspaces.getCurrentWorkspace() orelse return;
    enterFullscreen(wm, win, ws, geom);
}

pub fn toggleFullscreen(wm: *WM) void {
    const win        = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            exitFullscreen(wm, win, current_ws);
        } else {
            // Switching fullscreen from one window to another.
            // Pre-fetch geometry BEFORE the grab: xcb_get_geometry_reply blocks
            // and blocking inside a grab risks deadlock with concurrent grabs.
            const geom = fetchWindowGeom(wm, win);
            // Wrap both transitions in a single grab to avoid an intermediate frame.
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, fs_info.window, current_ws);
            enterFullscreenCommit(wm, win, current_ws, geom);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        }
    } else {
        enterFullscreen(wm, win, current_ws, fetchWindowGeom(wm, win));
    }
}
