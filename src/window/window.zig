//! Window management optimized for responsivity
//! OPTIMIZED: Enter event coalescing, reduced XCB calls
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

// EVENT HANDLERS - OPTIMIZED FOR IMMEDIATE RESPONSE

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // CRITICAL: Check workspace rules BEFORE mapping to avoid flicker
    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    if (target_ws) |ws| {
        if (ws != current_ws) {
            workspaces.addWindowToWorkspace(wm, win, ws);

            if (wm.config.tiling.enabled) {
                const attrs = utils.WindowAttrs{
                    .border_width = wm.config.tiling.border_width,
                    .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
                };
                attrs.configure(wm.conn, win);
            }

            utils.flush(wm.conn);
            return;
        }
    }

    workspaces.addWindowToCurrentWorkspace(wm, win);
    _ = xcb.xcb_map_window(wm.conn, win);

    if (wm.config.tiling.enabled) {
        tiling.notifyWindowMapped(wm, win);
    }

    focus.markLayoutOperation();
    utils.flush(wm.conn);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

/// OPTIMIZED: Coalesce enter notify events to prevent focus thrashing
pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;

    // Check focus protection
    if (focus.shouldSuppressMouseFocus()) return;

    // OPTIMIZATION: Coalesce enter events - skip if more are queued
    // This is critical when rapidly moving cursor across many windows
    if (hasQueuedEnterEvents(wm.conn)) {
        return; // Skip this event, process the latest one instead
    }

    focus.setFocus(wm, event.event, .mouse_enter);
}

/// Check if there are more enter notify events in the queue
/// Returns true if we should skip the current event
fn hasQueuedEnterEvents(conn: *xcb.xcb_connection_t) bool {
    // Check for multiple queued enter events
    var count: u8 = 0;
    while (count < 2) {
        // Check for 2 queued events instead of 1
        const queued = xcb.xcb_poll_for_event(conn);
        if (queued) |next_event| {
            defer std.c.free(next_event);
            const next_type = @as(*u8, @ptrCast(next_event)).* & 0x7F;
            if (next_type == xcb.XCB_ENTER_NOTIFY) {
                count += 1;
                continue;
            }
        }
        return count > 0; // This ensures we return in all cases
    }
    return false; // Default return if loop completes
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    const was_focused = wm.focused_window == win;

    // Clean up in correct order
    tiling.notifyWindowDestroyed(wm, win);
    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        wm.focused_window = null;

        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                focus.setFocus(wm, ws_windows[0], .window_destroyed);
                return;
            }
        }

        focus.clearFocus(wm);
    }
}

// WORKSPACE RULES

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
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
