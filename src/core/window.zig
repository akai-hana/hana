//! Window management optimized for responsivity
//! - Map windows IMMEDIATELY (no blocking on WM_CLASS)
//! - Apply workspace rules asynchronously after mapping
const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const builtin = @import("builtin");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

// ============================================================================
// EVENT HANDLERS - OPTIMIZED FOR IMMEDIATE RESPONSE
// ============================================================================

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // RESPONSIVITY: Map window IMMEDIATELY to current workspace
    // Apply rules asynchronously (slight delay acceptable for correct placement)
    workspaces.addWindowToCurrentWorkspace(wm, win);
    _ = xcb.xcb_map_window(wm.conn, win);
    
    if (wm.config.tiling.enabled) {
        tiling.notifyWindowMapped(wm, win);
    }

    // OPTIONAL: Apply workspace rules after window is visible
    // This creates a slight delay but window appears instantly
    if (wm.config.workspaces.rules.items.len > 0) {
        applyWorkspaceRulesAsync(wm, win);
    }
}

/// Apply workspace rules without blocking initial window display
fn applyWorkspaceRulesAsync(wm: *WM, win: u32) void {
    const target_ws = matchWorkspaceRule(wm, win) orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;
    
    if (target_ws != current_ws) {
        // Move window to correct workspace
        // User sees window appear briefly before it moves - acceptable tradeoff
        workspaces.moveWindowToWorkspace(wm, win, target_ws);
    }
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    // Let tiling handle tiled windows
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    // Configure floating window - single XCB call
    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;
    focus.setFocus(wm, event.event, .mouse_enter);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    const was_focused = wm.focused_window == win;

    wm.removeWindow(win);
    workspaces.removeWindow(win);
    tiling.notifyWindowDestroyed(wm, win);

    // Only refocus if the destroyed window was focused
    // Let the workspace/tiling system handle focusing the next window on the CURRENT workspace
    if (was_focused) {
        wm.focused_window = null;
        
        // Focus next window on current workspace only
        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                // Focus the first window on the current workspace
                focus.setFocus(wm, ws_windows[0], .window_destroyed);
            } else {
                // No windows left on current workspace
                focus.clearFocus(wm);
            }
        }
    }
}

// ============================================================================
// WORKSPACE RULES - NON-BLOCKING
// ============================================================================

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    // This still blocks, but only AFTER window is mapped
    // User sees window immediately, rule application is delayed
    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }

    return null;
}
