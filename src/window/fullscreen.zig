//! Fullscreen window management

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const log = @import("logging");

pub fn toggleFullscreen(wm: *WM) void {
    const win = wm.focused_window orelse return;
    
    if (wm.fullscreen_window == win) {
        exitFullscreen(wm);
    } else {
        if (wm.fullscreen_window != null) {
            exitFullscreen(wm);
        }
        enterFullscreen(wm, win);
    }
}

fn enterFullscreen(wm: *WM, win: u32) void {
    // Get original geometry including border width
    const cookie = xcb.xcb_get_geometry(wm.conn, win);
    const geom = xcb.xcb_get_geometry_reply(wm.conn, cookie, null) orelse return;
    defer std.c.free(geom);
    
    wm.fullscreen_geometry = .{
        .x = geom.*.x,
        .y = geom.*.y,
        .width = geom.*.width,
        .height = geom.*.height,
        .border_width = geom.*.border_width,
    };
    
    // Set fullscreen: no borders, full screen size
    const screen = wm.screen;
    const attrs = utils.WindowAttrs{
        .x = 0,
        .y = 0,
        .width = screen.width_in_pixels,
        .height = screen.height_in_pixels,
        .border_width = 0,
        .stack_mode = xcb.XCB_STACK_MODE_ABOVE,
    };
    attrs.configure(wm.conn, win);
    
    wm.fullscreen_window = win;
    utils.flush(wm.conn);
    
    if (log.isDebug()) {
        std.log.debug("[fullscreen] Entered fullscreen for window 0x{x}", .{win});
    }
}

fn exitFullscreen(wm: *WM) void {
    const win = wm.fullscreen_window orelse return;
    const saved = wm.fullscreen_geometry orelse return;
    
    // Restore original geometry and borders
    const attrs = utils.WindowAttrs{
        .x = saved.x,
        .y = saved.y,
        .width = saved.width,
        .height = saved.height,
        .border_width = saved.border_width,
    };
    attrs.configure(wm.conn, win);
    
    // Restore border color based on focus state
    if (wm.focused_window == win) {
        if (tiling.isWindowTiled(win)) {
            if (tiling.getState()) |t_state| {
                _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, 
                    &[_]u32{t_state.border_focused});
            }
        }
    }
    
    wm.fullscreen_window = null;
    wm.fullscreen_geometry = null;
    utils.flush(wm.conn);
    
    if (log.isDebug()) {
        std.log.debug("[fullscreen] Exited fullscreen for window 0x{x}", .{win});
    }
}

/// Check if a window is currently fullscreen
pub fn isFullscreen(wm: *const WM, win: u32) bool {
    return wm.fullscreen_window == win;
}

/// Exit fullscreen if the current fullscreen window is destroyed
pub fn notifyWindowDestroyed(wm: *WM, win: u32) void {
    if (wm.fullscreen_window == win) {
        wm.fullscreen_window = null;
        wm.fullscreen_geometry = null;
    }
}

/// Exit fullscreen when switching workspaces
pub fn notifyWorkspaceSwitch(wm: *WM) void {
    if (wm.fullscreen_window != null) {
        exitFullscreen(wm);
    }
}
